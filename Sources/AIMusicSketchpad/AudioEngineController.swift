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
    private var playheadTask: Task<Void, Never>?
    private var tracks: [UUID: PlaybackTrack] = [:]
    private var anchorHostTime: UInt64 = 0
    private var startBeat = 0.0
    private var bpm = 120.0
    private var playbackProject: StudioProject?
    private var automatedTracks: [TrackModel] = []
    var onFailure: ((String) -> Void)?

    // Read-only counters also let the stress test catch loop/player explosions.
    var playerCount: Int { tracks.values.reduce(0) { $0 + $1.clips.count } }
    var activePlayerCount: Int { tracks.values.reduce(0) { $0 + $1.clips.filter { $0.file != nil }.count } }
    var liveInstrumentCount: Int { tracks.values.reduce(0) { $0 + $1.liveInstruments.count } }

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
        let endBeat = recording ? Double.infinity : project.lengthBeats
        var playbackTracks: [UUID: PlaybackTrack] = [:]
        for baseTrack in project.tracks {
            let track = baseTrack.automated(at: fromBeat * 60 / project.bpm)
            guard track.clips.contains(where: { $0.endBeat > fromBeat && $0.startBeat < endBeat }) else { continue }
            let runtime = PlaybackTrack(track: track, engine: newEngine, format: format, fromBeat: fromBeat, endBeat: endBeat)
            runtime.apply(track, audible: !track.isMuted && (!soloed || track.isSolo))
            if runtime.audible { try runtime.schedule(bpm: project.bpm, fromBeat: fromBeat, sampleRate: project.sampleRate) }
            playbackTracks[track.id] = runtime
        }

        // Keep an empty/all-muted transport valid, including recording into a new project.
        _ = newEngine.mainMixerNode
        newEngine.prepare()
        try newEngine.start()
        // Establish the shared clock only after graph construction and engine startup.
        let anchorHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15)

        let startTime = AVAudioTime(hostTime: anchorHostTime)
        playbackTracks.values.filter(\.audible).forEach { $0.play(at: startTime) }

        engine = newEngine
        tracks = playbackTracks
        playheadBeat = fromBeat
        isPlaying = true
        self.anchorHostTime = anchorHostTime
        self.startBeat = fromBeat
        self.bpm = project.bpm
        playbackProject = project.preparedForPlayback()
        refreshAutomatedTracks()
        startPlayhead(project: project, recording: recording)
        return anchorHostTime
    }

    func stop(resetPlayhead: Bool = false) {
        if isPlaying { playheadBeat = currentBeat }
        playheadTask?.cancel()
        playheadTask = nil
        tracks.values.forEach { $0.stop() }
        engine?.stop()
        engine = nil
        playbackProject = nil
        automatedTracks.removeAll()
        tracks.removeAll()
        isPlaying = false
        if resetPlayhead { playheadBeat = 0 }
    }

    func updateMix(project: StudioProject) {
        guard isPlaying else { return }
        let snapshot = project.preparedForPlayback()
        playbackProject = snapshot
        refreshAutomatedTracks()
        let seconds = currentBeat * 60 / bpm
        let soloed = project.tracks.contains(where: \.isSolo)
        do {
            for original in snapshot.tracks {
                guard let runtime = tracks[original.id] else { continue }
                let audible = !original.isMuted && (!soloed || original.isSolo)
                let wasAudible = runtime.audible
                if wasAudible && !audible { runtime.stop() }
                runtime.apply(original.automated(at: seconds, presorted: true), audible: audible)
                if !wasAudible && audible {
                    // Start only the newly audible track, on the existing transport clock.
                    let resumeHost = max(anchorHostTime, mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15))
                    let resumeBeat = TransportClock.beat(now: resumeHost, anchor: anchorHostTime, start: startBeat, bpm: bpm)
                    try runtime.schedule(bpm: bpm, fromBeat: resumeBeat, sampleRate: project.sampleRate)
                    runtime.play(at: AVAudioTime(hostTime: resumeHost))
                }
            }
        } catch {
            stop()
            onFailure?(error.localizedDescription)
        }
    }

    private func refreshAutomatedTracks() {
        guard let snapshot = playbackProject else { automatedTracks = []; return }
        let soloed = snapshot.tracks.contains(where: \.isSolo)
        automatedTracks = snapshot.tracks.filter {
            !$0.isMuted && (!soloed || $0.isSolo) && $0.automation?.isEmpty == false
        }
    }

    private func applyAutomation(seconds: Double) {
        for original in automatedTracks {
            guard let runtime = tracks[original.id] else { continue }
            runtime.apply(original.automated(at: seconds, presorted: true), audible: true)
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
                let interval = self?.automatedTracks.isEmpty == false ? 16 : 34
                do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                let beat = self.currentBeat
                self.applyAutomation(seconds: beat * 60 / self.bpm)
                if !recording && beat >= project.lengthBeats {
                    self.stop()
                    self.playheadBeat = project.lengthBeats
                    return
                }
                // Automation stays at ~60 Hz; visual transport needs only ~30 Hz.
                if beat - self.playheadBeat >= self.bpm / 60 / 30 { self.playheadBeat = beat }
            }
        }
    }
}

/// One player/file per clip, not per loop repetition. Overlapping clips remain independent.
private final class PlaybackClip {
    let clip: ClipModel
    let player = AVAudioPlayerNode()
    var file: AVAudioFile?
    init(_ clip: ClipModel) { self.clip = clip }

    func schedule(bpm: Double, fromBeat: Double, sampleRate: Double, endBeat: Double) throws {
        let segments = scheduledSegments(for: clip, bpm: bpm, fromBeat: fromBeat, toBeat: endBeat)
        guard !segments.isEmpty else { return }
        let file = try AVAudioFile(forReading: clip.assetURL)
        for segment in segments {
            let frame = AVAudioFramePosition(((segment.timelineStartSeconds - fromBeat * 60 / bpm) * sampleRate).rounded())
            try scheduleFile(segment, file: file, on: player, at: AVAudioTime(sampleTime: max(0, frame), atRate: sampleRate))
        }
        self.file = file
    }
    func stop() { player.stop(); file = nil }
}

private final class PlaybackTrack {
    let mixer = AVAudioMixerNode()
    let effects: [AVAudioNode]
    let clips: [PlaybackClip]
    private var lastSettings: EffectSettings?
    private var mixConfigured = false
    private(set) var audible = false
    private let endBeat: Double
    private let sourceTrack: TrackModel
    private weak var engine: AVAudioEngine?
    private let format: AVAudioFormat
    private var currentTrack: TrackModel
    private var fromSeconds = 0.0
    private var rate = 48_000.0
    private(set) var liveInstruments: [LiveSurgeInstrument] = []

    init(track: TrackModel, engine: AVAudioEngine, format: AVAudioFormat, fromBeat: Double, endBeat: Double) {
        self.endBeat = endBeat
        self.sourceTrack = track
        self.currentTrack = track
        self.engine = engine
        self.format = format
        effects = makeEffects(settings: track.effects)
        clips = track.clips.filter {
            $0.endBeat > fromBeat && $0.startBeat < endBeat && !(track.surgePlayback?.enabled == true && $0.supportsLiveSurge)
        }.map(PlaybackClip.init)
        engine.attach(mixer)
        effects.forEach(engine.attach)
        connectTrackChain(engine: engine, mixer: mixer, effects: effects, format: format)
        for clip in clips {
            engine.attach(clip.player)
            engine.connect(clip.player, to: mixer, format: format)
        }
    }
    func apply(_ track: TrackModel, audible: Bool) {
        currentTrack = track
        if let settings = track.surgePlayback { liveInstruments.forEach { $0.apply(settings) } }
        let volume = audible ? Float(track.volume) : 0
        if mixer.outputVolume != volume { mixer.outputVolume = volume }
        if mixer.pan != Float(track.pan) { mixer.pan = Float(track.pan) }
        if !audible {
            if self.audible || !mixConfigured {
                effects.compactMap { $0 as? AVAudioUnitEffect }.forEach { $0.bypass = true }
            }
            lastSettings = nil
        } else if lastSettings != track.effects {
            configureEffects(effects, settings: track.effects, previous: lastSettings)
            lastSettings = track.effects
        }
        self.audible = audible
        mixConfigured = true
    }
    func schedule(bpm: Double, fromBeat: Double, sampleRate: Double) throws {
        fromSeconds = fromBeat * 60 / bpm
        rate = sampleRate
        // Muted tracks never reach this path at startup, so they load no synths.
        if liveInstruments.isEmpty, sourceTrack.surgePlayback?.enabled == true, let engine {
            let eligible = sourceTrack.clips.filter { $0.supportsLiveSurge && $0.endBeat > fromBeat && $0.startBeat < endBeat }
            let groups = Dictionary(grouping: eligible, by: { $0.instrumentAddOn! })
            for (configuration, clips) in groups {
                let instrument = try LiveSurgeInstrument(configuration: configuration, clips: clips, bpm: bpm, endBeat: endBeat)
                engine.attach(instrument.unit)
                engine.connect(instrument.unit, to: mixer, format: format)
                if let settings = currentTrack.surgePlayback { instrument.apply(settings) }
                liveInstruments.append(instrument)
            }
        }
        for clip in clips { try clip.schedule(bpm: bpm, fromBeat: fromBeat, sampleRate: sampleRate, endBeat: endBeat) }
    }
    func play(at time: AVAudioTime) {
        clips.filter { $0.file != nil }.forEach { $0.player.play(at: time) }
        liveInstruments.forEach { $0.play(at: time, fromSeconds: fromSeconds, sampleRate: rate) }
    }
    func stop() {
        clips.forEach { $0.stop() }
        liveInstruments.forEach { $0.stop() }
        // A bypassed delay/reverb must not replay its frozen pre-mute tail on unmute.
        effects.forEach { $0.reset() }
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
        var chains: [(TrackModel, PlaybackTrack)] = []

        for baseTrack in project.preparedForPlayback().tracks {
            guard !baseTrack.isMuted, !soloed || baseTrack.isSolo,
                  baseTrack.clips.contains(where: { $0.startBeat < project.lengthBeats }) else { continue }
            let track = baseTrack.automated(at: 0, presorted: true)
            let runtime = PlaybackTrack(track: track, engine: engine, format: format, fromBeat: 0, endBeat: project.lengthBeats)
            runtime.apply(track, audible: true)
            try runtime.schedule(bpm: project.bpm, fromBeat: 0, sampleRate: project.sampleRate)
            chains.append((baseTrack, runtime))
        }

        _ = engine.mainMixerNode
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: 4_096
        )
        try engine.start()
        let zero = AVAudioTime(sampleTime: 0, atRate: project.sampleRate)
        chains.forEach { $0.1.play(at: zero) }
        defer {
            chains.forEach { $0.1.stop() }
            engine.stop()
            engine.disableManualRenderingMode()
        }

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
            for (base, runtime) in automatedChains {
                runtime.apply(base.automated(at: seconds, presorted: true), audible: true)
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
    fromBeat: Double,
    toBeat: Double = .infinity
) -> [ScheduledAudioSegment] {
    guard bpm.isFinite, bpm > 0, clip.durationBeats.isFinite, clip.durationBeats > 0,
          clip.sourceDurationSeconds > 0, clip.sourceOffsetSeconds >= 0,
          clip.sourceOffsetSeconds < clip.sourceDurationSeconds,
          clip.endBeat > fromBeat else { return [] }
    let secondsPerBeat = 60 / bpm
    let leading = clip.leadingSilenceSeconds ?? 0
    let clipStartSeconds = clip.startBeat * secondsPerBeat + leading
    let clipDurationSeconds = max(0, min(clip.durationBeats * secondsPerBeat - leading - (clip.trailingSilenceSeconds ?? 0),
                                         toBeat * secondsPerBeat - clipStartSeconds))
    guard clipDurationSeconds > 0 else { return [] }
    let fromSeconds = fromBeat * secondsPerBeat
    let visibleStart = max(clipStartSeconds, fromSeconds)
    let initialSkip = visibleStart - clipStartSeconds
    guard initialSkip < clipDurationSeconds else { return [] }
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

private func configureEffects(_ effects: [AVAudioNode], settings: EffectSettings, previous: EffectSettings? = nil) {
    guard effects.count == 7, let eq = effects[0] as? AVAudioUnitEQ,
          let compressor = effects[1] as? AVAudioUnitEffect,
          let drive = effects[2] as? AVAudioUnitDistortion, let crush = effects[3] as? AVAudioUnitDistortion,
          let filter = effects[4] as? AVAudioUnitEQ,
          let reverb = effects[5] as? TrackReverb, let delay = effects[6] as? AVAudioUnitDelay else { return }
    if previous?.lowGain != settings.lowGain || previous?.midGain != settings.midGain || previous?.highGain != settings.highGain {
        for (band, gain) in zip(eq.bands, [settings.lowGain, settings.midGain, settings.highGain]) { band.gain = Float(gain) }
        eq.bypass = settings.lowGain == 0 && settings.midGain == 0 && settings.highGain == 0
    }
    if previous?.compression != settings.compression {
        compressor.bypass = settings.compression == 0
        setAudioUnitParameter(compressor.audioUnit, id: AudioUnitParameterID(kDynamicsProcessorParam_Threshold), value: Float(-5 - settings.compression * 35))
        setAudioUnitParameter(compressor.audioUnit, id: AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom), value: Float(40 - settings.compression * 35))
    }
    if previous?.reverbSpace != settings.reverbSpace || previous?.reverb != settings.reverb {
        reverb.setSpace(settings.reverbSpace)
        reverb.wetDryMix = Float(settings.reverb * 100)
        reverb.bypass = settings.reverb <= 0
    }
    if previous?.delay != settings.delay {
        delay.wetDryMix = Float(settings.delay * 100)
        delay.bypass = settings.delay <= 0
    }
    if previous?.delayTime != settings.delayTime { delay.delayTime = max(0.01, min(2, settings.delayTime)) }
    if previous?.delayFeedback != settings.delayFeedback { delay.feedback = Float(max(0, min(0.85, settings.delayFeedback)) * 100) }
    if previous?.drive != settings.drive {
        drive.bypass = settings.drive <= 0
        drive.wetDryMix = Float(max(0, min(1, settings.drive)) * 100)
    }
    if previous?.bitCrush != settings.bitCrush {
        crush.bypass = settings.bitCrush <= 0
        crush.wetDryMix = Float(max(0, min(1, settings.bitCrush)) * 100)
    }
    let band = filter.bands[0]
    if previous?.filterMode != settings.filterMode {
        filter.bypass = settings.filterMode == .off
        band.bypass = settings.filterMode == .off
        switch settings.filterMode {
        case .off, .lowPass: band.filterType = .resonantLowPass
        case .highPass: band.filterType = .resonantHighPass
        case .bandPass: band.filterType = .bandPass
        }
    }
    if previous?.filterCutoff != settings.filterCutoff { band.frequency = Float(max(20, min(20_000, settings.filterCutoff))) }
    if previous?.filterResonance != settings.filterResonance { band.bandwidth = Float(2 - max(0, min(1, settings.filterResonance)) * 1.7) }
}
