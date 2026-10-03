import AVFoundation
import AudioToolbox
import Foundation

struct ScheduledAudioSegment {
    let url: URL
    let timelineStartSeconds: Double
    let sourceOffsetSeconds: Double
    let durationSeconds: Double
}

@MainActor
final class AudioEngineController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var playheadBeat = 0.0

    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var playheadTask: Task<Void, Never>?
    private var trackMixers: [UUID: AVAudioMixerNode] = [:]
    private var trackEffects: [UUID: [AVAudioNode]] = [:]
    private var files: [AVAudioFile] = []
    private var anchorHostTime: UInt64 = 0
    private var startBeat = 0.0
    private var bpm = 120.0
    private var playbackProject: StudioProject?

    var currentBeat: Double {
        guard isPlaying else { return playheadBeat }
        return TransportClock.beat(now: mach_absolute_time(), anchor: anchorHostTime, start: startBeat, bpm: bpm)
    }

    func toggle(project: StudioProject) throws {
        if isPlaying {
            stop()
        } else {
            try play(project: project, fromBeat: playheadBeat)
        }
    }

    @discardableResult
    func play(project: StudioProject, fromBeat: Double = 0, recording: Bool = false) throws -> UInt64 {
        stop(resetPlayhead: false)
        let fromBeat = recording ? max(0, fromBeat) : (fromBeat >= project.lengthBeats ? 0 : max(0, fromBeat))

        let newEngine = AVAudioEngine()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: project.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let soloed = project.tracks.contains(where: \.isSolo)
        var scheduledPlayers: [(player: AVAudioPlayerNode, startDelay: Double)] = []

        for baseTrack in project.tracks {
            let track = baseTrack.automated(at: fromBeat * 60 / project.bpm)
            let mixer = AVAudioMixerNode()
            let effects = makeEffects(settings: track.effects)
            newEngine.attach(mixer)
            effects.forEach(newEngine.attach)
            connectTrackChain(engine: newEngine, mixer: mixer, effects: effects, format: format)
            mixer.outputVolume = (track.isMuted || (soloed && !track.isSolo)) ? 0 : Float(track.volume)
            mixer.pan = Float(track.pan)
            trackMixers[track.id] = mixer
            trackEffects[track.id] = effects

            for clip in track.clips {
                for segment in scheduledSegments(for: clip, bpm: project.bpm, fromBeat: fromBeat) {
                    let file = try AVAudioFile(forReading: segment.url)
                    let player = AVAudioPlayerNode()
                    newEngine.attach(player)
                    newEngine.connect(player, to: mixer, format: format)
                    try scheduleFile(segment, file: file, on: player)
                    files.append(file)
                    let startDelay = max(
                        0,
                        segment.timelineStartSeconds - fromBeat * 60 / project.bpm
                    )
                    scheduledPlayers.append((player, startDelay))
                }
            }
        }

        newEngine.prepare()
        try newEngine.start()
        // Establish the shared clock only after graph construction and engine startup.
        let anchorHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15)

        for scheduled in scheduledPlayers {
            scheduled.player.play(
                at: AVAudioTime(
                    hostTime: anchorHostTime + AVAudioTime.hostTime(forSeconds: scheduled.startDelay)
                )
            )
        }

        engine = newEngine
        players = scheduledPlayers.map(\.player)
        playheadBeat = fromBeat
        isPlaying = true
        self.anchorHostTime = anchorHostTime
        self.startBeat = fromBeat
        self.bpm = project.bpm
        playbackProject = project
        startPlayhead(project: project, recording: recording)
        return anchorHostTime
    }

    func stop(resetPlayhead: Bool = false) {
        if isPlaying { playheadBeat = currentBeat }
        playheadTask?.cancel()
        playheadTask = nil
        players.forEach { $0.stop() }
        players.removeAll()
        engine?.stop()
        engine = nil
        playbackProject = nil
        files.removeAll()
        trackMixers.removeAll()
        trackEffects.removeAll()
        isPlaying = false
        if resetPlayhead { playheadBeat = 0 }
    }

    func updateMix(project: StudioProject) {
        if isPlaying { playbackProject = project }
        applyMix(project: project, seconds: currentBeat * 60 / project.bpm)
    }

    private func applyMix(project: StudioProject, seconds: Double) {
        let soloed = project.tracks.contains(where: \.isSolo)
        for original in project.tracks {
            let track = original.automated(at: seconds)
            trackMixers[track.id]?.outputVolume = (track.isMuted || (soloed && !track.isSolo)) ? 0 : Float(track.volume)
            trackMixers[track.id]?.pan = Float(track.pan)
            if let effects = trackEffects[track.id] { configureEffects(effects, settings: track.effects) }
        }
    }

    func export(project: StudioProject, to url: URL) async throws {
        stop(resetPlayhead: false)
        try await Task.detached(priority: .userInitiated) {
            try OfflineMixRenderer.render(project: project, to: url)
        }.value
    }

    private func startPlayhead(project: StudioProject, recording: Bool) {
        playheadTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                let beat = self.currentBeat
                if let snapshot = self.playbackProject, snapshot.tracks.contains(where: { $0.automation?.isEmpty == false }) {
                    self.applyMix(project: snapshot, seconds: beat * 60 / snapshot.bpm)
                }
                if !recording && beat >= project.lengthBeats {
                    self.stop()
                    self.playheadBeat = project.lengthBeats
                    return
                }
                self.playheadBeat = beat
            }
        }
    }
}

enum OfflineMixRenderer {
    static func render(project: StudioProject, to url: URL) throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: project.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let soloed = project.tracks.contains(where: \.isSolo)
        var players: [AVAudioPlayerNode] = []
        var files: [AVAudioFile] = []
        var chains: [(TrackModel, AVAudioMixerNode, [AVAudioNode])] = []

        for baseTrack in project.tracks {
            let track = baseTrack.automated(at: 0)
            let mixer = AVAudioMixerNode()
            let effects = makeEffects(settings: track.effects)
            engine.attach(mixer)
            effects.forEach(engine.attach)
            connectTrackChain(engine: engine, mixer: mixer, effects: effects, format: format)
            mixer.outputVolume = (track.isMuted || (soloed && !track.isSolo)) ? 0 : Float(track.volume)
            mixer.pan = Float(track.pan)
            chains.append((baseTrack, mixer, effects))

            for clip in track.clips {
                for segment in scheduledSegments(for: clip, bpm: project.bpm, fromBeat: 0) {
                    let file = try AVAudioFile(forReading: segment.url)
                    let player = AVAudioPlayerNode()
                    engine.attach(player)
                    engine.connect(player, to: mixer, format: format)
                    let startSample = AVAudioFramePosition(segment.timelineStartSeconds * project.sampleRate)
                    try scheduleFile(segment, file: file, on: player,
                                     at: AVAudioTime(sampleTime: startSample, atRate: project.sampleRate))
                    files.append(file)
                    players.append(player)
                }
            }
        }

        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: 4_096
        )
        try engine.start()
        let zero = AVAudioTime(sampleTime: 0, atRate: project.sampleRate)
        players.forEach { $0.play(at: zero) }

        var fileSettings = format.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = AVAudioFramePosition(
            ceil(project.lengthBeats * 60 / project.bpm * project.sampleRate)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else { throw StudioError.invalidAudio }

        let automatedChains = chains.filter { $0.0.automation?.isEmpty == false }
        var stalls = 0
        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let quantum: AVAudioFrameCount = automatedChains.isEmpty ? engine.manualRenderingMaximumFrameCount : 256
            let frames = min(quantum, AVAudioFrameCount(remaining))
            let seconds = Double(engine.manualRenderingSampleTime) / project.sampleRate
            for (base, mixer, effects) in automatedChains {
                let track = base.automated(at: seconds)
                mixer.outputVolume = (track.isMuted || (soloed && !track.isSolo)) ? 0 : Float(track.volume)
                mixer.pan = Float(track.pan)
                configureEffects(effects, settings: track.effects)
            }
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                stalls = 0
                try outputFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 100 { throw MessageError("Audio export stalled.") }
                continue
            case .error:
                throw StudioError.invalidAudio
            @unknown default:
                throw StudioError.invalidAudio
            }
        }
        players.forEach { $0.stop() }
        engine.stop()
        engine.disableManualRenderingMode()
        withExtendedLifetime(files) {}
    }
}

private func makeEffects(settings: EffectSettings) -> [AVAudioNode] {
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    eq.bands[0].filterType = .lowShelf
    eq.bands[0].frequency = 160
    eq.bands[0].gain = Float(settings.lowGain)
    eq.bands[0].bypass = false
    eq.bands[1].filterType = .parametric
    eq.bands[1].frequency = 1_200
    eq.bands[1].bandwidth = 1
    eq.bands[1].gain = Float(settings.midGain)
    eq.bands[1].bypass = false
    eq.bands[2].filterType = .highShelf
    eq.bands[2].frequency = 6_000
    eq.bands[2].gain = Float(settings.highGain)
    eq.bands[2].bypass = false

    let compressorDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    let compressor = AVAudioUnitEffect(audioComponentDescription: compressorDescription)
    setAudioUnitParameter(
        compressor.audioUnit,
        id: AudioUnitParameterID(kDynamicsProcessorParam_Threshold),
        value: Float(-5 - settings.compression * 35)
    )
    setAudioUnitParameter(
        compressor.audioUnit,
        id: AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom),
        value: Float(40 - settings.compression * 35)
    )
    setAudioUnitParameter(
        compressor.audioUnit,
        id: AudioUnitParameterID(kDynamicsProcessorParam_AttackTime),
        value: 0.005
    )
    setAudioUnitParameter(
        compressor.audioUnit,
        id: AudioUnitParameterID(kDynamicsProcessorParam_ReleaseTime),
        value: 0.08
    )

    let drive = AVAudioUnitDistortion()
    drive.loadFactoryPreset(.multiDistortedFunk)
    drive.preGain = -12
    let crush = AVAudioUnitDistortion()
    crush.loadFactoryPreset(.multiDecimated1)
    crush.preGain = -12
    let filter = AVAudioUnitEQ(numberOfBands: 1)
    let reverb = TrackReverb()
    reverb.wetDryMix = Float(settings.reverb * 100)

    let delay = AVAudioUnitDelay()
    delay.delayTime = 0.25
    delay.feedback = 22
    delay.lowPassCutoff = 9_000
    delay.wetDryMix = Float(settings.delay * 100)
    let effects: [AVAudioNode] = [eq, compressor, drive, crush, filter, reverb, delay]
    configureEffects(effects, settings: settings)
    return effects
}

private func setAudioUnitParameter(
    _ audioUnit: AudioUnit,
    id: AudioUnitParameterID,
    value: AudioUnitParameterValue
) {
    AudioUnitSetParameter(
        audioUnit,
        id,
        kAudioUnitScope_Global,
        0,
        value,
        0
    )
}

private func connectTrackChain(
    engine: AVAudioEngine,
    mixer: AVAudioMixerNode,
    effects: [AVAudioNode],
    format: AVAudioFormat
) {
    var previous: AVAudioNode = mixer
    for effect in effects {
        engine.connect(previous, to: effect, format: format)
        previous = effect
    }
    engine.connect(previous, to: engine.mainMixerNode, format: format)
}

func scheduledSegments(
    for clip: ClipModel,
    bpm: Double,
    fromBeat: Double
) -> [ScheduledAudioSegment] {
    guard bpm.isFinite, bpm > 0, clip.durationBeats.isFinite, clip.durationBeats > 0,
          clip.sourceDurationSeconds > 0, clip.sourceOffsetSeconds >= 0,
          clip.sourceOffsetSeconds < clip.sourceDurationSeconds,
          clip.endBeat > fromBeat else { return [] }
    let secondsPerBeat = 60 / bpm
    let clipStartSeconds = clip.startBeat * secondsPerBeat
    let clipDurationSeconds = clip.durationBeats * secondsPerBeat
    let fromSeconds = fromBeat * secondsPerBeat
    let visibleStart = max(clipStartSeconds, fromSeconds)
    let initialSkip = visibleStart - clipStartSeconds
    let sourceLength = clip.sourceRegionSeconds
    let playbackOffset = clip.playbackOffsetSeconds ?? 0

    if !clip.loopEnabled {
        let available = max(0, sourceLength - playbackOffset - initialSkip)
        let duration = min(available, clipDurationSeconds - initialSkip)
        guard duration > 0 else { return [] }
        return [ScheduledAudioSegment(
            url: clip.assetURL,
            timelineStartSeconds: visibleStart,
            sourceOffsetSeconds: clip.sourceOffsetSeconds + playbackOffset + initialSkip,
            durationSeconds: duration
        )]
    }

    var segments: [ScheduledAudioSegment] = []
    var timeline = visibleStart
    let clipEndSeconds = clipStartSeconds + clipDurationSeconds
    var sourcePhase = (initialSkip + playbackOffset).truncatingRemainder(dividingBy: sourceLength)

    while timeline < clipEndSeconds - 0.0001 {
        let availableInLoop = sourceLength - sourcePhase
        let duration = min(availableInLoop, clipEndSeconds - timeline)
        segments.append(ScheduledAudioSegment(
            url: clip.assetURL,
            timelineStartSeconds: timeline,
            sourceOffsetSeconds: clip.sourceOffsetSeconds + sourcePhase,
            durationSeconds: duration
        ))
        timeline += duration
        sourcePhase = 0
    }
    return segments
}

private func scheduleFile(_ segment: ScheduledAudioSegment, file: AVAudioFile,
                          on player: AVAudioPlayerNode, at time: AVAudioTime? = nil) throws {
    let start = AVAudioFramePosition((segment.sourceOffsetSeconds * file.processingFormat.sampleRate).rounded())
    let count = min(file.length - start, AVAudioFramePosition((segment.durationSeconds * file.processingFormat.sampleRate).rounded()))
    guard start >= 0, count > 0, count <= Int64(UInt32.max) else { throw StudioError.invalidAudio }
    player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count), at: time)
}

enum TransportClock {
    static func beat(now: UInt64, anchor: UInt64, start: Double, bpm: Double) -> Double {
        let seconds = now > anchor ? AVAudioTime.seconds(forHostTime: now - anchor) : 0
        return start + seconds * bpm / 60
    }
}

private final class TrackReverb: AVAudioUnitReverb {
    private var loadedSpace: ReverbSpace?
    func setSpace(_ space: ReverbSpace) {
        guard loadedSpace != space else { return }
        switch space {
        case .room: loadFactoryPreset(.smallRoom)
        case .plate: loadFactoryPreset(.plate)
        case .hall: loadFactoryPreset(.mediumHall)
        case .cathedral: loadFactoryPreset(.cathedral)
        }
        loadedSpace = space
    }
}

private func configureEffects(_ effects: [AVAudioNode], settings: EffectSettings) {
    guard effects.count == 7, let eq = effects[0] as? AVAudioUnitEQ,
          let compressor = effects[1] as? AVAudioUnitEffect,
          let drive = effects[2] as? AVAudioUnitDistortion, let crush = effects[3] as? AVAudioUnitDistortion,
          let filter = effects[4] as? AVAudioUnitEQ,
          let reverb = effects[5] as? TrackReverb, let delay = effects[6] as? AVAudioUnitDelay else { return }
    for (band, gain) in zip(eq.bands, [settings.lowGain, settings.midGain, settings.highGain]) { band.gain = Float(gain) }
    compressor.bypass = settings.compression == 0
    setAudioUnitParameter(compressor.audioUnit, id: AudioUnitParameterID(kDynamicsProcessorParam_Threshold), value: Float(-5 - settings.compression * 35))
    setAudioUnitParameter(compressor.audioUnit, id: AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom), value: Float(40 - settings.compression * 35))
    reverb.setSpace(settings.reverbSpace)
    // Loading a factory space can reset mix parameters.
    reverb.wetDryMix = Float(settings.reverb * 100)
    delay.wetDryMix = Float(settings.delay * 100)
    delay.delayTime = max(0.01, min(2, settings.delayTime))
    delay.feedback = Float(max(0, min(0.85, settings.delayFeedback)) * 100)
    drive.bypass = settings.drive <= 0
    drive.wetDryMix = Float(max(0, min(1, settings.drive)) * 100)
    crush.bypass = settings.bitCrush <= 0
    crush.wetDryMix = Float(max(0, min(1, settings.bitCrush)) * 100)
    let band = filter.bands[0]
    band.bypass = settings.filterMode == .off
    switch settings.filterMode {
    case .off, .lowPass: band.filterType = .resonantLowPass
    case .highPass: band.filterType = .resonantHighPass
    case .bandPass: band.filterType = .bandPass
    }
    band.frequency = Float(max(20, min(20_000, settings.filterCutoff)))
    band.bandwidth = Float(2 - max(0, min(1, settings.filterResonance)) * 1.7)
}
