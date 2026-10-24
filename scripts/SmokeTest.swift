import AVFoundation
import AppKit
import Darwin
import Foundation
import Combine
import SwiftUI

@main
struct SmokeTest {
    @MainActor private static func assertUsability() throws {
        let studio = StudioModel()
        for _ in 0..<36 { studio.addTrack() }
        try require(studio.project.tracks.count == 40 && studio.alertMessage == nil, "Tracks still capped at eight")
        studio.undo()
        try require(studio.project.tracks.count == 39, "Add-track undo failed")
        studio.redo()
        try require(studio.project.tracks.count == 40, "Add-track redo failed")
        let restored = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(studio.project))
        try require(restored.tracks == studio.project.tracks, "Large project lost tracks on JSON round-trip")
        studio.zoomTimeline(inward: true)
        try require(studio.timelineBeatWidth == 42.5, "Zoom-in step")
        studio.zoomTimeline(inward: false)
        try require(studio.timelineBeatWidth == 34, "Zoom-out step")
        for _ in 0..<100 { studio.zoomTimeline(inward: true) }
        try require(studio.timelineBeatWidth == 160, "Zoom maximum")
        for _ in 0..<100 { studio.zoomTimeline(inward: false) }
        try require(studio.timelineBeatWidth == 8, "Zoom minimum")
        func action(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> StudioKeyAction? {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 15)!
            return StudioKeyAction.action(for: event)
        }
        try require(action("r") == .record && action("R", .capsLock) == .record, "R record shortcut")
        try require(action("r", .command) == nil && action("r", .option) == nil && action("r", .shift) == nil,
                    "Modified R should pass through")
        try require(action("+", .command) == .zoomIn && action("=", .command) == .zoomIn &&
                    action("+", [.command, .shift]) == .zoomIn && action("-", .command) == .zoomOut,
                    "Zoom keyboard layouts")
        try require(action("+") == nil && action("-", [.command, .option]) == nil && action("a") == nil,
                    "Unrelated keys intercepted")
        studio.isBusy = true
        studio.toggleRecording()
        try require(!studio.recording.isRecording && !studio.canToggleRecording, "Record busy guard")
        print("PASS: 40 tracks, undo/redo, large-project JSON, zoom range and R/zoom shortcut mapping")
    }

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
        if CommandLine.arguments.contains("--live-surge-only") { try await SurgePlaybackTests.run(); return }
        try await PlaybackPerformanceTests.run()
        if CommandLine.arguments.contains("--playback-only") { return }
        try await SurgePlaybackTests.run()
        try assertUsability()
        try await EditingFeatureTests.run()
        try await InstrumentTests.run()
        try assertOctaveShortcuts()
        try assertGenerationOutputRange()
        try assertNoteDisplay()
        try assertEditingHistory()
        try assertExpandedEffects()
        let studio = StudioModel()
        var observed = 0
        let subscription = studio.objectWillChange.sink { observed += 1 }
        var cursorObserved = 0
        let cursorSubscription = studio.audio.objectWillChange.sink { cursorObserved += 1 }
        studio.audio.playheadBeat = 12
        try require(observed == 0 && cursorObserved > 0, "cursor must update its own views without redrawing the entire studio")
        withExtendedLifetime(cursorSubscription) {}
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
        if CommandLine.arguments.contains("--signature-kit") {
            try assertSignatureKit()
        }
        if CommandLine.arguments.contains("--aurora-kit") { try assertSignatureKit(kit: .aurora) }

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

        if CommandLine.arguments.contains("--track-workflow") || CommandLine.arguments.contains("--long-track-workflow") {
            let workflow = StudioModel()
            let original = ClipModel(name: "My recorded bass", assetPath: source.path, startBeat: 4,
                                     durationBeats: 4, sourceDurationSeconds: duration)
            workflow.project.tracks[0].clips = [original]
            workflow.project.lengthBeats = 8
            let targetID = workflow.project.tracks[0].id
            workflow.beginGeneration(trackID: targetID, useTrack: true)
            workflow.generationRequest.bars = 1
            let newBeats = CommandLine.arguments.contains("--long-track-workflow") ? 60.5 : 8.5
            workflow.generationRequest.outputEndBeat = original.endBeat + newBeats
            workflow.generateMusic()
            var lastStatus = ""
            for _ in 0..<2_400 where workflow.isBusy {
                if workflow.status != lastStatus { print(workflow.status); lastStatus = workflow.status }
                try await Task.sleep(for: .milliseconds(500))
            }
            if workflow.isBusy { workflow.cancelGeneration(); throw SmokeFailure("track AI workflow timed out") }
            try require(workflow.alertMessage == nil, "track AI workflow failed: \(workflow.alertMessage ?? "")")
            let clips = workflow.project.tracks[0].clips
            try require(clips.count == 2 && clips[0] == original && clips[1].startBeat == original.endBeat,
                        "AI replaced or overlapped the source performance")
            try require(abs(clips[1].endBeat - (original.endBeat + newBeats)) < 0.000001,
                        "AI output did not reach the requested out-of-bounds end beat")
            try require(workflow.project.lengthBeats >= clips[1].endBeat && workflow.project.lengthBeats > 8,
                        "timeline did not grow with the generated continuation")
            let generatedFile = try AVAudioFile(forReading: clips[1].assetURL)
            try require(abs(Double(generatedFile.length) / generatedFile.processingFormat.sampleRate - newBeats * 0.5) < 0.0001,
                        "generated source audio is padded or truncated to the wrong duration")
            try require(clips[1].generationReference?.trackID == targetID && workflow.project.tracks[1].clips.isEmpty,
                        "AI used or wrote the wrong track")
            try assertAudibleStereo48k(clips[1].assetURL)
            workflow.undo()
            try require(workflow.project.tracks[0].clips == [original] && workflow.project.lengthBeats == 8,
                        "undo failed to remove the AI take and timeline extension together")
            workflow.redo()
            try require(workflow.project.tracks[0].clips == clips, "AI continuation redo failed")
            print("PASS: complete AI action generates through custom end beat, extends timeline, preserves original/provenance, undo/redo")
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

    @MainActor
    private static func assertGenerationOutputRange() throws {
        var project = StudioProject()
        project.lengthBeats = 16
        let id = project.tracks[0].id
        project.tracks[0].clips = [ClipModel(name: "source", assetPath: "/unused.wav", startBeat: 4,
                                           durationBeats: 8, sourceDurationSeconds: 4)]
        var request = GenerationRequest()
        request.input = .trackAudio; request.referenceStartBeat = 4; request.referenceEndBeat = 8
        request.outputEndBeat = 80
        let plan = try GenerationOutputRange(project: project, trackID: id, request: request, playhead: 0)
        try require(plan.startBeat == 12 && plan.endBeat == 80 && plan.seconds == 34,
                    "reference range or timeline clamped new generation length")
        try require(project.lengthBeats == 16 && project.tracks[0].clips.count == 1,
                    "editing output range mutated the project before successful generation")
        request.outputEndBeat = nil; request.bars = 2
        let bars = try GenerationOutputRange(project: project, trackID: id, request: request, playhead: 0)
        try require(bars.startBeat == 12 && bars.endBeat == 20, "legacy bar lengths changed")
        request.input = .textOnly; request.outputEndBeat = 64
        let text = try GenerationOutputRange(project: project, trackID: id, request: request, playhead: 8)
        try require(text.startBeat == 8 && text.seconds == 28, "text generation ignored playhead/custom end")
        for invalid in [8.0, 7.0, 8.1, Double.nan, Double.infinity, 700] {
            request.outputEndBeat = invalid
            do {
                _ = try GenerationOutputRange(project: project, trackID: id, request: request, playhead: 8)
                throw SmokeFailure("invalid AI end beat accepted")
            } catch is MessageError {}
        }
        request.outputEndBeat = 608
        let maximum = try GenerationOutputRange(project: project, trackID: id, request: request, playhead: 8)
        try require(maximum.seconds == 300,
                    "five-minute continuation boundary was rejected")
        let saved = try JSONDecoder().decode(GenerationRequest.self, from: JSONEncoder().encode(request))
        try require(saved.outputEndBeat == 608, "output end beat not saved")
        request.outputEndBeat = nil
        let legacy = try JSONDecoder().decode(GenerationRequest.self, from: JSONEncoder().encode(request))
        try require(legacy.outputEndBeat == nil, "older AI settings cannot be loaded")
        print("PASS: output-end planning beyond track/timeline, bars compatibility, validation and saved settings")
    }

    @MainActor
    private static func assertNoteDisplay() throws {
        let notes = [
            MIDINote(pitch: 60, velocity: 0.8, startBeat: 1, durationBeats: 1),
            MIDINote(pitch: 64, velocity: 0.6, startBeat: 1, durationBeats: 2),
            MIDINote(pitch: 67, velocity: 1, startBeat: 4, durationBeats: 1)
        ]
        let clip = ClipModel(name: "Chord + melody", assetPath: "/unused.wav", startBeat: 8,
                             durationBeats: 8, sourceDurationSeconds: 4, midiNotes: notes, midiSourceBPM: 120)
        let layout = ClipNoteLayout.notes(for: clip, bpm: 120)
        try require(layout == [DisplayNote(pitch: 60, velocity: 0.8, startSeconds: 0.5, durationSeconds: 0.5),
                               DisplayNote(pitch: 64, velocity: 0.6, startSeconds: 0.5, durationSeconds: 1),
                               DisplayNote(pitch: 67, velocity: 1, startSeconds: 2, durationSeconds: 0.5)],
                    "note view stretched leading/trailing silence or lost simultaneous pitches")
        try require(ClipNoteLayout.pitchRange(for: clip) == 60...71, "pitches are not on stable semitone rows")
        let trimmed = try ClipEditing.trim(clip, from: 9.5, to: 13, bpm: 120)
        let trimmedNotes = ClipNoteLayout.notes(for: trimmed, bpm: 120)
        try require(trimmedNotes[0].startSeconds == 0 && trimmedNotes[0].durationSeconds == 0.25
                    && trimmedNotes[1].durationSeconds == 0.75 && trimmedNotes[2].startSeconds == 1.25,
                    "trimmed note positions do not match audio source offset")
        let loop = ClipEditing.loop(trimmed, times: 2, bpm: 120)
        let loopNotes = ClipNoteLayout.notes(for: loop, bpm: 120)
        try require(loopNotes.count == 6 && loopNotes[3].startSeconds == 1.75
                    && loopNotes[5].startSeconds == 3, "trimmed source region did not repeat on the note display")
        let split = try ClipEditing.split(loop, at: loop.startBeat + 2, bpm: 120).1
        let splitNotes = ClipNoteLayout.notes(for: split, bpm: 120)
        try require(splitNotes.first?.pitch == 67 && splitNotes.first?.startSeconds == 0.25,
                    "split display ignored the loop phase")
        let wrapped = try ClipEditing.trim(loop, from: loop.startBeat + 2, to: loop.startBeat + 5, bpm: 120)
        var consolidated = wrapped
        consolidated.midiNotes = ClipNoteLayout.rebasedNotes(for: wrapped, bpm: 120)
        consolidated.midiSourceBPM = 120
        consolidated.sourceOffsetSeconds = 0; consolidated.playbackOffsetSeconds = 0
        consolidated.sourceDurationSeconds = wrapped.durationBeats * 0.5
        consolidated.loopEnabled = false; consolidated.loopLengthSeconds = nil
        try require(ClipNoteLayout.notes(for: consolidated, bpm: 120) == ClipNoteLayout.notes(for: wrapped, bpm: 120),
                    "consolidating a wrapped loop invalidated note metadata")
        let shorter = ClipEditing.resize(clip, leftEdge: false, to: 11, bpm: 120)
        try require(ClipNoteLayout.notes(for: shorter, bpm: 120).count == 2, "right resize stretched later notes into view")
        let revealed = ClipEditing.resize(shorter, leftEdge: false, to: 16, bpm: 120)
        try require(ClipNoteLayout.notes(for: revealed, bpm: 120) == ClipNoteLayout.notes(for: shorter, bpm: 120),
                    "silent extension revealed trimmed notes")
        var faster = clip; faster.durationBeats *= 1.5
        try require(ClipNoteLayout.notes(for: faster, bpm: 180) == layout, "tempo edit shifted notes relative to rendered audio")
        var legacy = clip; legacy.midiSourceBPM = nil
        let studio = StudioModel()
        studio.project.tracks[0].clips = [legacy]
        studio.setTempo(180)
        let updated = studio.project.tracks[0].clips[0]
        try require(updated.midiSourceBPM == 120 && ClipNoteLayout.notes(for: updated, bpm: 180) == layout,
                    "legacy note tempo was not preserved on tempo edit")
        let loaded = try JSONDecoder().decode(ClipModel.self, from: JSONEncoder().encode(legacy))
        try require(loaded.midiSourceBPM == nil && ClipNoteLayout.notes(for: loaded, bpm: 120) == layout,
                    "legacy project compatibility failed")
        let saved = try JSONDecoder().decode(ClipModel.self, from: JSONEncoder().encode(updated))
        try require(saved == updated, "source tempo not saved with the take")
        var invalid = clip
        invalid.midiNotes = [MIDINote(pitch: 200, velocity: 1, startBeat: 0, durationBeats: 1),
                             MIDINote(pitch: 60, velocity: 0, startBeat: 0, durationBeats: 1)]
        try require(ClipNoteLayout.notes(for: invalid, bpm: 120).isEmpty, "display contains inaudible/invalid MIDI events")
        if CommandLine.arguments.contains("--note-preview") {
            let content = VStack(alignment: .leading, spacing: 8) {
                Text("Original · leading silence, chord, then melody").font(.caption)
                ClipNoteView(clip: clip, bpm: 120).frame(width: 640, height: 64).background(Color.blue)
                Text("Trimmed · partial notes at start; pitches stay on the same rows").font(.caption)
                ClipNoteView(clip: trimmed, bpm: 120).frame(width: 280, height: 64).background(Color.purple)
                Text("Looped trim · two identical repetitions").font(.caption)
                ClipNoteView(clip: loop, bpm: 120).frame(width: 560, height: 64).background(Color.teal)
            }.padding(16).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw SmokeFailure("could not render note preview")
            }
            let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent("AIMusicSketchpad-note-preview.png")
            try data.write(to: previewURL)
            print("NOTE PREVIEW: \(previewURL.path)")
        }
        print("PASS: note display timing, pitch rows, polyphony, trim/split/loop/resize, source tempo and legacy saves")
    }

    @MainActor
    private static func assertOctaveShortcuts() throws {
        func event(_ key: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], repeated: Bool = false,
                   type: NSEvent.EventType = .keyDown) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                            windowNumber: 0, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: key)!
        }
        let controller = RecordingController()
        controller.source = .keyboard
        let view = PianoKeyView()
        view.recording = controller
        for (offset, pair) in [(UInt16(37), "l"), (41, "ö"), (39, "ä"), (42, "#")].enumerated() {
            let note = 13 + offset
            try require(PianoKeyView.semitone(from: event(pair.0, pair.1)) == note, "extended keyboard mapping wrong")
            controller.octave = 4
            view.keyDown(with: event(pair.0, pair.1))
            try require(view.held[pair.0] == 60 + note, "extended key did not play expected pitch")
            controller.octave = 5
            view.keyUp(with: event(pair.0, pair.1, type: .keyUp))
            try require(view.held[pair.0] == nil, "extended note release lost after octave change")
            try require(PianoKeyView.semitone(from: event(pair.0, pair.1, flags: .command)) == nil, "extended key intercepted shortcut")
        }
        try require(PianoKeyView.semitone(from: event(255, "Ö")) == 14, "German character mapping depended on key code")
        for (index, key) in [UInt16(18), 19, 20, 21, 23, 22].enumerated() {
            view.keyDown(with: event(key, String(index + 1)))
            try require(controller.octave == index + 1, "number key did not select its octave")
        }
        view.keyDown(with: event(83, "1", flags: .numericPad))
        try require(controller.octave == 1, "numeric keypad octave shortcut failed")
        view.keyDown(with: event(22, "6", repeated: true))
        try require(controller.octave == 1, "autorepeat changed the octave")
        for flags: NSEvent.ModifierFlags in [.command, .control, .option] {
            try require(PianoKeyView.octaveShortcut(from: event(18, "1", flags: flags)) == nil,
                        "octave shortcut intercepted modified app shortcuts")
        }
        for characters in ["0", "7", "!", "a", "12"] {
            try require(PianoKeyView.octaveShortcut(from: event(18, characters)) == nil, "invalid octave accepted")
        }
        view.keyDown(with: event(0, "a"))
        try require(view.held[0] == 24, "wrong first-octave note")
        view.keyDown(with: event(22, "6"))
        try require(view.held[0] == 24, "octave change retuned a held note")
        view.keyUp(with: event(0, "a", type: .keyUp))
        try require(view.held.isEmpty, "octave change left a held key stuck")
        view.keyDown(with: event(0, "a"))
        try require(view.held[0] == 84, "new key press did not use the new octave")
        view.releaseKeys()
        print("PASS: 1–6/numpad octave shortcuts, modifier guards, repeat suppression, and held-note release")
    }

    private static func assertSignatureKit(kit: KeyboardInstrument = .signature) throws {
        let started = Date()
        let urls = kit == .signature ? try SignatureKit.sampleURLs() : []
        for index in 0..<28 {
            let samples = kit == .signature ? SignatureKit.synthesize(index) : AuroraKit.synthesize(index)
            try require(samples.allSatisfy { $0.isFinite && abs($0) <= 0.651 }, "invalid synth samples")
            try require(samples.contains { abs($0) > 0.01 }, "empty synth source")
            if kit == .signature {
                let cached = try completePCM(AVAudioFile(forReading: urls[index]))[0]
                try require(cached == samples, "synth cache \(index) differs from generated PCM")
            } else {
                try require(samples != SignatureKit.synthesize(index), "Aurora source is a duplicate of Signature")
            }
        }
        let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try MIDIRenderer.loadInstrument(kit, into: sampler)
        let instrument = sampler.auAudioUnit.fullState!["Instrument"] as! [String: Any]
        let layers = instrument["Layers"] as! [[String: Any]]
        let zones = layers.flatMap { $0["Zones"] as! [[String: Any]] }
        try require(zones.count == 128 && Set(zones.compactMap { $0["min key"] as? Int }) == Set(0..<128),
                    "Signature Kit has gaps in its MIDI map")
        try require(layers.allSatisfy { ($0["output"] as? Int ?? 0) == 0 }, "Signature Kit has disconnected outputs")
        var vectors: [Int: [Float]] = [:]
        for pitch in 0..<128 {
            let url = temporaryURL("signature-\(pitch).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try MIDIRenderer.render(notes: [MIDINote(pitch: pitch, velocity: 0.8, startBeat: 0, durationBeats: 0.7)],
                                       instrument: kit, bpm: 120, durationBeats: 1, sampleRate: 48_000, to: url)
            do { try assertAudibleStereo48k(url) }
            catch { throw SmokeFailure("Signature Kit note \(pitch): \(error)") }
            let pcm = try completePCM(AVAudioFile(forReading: url))[0]
            if let bad = pcm.firstIndex(where: { !$0.isFinite }) {
                throw SmokeFailure("Signature Kit note \(pitch) invalid audio at frame \(bad), \(Double(bad) / 48_000)s")
            }
            if (24..<48).contains(pitch) || [48, 60, 72, 84].contains(pitch) {
                vectors[pitch] = pcm
            }
        }
        let keys = vectors.keys.sorted()
        for (i, first) in keys.enumerated() {
            let a = vectors[first]!, energyA = a.reduce(0.0) { $0 + Double($1) * Double($1) }
            for second in keys.dropFirst(i + 1) {
                let b = vectors[second]!, energyB = b.reduce(0.0) { $0 + Double($1) * Double($1) }
                let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                let similarity = abs(dot) / sqrt(energyA * energyB)
                try require(similarity < 0.9999, "Signature sounds \(first)/\(second): similarity \(similarity), energy \(energyA)/\(energyB), frames \(a.count)/\(b.count)")
            }
        }
        for pitch in [48, 60, 84] {
            let url = temporaryURL("signature-sustain-\(pitch).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            // Chord source is ~7.8 seconds; holding for ten proves it really loops.
            _ = try MIDIRenderer.render(notes: [MIDINote(pitch: pitch, velocity: 0.8, startBeat: 0, durationBeats: 20)],
                                       instrument: kit, bpm: 120, durationBeats: 22, sampleRate: 48_000, to: url)
            let signal = try completePCM(AVAudioFile(forReading: url))[0]
            let heldPeak = signal[432_000..<456_000].map { abs($0) }.max()!
            let releasedPeak = signal[504_000..<520_000].map { abs($0) }.max()!
            try require(heldPeak > 0.001, "Signature Kit note \(pitch) stopped early: held=\(heldPeak), released=\(releasedPeak)")
            try require(releasedPeak < 0.0001, "Signature Kit note \(pitch) stuck after release: \(releasedPeak)")
        }
        var project = StudioProject()
        project.tracks[0].clips = [ClipModel(name: "Signature take", assetPath: "/test.wav", startBeat: 0,
                                           durationBeats: 4, sourceDurationSeconds: 2, instrument: kit)]
        let roundtrip = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        try require(roundtrip.tracks[0].clips[0].instrument == kit, "Kit identity not saved")
        print("PASS: \(kit.rawValue), all 128 MIDI notes audible, 28 distinct sources, sustained loops, note-off, project metadata (\(Int(Date().timeIntervalSince(started)))s)")
    }

    @MainActor
    private static func assertEditingHistory() throws {
        let studio = StudioModel()
        let fresh = studio.project
        studio.addTrack()
        let added = studio.project
        studio.undo()
        try require(studio.project == fresh && studio.canRedo, "add-track undo not atomic")
        studio.redo()
        try require(studio.project == added, "redo did not restore track")
        studio.undo()
        studio.project.name = "New branch"
        try require(!studio.canRedo, "a new edit failed to clear redo")
        studio.newProject()
        try require(!studio.canUndo && !studio.canRedo, "new project inherited history")
        let clip = ClipModel(name: "resize", assetPath: "/immutable.wav", startBeat: 4,
                             durationBeats: 8, sourceDurationSeconds: 4)
        studio.project.tracks[0].clips = [clip]
        let original = studio.project
        studio.selectedTrackID = original.tracks[0].id
        studio.selectedClipID = clip.id
        studio.resizeClip(clip.id, leftEdge: true, to: 6)
        studio.resizeClip(clip.id, leftEdge: false, to: 9)
        let trimmed = studio.clip(clip.id)!
        try require(trimmed.startBeat == 6 && trimmed.endBeat == 9 && trimmed.playbackOffsetSeconds == 1, "edge trim failed")
        studio.resizeClip(clip.id, leftEdge: false, to: 30)
        try require(studio.clip(clip.id)!.endBeat == 30 && studio.clip(clip.id)!.trailingSilenceSeconds == 10.5,
                    "right extension did not add silence")
        studio.resizeClip(clip.id, leftEdge: true, to: 0)
        try require(studio.clip(clip.id)!.startBeat == 0 && studio.clip(clip.id)!.leadingSilenceSeconds == 3,
                    "left extension did not add silence")
        studio.undo(); studio.undo(); studio.undo(); studio.undo()
        try require(studio.project == original, "resize history does not restore exact source offsets")
        studio.audio.playheadBeat = 8
        studio.splitSelectedClip()
        let split = studio.project
        studio.undo()
        try require(studio.project == original, "split must undo in one action")
        studio.redo()
        try require(studio.project == split, "split redo did not preserve clip IDs")
        studio.undo()
        studio.duplicateClip(clip.id)
        studio.undo()
        try require(studio.project == original, "duplicate undo left a clip/length change")
        studio.beginEdit("Mix gesture")
        for n in 0...20 { studio.project.tracks[0].effects.drive = Double(n) / 20 }
        studio.endEdit()
        studio.undo()
        try require(studio.project == original, "one slider gesture created multiple undo steps")
        studio.redo()
        try require(studio.project.tracks[0].effects.drive == 1, "slider redo failed")
        studio.undo()
        studio.setAutomationPoint(trackID: original.tracks[0].id, parameter: .filterCutoff, seconds: 1, value: -0.5)
        studio.undo()
        try require(studio.project == original, "automation undo failed")
        studio.selectedClipID = clip.id
        studio.deleteSelectedClip(); studio.undo()
        try require(studio.project == original, "deleted clip/source cannot be recovered")
        studio.isBusy = true
        let locked = studio.project
        studio.undo(); studio.redo()
        try require(studio.project == locked, "undo modified project during generation/recording")
        studio.isBusy = false
        var loop = clip
        loop.loopEnabled = true
        loop.playbackOffsetSeconds = 0.5
        let expanded = ClipEditing.resize(loop, leftEdge: true, to: 1, bpm: 120)
        try require(expanded.startBeat == 1 && expanded.endBeat == 12 && expanded.playbackOffsetSeconds == 0.5
                    && expanded.leadingSilenceSeconds == 1.5, "left extension shifted the audible loop")
        let longer = ClipEditing.resize(expanded, leftEdge: false, to: 24, bpm: 120)
        let segments = scheduledSegments(for: longer, bpm: 120, fromBeat: 0)
        try require(longer.endBeat == 24 && segments.first?.timelineStartSeconds == 2
                    && abs(segments.reduce(0) { $0 + $1.durationSeconds } - 4) < 0.0001
                    && ClipEditing.needsLoopRender(longer, bpm: 120), "loop padding changed existing audio or repetition length")
        try require(ClipEditing.resize(clip, leftEdge: true, to: 99, bpm: 120).durationBeats > 0,
                    "edge crossing inverted a clip")
        let trackID = studio.project.tracks[0].id
        var second = clip; second.id = UUID(); second.startBeat = 16
        var third = clip; third.id = UUID(); third.startBeat = 28
        studio.project.tracks[0].clips = [clip, second, third]
        studio.selectClip(trackID: trackID, clipID: clip.id)
        studio.selectClip(trackID: trackID, clipID: third.id, range: true)
        try require(studio.selectedClipIDs.count == 3, "Shift-click failed to select a clip range")
        studio.selectClip(trackID: trackID, clipID: second.id, additive: true)
        try require(studio.selectedClipIDs == [clip.id, third.id], "Command-click failed to toggle a clip")
        let beforeDelete = studio.project
        studio.deleteSelectedClip()
        try require(studio.project.tracks[0].clips == [second], "bulk deletion removed the wrong clips")
        studio.undo()
        try require(studio.project == beforeDelete, "bulk deletion did not undo atomically")
        print("PASS: undo/redo, atomic edits, silent padding, loop timing and clip multi-selection/deletion")
    }

    private static func assertExpandedEffects() throws {
        let legacy = Data("{\"lowGain\":2,\"midGain\":0,\"highGain\":0,\"compression\":0,\"reverb\":0.2,\"delay\":0}".utf8)
        let old = try JSONDecoder().decode(EffectSettings.self, from: legacy)
        try require(old.drive == 0 && old.bitCrush == 0 && old.filterMode == .off && old.reverbSpace == .hall
                    && old.lowGain == 2 && old.delayTime == 0.25, "old projects changed effect defaults")
        let source = temporaryURL("effects-source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for i in 0..<96_000 {
            let t = Double(i) / 48_000
            let sample = Float(0.15 * (sin(2 * .pi * 120 * t) + sin(2 * .pi * 8_000 * t)))
            for c in 0..<2 { buffer.floatChannelData![c][i] = sample }
        }
        try autoreleasepool { try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer) }
        var project = StudioProject()
        project.lengthBeats = 8
        project.tracks = [.new(index: 0)]
        project.tracks[0].volume = 1
        project.tracks[0].clips = [ClipModel(name: "tone", assetPath: source.path, startBeat: 0, durationBeats: 4, sourceDurationSeconds: 2)]
        func render(_ settings: EffectSettings, automation: [AutomationLane]? = nil) throws -> [Float] {
            var test = project
            test.tracks[0].effects = settings
            test.tracks[0].automation = automation
            let url = temporaryURL("effects-result.wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try OfflineMixRenderer.render(project: test, to: url)
            let pcm = try completePCM(AVAudioFile(forReading: url))[0]
            try require(pcm.allSatisfy { $0.isFinite && abs($0) < 8 }, "effect produced invalid/extreme PCM")
            return pcm
        }
        func magnitude(_ samples: [Float], frequency: Double, start: Int = 48_000) -> Double {
            var real = 0.0, imaginary = 0.0
            for i in start..<(start + 12_000) {
                let phase = 2 * .pi * frequency * Double(i) / 48_000
                real += Double(samples[i]) * cos(phase)
                imaginary += Double(samples[i]) * sin(phase)
            }
            return hypot(real, imaginary) / 12_000
        }
        let dry = try render(EffectSettings())
        var effect = EffectSettings()
        effect.filterMode = .lowPass; effect.filterCutoff = 500
        let low = try render(effect)
        try require(magnitude(low, frequency: 8_000) < magnitude(dry, frequency: 8_000) * 0.1
                    && magnitude(low, frequency: 120) > magnitude(dry, frequency: 120) * 0.4, "low-pass filter does not cut highs")
        effect.filterMode = .highPass; effect.filterCutoff = 2_000
        let high = try render(effect)
        try require(magnitude(high, frequency: 120) < magnitude(dry, frequency: 120) * 0.1
                    && magnitude(high, frequency: 8_000) > magnitude(dry, frequency: 8_000) * 0.4, "high-pass filter does not cut lows")
        effect.filterMode = .bandPass; effect.filterCutoff = 1_000; effect.filterResonance = 1
        _ = try render(effect)
        for crush in [false, true] {
            var settings = EffectSettings()
            if crush { settings.bitCrush = 0.8 } else { settings.drive = 0.8 }
            let wet = try render(settings)
            let difference = zip(wet, dry).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) } / Double(wet.count)
            try require(difference > 0.001, "\(crush ? "bit-crush" : "drive") has no audible effect")
        }
        for space in ReverbSpace.allCases {
            var settings = EffectSettings(); settings.reverb = 0.5; settings.reverbSpace = space
            let wet = try render(settings)
            try require(wet[100_000..<140_000].contains { abs($0) > 0.00001 }, "\(space) has no reverb tail")
        }
        var delay = EffectSettings(); delay.delay = 0.7; delay.delayTime = 0.4; delay.delayFeedback = 0.4
        let echo = try render(delay)
        try require(echo[100_000..<115_000].contains { abs($0) > 0.001 }, "delay time/feedback has no tail")
        var filter = EffectSettings(); filter.filterMode = .lowPass; filter.filterCutoff = 1_000
        let sweep = AutomationLane(parameter: .filterCutoff, points: [AutomationPoint(seconds: 0, value: -0.5), AutomationPoint(seconds: 1.5, value: 0.8)])
        let swept = try render(filter, automation: [sweep])
        try require(magnitude(swept, frequency: 8_000, start: 72_000) > magnitude(swept, frequency: 8_000, start: 0) * 5,
                    "cutoff automation did not sweep exported audio")
        project.tracks[0].effects = filter; project.tracks[0].automation = [sweep]
        let roundtrip = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        try require(roundtrip == project, "new effects/automation do not survive save/load")
        print("PASS: legacy effects, audible drive/bit-crush/reverb/delay, LP/HP/BP filters and rendered cutoff automation")
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
