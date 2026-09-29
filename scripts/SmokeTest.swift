import AVFoundation
import Darwin
import Foundation
import Combine

@main
struct SmokeTest {
    static func main() async {
        do {
            try await run()
            print("PASS: native instruments, WAV export, delayed playback, trim/loop/split, conversion, note capture, playhead observation, and project compatibility")
        } catch {
            fputs("Smoke test failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let studio = StudioModel()
        var observed = 0
        let subscription = studio.objectWillChange.sink { observed += 1 }
        studio.audio.playheadBeat = 12
        try require(observed > 0, "nested playhead updates never reach the UI")
        withExtendedLifetime(subscription) {}
        let anchor = AVAudioTime.hostTime(forSeconds: 10)
        try require(TransportClock.beat(now: anchor - 1, anchor: anchor, start: 4, bpm: 120) == 4,
                    "playhead advances before audio starts")
        let beat = TransportClock.beat(now: anchor + AVAudioTime.hostTime(forSeconds: 1), anchor: anchor, start: 4, bpm: 120)
        try require(abs(beat - 6) < 0.0001, "host-time cursor rate is wrong")

        var capture = NoteCapture()
        capture.on(60, velocity: 100, beat: 0)
        capture.on(64, velocity: 90, beat: 0.5)
        capture.off(60, beat: 1)
        let recorded = capture.finish(at: 2)
        try require(recorded.count == 2 && recorded[0].durationBeats == 1 && recorded[1].durationBeats == 1.5,
                    "polyphonic recording or held-note finalization is wrong")

        var original = ClipModel(name: "test", assetPath: "/unused.wav", startBeat: 0,
                                 durationBeats: 16, sourceDurationSeconds: 4, loopEnabled: true)
        let pair = try ClipEditing.split(original, at: 3, bpm: 120)
        let rightSegments = scheduledSegments(for: pair.1, bpm: 120, fromBeat: 3)
        try require(abs(rightSegments[0].sourceOffsetSeconds - 1.5) < 0.0001, "split lost loop phase")
        try require(abs(rightSegments[1].sourceOffsetSeconds) < 0.0001, "split repeats a shortened loop")
        let trimmed = try ClipEditing.trim(original, from: 2, to: 6, bpm: 120)
        let looped = ClipEditing.loop(trimmed, times: 2, bpm: 120)
        let segments = scheduledSegments(for: looped, bpm: 120, fromBeat: 0)
        try require(segments.count == 2 && abs(segments[0].sourceOffsetSeconds - 1) < 0.0001
                    && abs(segments[1].sourceOffsetSeconds - 1) < 0.0001, "looping a trim uses the wrong source")
        let wrapped = try ClipEditing.trim(original, from: 6, to: 10, bpm: 120)
        try require(ClipEditing.needsLoopRender(wrapped, bpm: 120), "wrapped trims must consolidate before repeating")
        try require(!ClipEditing.needsLoopRender(original, bpm: 120), "whole cycles don't need consolidation")
        original.sourceOffsetSeconds = 8
        try require(scheduledSegments(for: original, bpm: 120, fromBeat: 0).isEmpty, "invalid offsets should not crash")

        let motif = RuleBasedComposer.compose(part: .drums, bars: 2, key: "C minor", prompt: "house")
        let expanded = try LoopNotes.expand(motif, motifBeats: 8, totalBeats: 32, part: .drums)
        try require(expanded.count == motif.count * 4 && expanded.contains { $0.startBeat >= 28 }, "generation leaves empty bars")
        do {
            _ = try LoopNotes.expand([MIDINote(pitch: 60, velocity: 1, startBeat: 0, durationBeats: 1)], motifBeats: 8, totalBeats: 32, part: .bass)
            throw SmokeFailure("one note was accepted as an entire loop")
        } catch is MessageError {}

        let encoded = try JSONEncoder().encode(StudioProject())
        let decoded = try JSONDecoder().decode(StudioProject.self, from: encoded)
        try require(decoded.tracks.count == 4, "project round-trip failed")
        studio.project.tracks[0].clips = [trimmed]
        studio.setTempo(90)
        try require(studio.project.tracks[0].clips[0].durationBeats == 3, "tempo edit changed real audio duration")
        var loaded = StudioProject()
        loaded.bpm = 100
        loaded.tracks[0].clips = [trimmed]
        studio.project = loaded
        try require(studio.project.tracks[0].clips[0].durationBeats == 4, "loading a different tempo rescaled saved clips")
        for part in [MusicalPart.drums, .bass, .chords, .melody] {
            let notes = RuleBasedComposer.compose(
                part: part,
                bars: 4,
                key: "C minor",
                prompt: "warm organic house"
            )
            try require(!notes.isEmpty, "\(part.title) contained no notes")
            try require(notes.allSatisfy { $0.startBeat >= 0 && $0.startBeat < 16 }, "note outside timeline")
            try require(notes.allSatisfy { (0..<128).contains($0.pitch) }, "invalid MIDI pitch")
            let url = temporaryURL("\(part.rawValue).wav")
            _ = try MIDIRenderer.render(notes: notes, part: part, bpm: 120, bars: 4, sampleRate: 48_000, to: url)
            try assertAudibleStereo48k(url)
        }

        if CommandLine.arguments.contains("--local-kits") {
            try assertCompleteDrumKit(.house, pitches: [36, 37, 38, 39, 40, 41, 42, 44, 46, 48, 49, 50, 51, 52, 53, 54, 58])
            try assertCompleteDrumKit(.deepHouse, pitches: Array(36...58))
            try assertCompleteDrumKit(.tr909, pitches: [36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 48, 49, 51, 53, 56])
            for instrument in [KeyboardInstrument.house, .deepHouse, .tr909, .oriental, .oud] {
                let pitches = instrument.isPercussion ? [36, 38, 42, 46] : [48, 52, 55, 60]
                let notes = pitches.enumerated().map { index, pitch in
                    MIDINote(pitch: pitch, velocity: 0.8, startBeat: Double(index), durationBeats: 0.5)
                }
                let url = temporaryURL("\(instrument.id).wav")
                _ = try MIDIRenderer.render(notes: notes, instrument: instrument, bpm: 120,
                                           durationBeats: 5, sampleRate: 48_000, to: url)
                try assertAudibleStereo48k(url)
                print("PASS: \(instrument.rawValue) loaded and rendered from installed Apple library")
            }
        }

        let source = temporaryURL("source.wav")
        let mix = temporaryURL("mix.wav")
        let notes = RuleBasedComposer.compose(
            part: .bass,
            bars: 1,
            key: "C minor",
            prompt: "deep"
        )
        let duration = try MIDIRenderer.render(
            notes: notes,
            part: .bass,
            bpm: 120,
            bars: 1,
            sampleRate: 48_000,
            to: source
        )
        try assertAudibleStereo48k(source)

        var project = StudioProject()
        project.lengthBeats = 4
        project.tracks = [TrackModel.new(index: 0)]
        project.tracks[0].effects.compression = 0.35
        project.tracks[0].effects.reverb = 0.12
        project.tracks[0].clips = [
            ClipModel(
                name: "Bass",
                assetPath: source.path,
                startBeat: 0,
                durationBeats: 4,
                sourceDurationSeconds: duration
            )
        ]
        let audio = AudioEngineController()
        try await audio.export(project: project, to: mix)
        try assertAudibleStereo48k(mix)

        project.lengthBeats = 8
        project.tracks[0].clips[0].startBeat = 4
        project.tracks[0].effects = EffectSettings()
        let delayed = temporaryURL("delayed.wav")
        try await audio.export(project: project, to: delayed)
        let delayedFile = try AVAudioFile(forReading: delayed)
        try require(abs(Double(delayedFile.length) - 192_000) < 2, "export duration is wrong")
        let delayBuffer = AVAudioPCMBuffer(pcmFormat: delayedFile.processingFormat, frameCapacity: 192_000)!
        try delayedFile.read(into: delayBuffer)
        let samples = delayBuffer.floatChannelData![0]
        var before: Float = 0, after: Float = 0
        for i in 0..<90_000 { before = max(before, abs(samples[i])) }
        for i in 100_000..<180_000 { after = max(after, abs(samples[i])) }
        try require(before < 0.00001 && after > 0.001, "audio clip is not scheduled at its timeline beat")

        // Exercise real-time transport without playing sound through the speakers.
        var muted = project
        muted.tracks[0].isMuted = true
        try audio.play(project: muted, fromBeat: 2)
        try await Task.sleep(for: .milliseconds(400))
        try require(audio.isPlaying && audio.playheadBeat > 2.1, "live transport cursor did not advance")
        try audio.play(project: muted, fromBeat: 6)
        try await Task.sleep(for: .milliseconds(250))
        try require(audio.playheadBeat >= 6 && audio.playheadBeat < 7, "seek retained the old playhead task")
        audio.stop()
        let stopped = audio.playheadBeat
        try await Task.sleep(for: .milliseconds(60))
        try require(audio.playheadBeat == stopped, "stopped cursor kept moving")

        var wrappingClip = ClipModel(name: "wrapped", assetPath: source.path, startBeat: 0,
                                     durationBeats: 8, sourceDurationSeconds: duration, loopEnabled: true)
        wrappingClip = try ClipEditing.trim(wrappingClip, from: 3, to: 5, bpm: 120)
        studio.project = StudioProject()
        studio.project.tracks[0].clips = [wrappingClip]
        studio.loopClip(wrappingClip.id)
        for _ in 0..<100 where studio.isBusy { try await Task.sleep(for: .milliseconds(50)) }
        try require(!studio.isBusy && studio.alertMessage == nil, "wrapped-loop consolidation failed")
        let wrappedResult = studio.project.tracks[0].clips[0]
        let wrappedSegments = scheduledSegments(for: wrappedResult, bpm: 120, fromBeat: 0)
        try require(wrappedSegments.count == 2 && wrappedSegments.allSatisfy { $0.sourceOffsetSeconds == 0 },
                    "wrapped selection did not repeat from its own start")

        let monoURL = temporaryURL("mono44100.wav")
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 44_100)!
        mono.frameLength = 44_100
        for i in 0..<44_100 { mono.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 220 / 44_100) * 0.2) }
        do {
            let file = try AVAudioFile(forWriting: monoURL, settings: monoFormat.settings)
            try file.write(from: mono)
        }
        let converted = temporaryURL("converted.wav")
        try AssetManager.shared.convert(sourceURL: monoURL, outputURL: converted, sampleRate: 48_000)
        try assertAudibleStereo48k(converted)
        let convertedFile = try AVAudioFile(forReading: converted)
        try require(abs(Double(convertedFile.length) - 48_000) < 4, "converter lost final audio samples")
        try await featureChecks(source: converted)

        if CommandLine.arguments.contains("--track-workflow") {
            let workflow = StudioModel()
            let original = ClipModel(name: "My recorded bass", assetPath: source.path, startBeat: 4,
                                     durationBeats: 4, sourceDurationSeconds: duration)
            workflow.project.tracks[0].clips = [original]
            let targetID = workflow.project.tracks[0].id
            workflow.beginGeneration(trackID: targetID, useTrack: true)
            workflow.generationRequest.bars = 1
            workflow.generateMusic()
            var lastStatus = ""
            for _ in 0..<240 where workflow.isBusy {
                if workflow.status != lastStatus { print(workflow.status); lastStatus = workflow.status }
                try await Task.sleep(for: .milliseconds(500))
            }
            if workflow.isBusy { workflow.cancelGeneration(); throw SmokeFailure("track AI workflow timed out") }
            try require(workflow.alertMessage == nil, "track AI workflow failed: \(workflow.alertMessage ?? "")")
            let clips = workflow.project.tracks[0].clips
            try require(clips.count == 2 && clips[0] == original && clips[1].startBeat == original.endBeat,
                        "AI replaced or overlapped the source performance")
            try require(clips[1].generationReference?.trackID == targetID && workflow.project.tracks[1].clips.isEmpty,
                        "AI used or wrote the wrong track")
            try assertAudibleStereo48k(clips[1].assetURL)
            print("PASS: complete per-track AI action preserves original, records provenance, appends audible new take")
        }

        if CommandLine.arguments.contains("--audio-model") {
            let generator = TextAudioGenerator()
            let generated = temporaryURL("musicgen.wav")
            try await generator.generate(prompt: "Dry electronic drum loop, kick and closed hi hats, no vocals",
                                         seconds: 2, seed: 42, output: generated) { print($0) }
            let generatedFile = try AVAudioFile(forReading: generated)
            try require(generatedFile.length == 64_000 && generatedFile.fileFormat.sampleRate == 32_000,
                        "model output is not two seconds of native 32 kHz audio")
            let normalized = temporaryURL("musicgen48k.wav")
            try AssetManager.shared.convert(sourceURL: generated, outputURL: normalized, sampleRate: 48_000)
            try assertAudibleStereo48k(normalized)
            print("PASS: Swift → local MusicGen → WAV → timeline-format conversion")

            let continuation = temporaryURL("conditioned.wav")
            try await generator.generate(prompt: "Continue this bass part with a melodic variation", seconds: 2,
                                         seed: 42, output: continuation, referenceAudio: source) { print($0) }
            let continuationFile = try AVAudioFile(forReading: continuation)
            try require(continuationFile.length == 64_000, "conditioned output includes the original prompt or wrong duration")
            let continued48 = temporaryURL("conditioned48.wav")
            try AssetManager.shared.convert(sourceURL: continuation, outputURL: continued48, sampleRate: 48_000)
            try assertAudibleStereo48k(continued48)
            print("PASS: recorded/rendered track audio → MusicGen continuation → new-audio-only output")
            let cancellation = Task {
                try await generator.generate(prompt: "Drum loop", seconds: 20, seed: 1,
                                             output: temporaryURL("cancelled.wav")) { _ in }
            }
            try await Task.sleep(for: .milliseconds(500))
            cancellation.cancel()
            do {
                try await cancellation.value
                throw SmokeFailure("cancelled generation completed without cancellation")
            } catch is CancellationError {
                print("PASS: cancelling generation stops the worker")
            }
        }
    }

    @MainActor private static func featureChecks(source: URL) async throws {
        let studio = StudioModel()
        let clip = ClipModel(name: "Recorded source", assetPath: source.path, startBeat: 0,
                             durationBeats: 8, sourceDurationSeconds: 1, loopEnabled: true)
        studio.project.tracks[0].clips = [clip]
        studio.copyClip(clip.id)
        studio.selectedTrackID = studio.project.tracks[1].id
        studio.audio.playheadBeat = 10
        studio.pasteClip()
        let pasted = studio.project.tracks[1].clips[0]
        try require(pasted.id != clip.id && pasted.assetPath == clip.assetPath && pasted.startBeat == 10 && pasted.loopEnabled,
                    "copy/paste changed source or lost trim/loop settings")
        studio.duplicateClip(pasted.id)
        try require(studio.project.tracks[1].clips[1].startBeat == pasted.endBeat, "duplicate placement is wrong")
        let destination = studio.project.tracks[2].id
        studio.snapEnabled = false
        studio.moveClip(id: pasted.id, on: destination, to: 3.123)
        try require(studio.project.tracks[2].clips[0].startBeat == 3.123 && studio.project.tracks[1].clips.count == 1,
                    "cross-track drag or free positioning failed")
        studio.visibleAutomation[studio.project.tracks[0].id] = .volume
        try require(studio.dragDestination(trackID: studio.project.tracks[0].id, deltaY: 180) == studio.project.tracks[1].id,
                    "cross-track drag ignores expanded automation lanes")

        let lane = AutomationLane(parameter: .volume, points: [AutomationPoint(seconds: 0, value: -1),
                                                              AutomationPoint(seconds: 2, value: 0)])
        try require(abs(lane.value(at: 1) + 0.5) < 0.00001 && lane.value(at: 3) == 0, "automation interpolation failed")
        var mix = StudioProject()
        mix.tracks = [TrackModel.new(index: 0)]
        mix.lengthBeats = 8
        mix.tracks[0].clips = [clip]
        mix.tracks[0].automation = [AutomationLane(parameter: .volume, points: [
            AutomationPoint(seconds: 0, value: -1), AutomationPoint(seconds: 1, value: -1),
            AutomationPoint(seconds: 1.05, value: 0)])]
        let output = temporaryURL("automated.wav")
        try OfflineMixRenderer.render(project: mix, to: output)
        let file = try AVAudioFile(forReading: output)
        let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: data)
        let samples = data.floatChannelData![0]
        var quiet: Float = 0, audible: Float = 0
        for i in 1000..<40_000 { quiet = max(quiet, abs(samples[i])) }
        for i in 100_000..<140_000 { audible = max(audible, abs(samples[i])) }
        try require(quiet < 0.00001 && audible > 0.01, "automation export failed: quiet peak=\(quiet), audible peak=\(audible)")

        // A muted selected track remains usable as AI input; unrelated assets
        // are deliberately invalid so any accidental full-mix render fails.
        mix.tracks[0].isMuted = true
        var other = TrackModel.new(index: 1)
        other.isSolo = true
        other.clips = [ClipModel(name: "Do not read", assetPath: "/missing-other-track.wav", startBeat: 0,
                                durationBeats: 8, sourceDurationSeconds: 4)]
        mix.tracks.append(other)
        let reference = try TrackAudioReference(project: mix, trackID: mix.tracks[0].id, start: 3, end: 5)
        try require(reference.project.tracks.count == 1 && !reference.project.tracks[0].isMuted,
                    "AI input must include only the chosen track regardless of mute/solo")
        let metadata = try reference.render(to: temporaryURL("reference.wav"))
        try assertAudibleStereo48k(URL(fileURLWithPath: metadata.assetPath))
        let referenceFile = try AVAudioFile(forReading: URL(fileURLWithPath: metadata.assetPath))
        try require(referenceFile.length == 48_000, "reference range included audio outside the selection")
        mix.tracks[0].generationSettings = GenerationRequest()
        mix.tracks[0].generationSettings?.input = .trackAudio
        mix.tracks[0].clips[0].generationReference = metadata
        let saved = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(mix))
        try require(saved == mix, "automation / per-track AI / reference metadata was lost on save")
        print("PASS: cross-track copy/paste/drag, automation interpolation and audible export, single-track AI input, saved metadata")
    }

    private static func assertCompleteDrumKit(_ kit: KeyboardInstrument, pitches: [Int]) throws {
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try sampler.loadInstrument(at: URL(fileURLWithPath: kit.libraryPath!))
        let originalReferences = sampler.auAudioUnit.fullState!["file-references"] as! [String: String]
        try MIDIRenderer.loadInstrument(kit, into: sampler)
        let state = sampler.auAudioUnit.fullState!
        let instrument = state["Instrument"] as! [String: Any]
        let layers = instrument["Layers"] as! [[String: Any]]
        try require(layers.allSatisfy { ($0["output"] as? Int ?? 0) == 0 }, "\(kit) has disconnected outputs")
        let zones = layers.flatMap { $0["Zones"] as! [[String: Any]] }
        try require(Set(zones.compactMap { $0["min key"] as? Int }) == Set(pitches), "\(kit) lost drum zones")
        try require(zones.count == pitches.count, "\(kit) has duplicate or missing drum zones")

        if kit == .tr909 || kit == .deepHouse {
            let refs = state["file-references"] as! [String: String]
            let changedReferences = refs.filter { originalReferences[$0.key] != $0.value }
            try require(changedReferences.count == 2, "\(kit) expected two compatibility samples")
            for (key, path) in changedReferences {
                let originalURL = URL(fileURLWithPath: originalReferences[key]!)
                let cachedURL = URL(fileURLWithPath: path)
                let original = try AVAudioFile(forReading: originalURL)
                let cached = try AVAudioFile(forReading: cachedURL)
                try require(original.length == cached.length && original.processingFormat == cached.processingFormat,
                            "\(kit) compatibility conversion changed format or duration")
                let originalPCM = try completePCM(original)
                let cachedPCM = try completePCM(cached)
                try require(originalPCM == cachedPCM, "\(kit) compatibility conversion changed PCM samples")
            }
        }

        var sounds: [[Float]] = []
        for pitch in pitches {
            let url = temporaryURL("\(kit.id)-note-\(pitch).wav")
            _ = try MIDIRenderer.render(notes: [MIDINote(pitch: pitch, velocity: 0.8, startBeat: 0, durationBeats: 0.8)],
                                       instrument: kit, bpm: 120, durationBeats: 1, sampleRate: 48_000, to: url)
            do { try assertAudibleStereo48k(url) }
            catch { throw SmokeFailure("\(kit.rawValue) note \(pitch): \(error)") }
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000)!
            try file.read(into: buffer)
            let signal = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let energy = signal.reduce(0.0) { $0 + Double($1) * Double($1) }
            try require(energy > 0.0001, "\(kit) note \(pitch) is silent")
            for (index, other) in sounds.enumerated() {
                let otherEnergy = other.reduce(0.0) { $0 + Double($1) * Double($1) }
                let dot = zip(signal, other).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                try require(abs(dot) / sqrt(energy * otherEnergy) < 0.9999,
                            "\(kit) notes \(pitches[index]) and \(pitch) repeat the same sound")
            }
            sounds.append(signal)
        }
        print("PASS: \(kit.rawValue) has \(pitches.count) audible, distinct mapped drums; all groups reach stereo")
    }

    private static func completePCM(_ file: AVAudioFile) throws -> [[Float]] {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
        var samples = Array(repeating: [Float](), count: Int(file.processingFormat.channelCount))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try require(buffer.frameLength > 0, "sample read ended early")
            for channel in samples.indices {
                samples[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
            }
        }
        try require(samples.allSatisfy { $0.count == file.length }, "sample count differs from file length")
        return samples
    }

    private static func assertAudibleStereo48k(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        try require(abs(file.fileFormat.sampleRate - 48_000) < 0.1, "not 48 kHz")
        try require(file.fileFormat.channelCount == 2, "not stereo")
        try require(file.length > 1_000, "audio is too short")

        let frames = AVAudioFrameCount(min(file.length, 48_000))
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SmokeFailure("could not allocate audio buffer")
        }
        try file.read(into: buffer, frameCount: frames)
        guard let channels = buffer.floatChannelData else { throw SmokeFailure("no float audio") }
        var peak: Float = 0
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        try require(peak > 0.001, "audio is silent")
    }

    private static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AIMusicSketchpadTests-\(UUID().uuidString)-\(name)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SmokeFailure(message) }
    }
}

private struct SmokeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
