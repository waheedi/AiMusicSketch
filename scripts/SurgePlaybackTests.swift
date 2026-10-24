import AVFoundation
import Foundation
import AppKit
import SwiftUI

enum SurgePlaybackTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MessageError("Live Surge test: \(message)") }
    }
    @MainActor static func run() async throws {
        guard AudioUnitID.installed().contains(where: \.isSurgeXT) else {
            print("SKIP: Live Surge audio checks (Surge XT not installed)"); return
        }
        let configuration = try SurgePatchBank.configuration(for: SurgePatchBank.presets[2])
        var clip = ClipModel(name: "Live Surge check", assetPath: "/missing-original-is-not-used.wav", startBeat: 1,
            durationBeats: 4, sourceDurationSeconds: 2)
        clip.instrumentAddOn = configuration
        clip.midiSourceBPM = 120
        clip.midiNotes = [MIDINote(pitch: 60, velocity: 0.7, startBeat: 0, durationBeats: 1.6),
                          MIDINote(pitch: 67, velocity: 0.7, startBeat: 2, durationBeats: 1)]
        try check(clip.supportsLiveSurge, "recorded notes + patch not recognized")
        let instrument = try LiveSurgeInstrument(configuration: configuration, clips: [clip], bpm: 120, endBeat: 8)
        let parameters = instrument.unit.auAudioUnit.parameterTree!.allParameters
        let pairs: [(AutomationParameter, String)] = [(.surgeCutoff, "Filter 1 Cutoff"),
            (.surgeResonance, "Filter 1 Resonance"), (.surgeAttack, "Amp EG Attack"),
            (.surgeRelease, "Amp EG Release"), (.surgeWidth, "Width")]
        for (kind, name) in pairs {
            let a = parameters.first { $0.displayName == "A \(name)" }!
            let b = parameters.first { $0.displayName == "B \(name)" }!
            let beforeA = a.value, beforeB = b.value
            var controls = SurgePlaybackSettings(enabled: true)
            let offset = beforeA > 0.5 ? -0.25 : 0.25
            controls.set(kind, value: offset)
            instrument.apply(controls)
            try check(abs(a.value - max(0, min(1, beforeA + Float(offset)))) < 0.0001, "\(name) A not connected")
            try check(abs(b.value - max(0, min(1, beforeB + Float(offset)))) < 0.0001, "\(name) B not connected")
            instrument.apply(SurgePlaybackSettings(enabled: true))
            try check(abs(a.value - beforeA) < 0.0001, "reset did not restore patch")
        }
        var project = StudioProject()
        project.lengthBeats = 7
        project.tracks = [TrackModel.new(index: 0)]
        project.tracks[0].clips = [clip]
        project.tracks[0].surgePlayback = SurgePlaybackSettings(enabled: true)
        project.tracks[0].volume = 0.5
        project.tracks[0].automation = [AutomationLane(parameter: .surgeCutoff, points: [
            AutomationPoint(seconds: 0, value: 0), AutomationPoint(seconds: 1, value: 0.25)])]
        let atTime = project.tracks[0].automated(at: 0.5)
        try check(abs(atTime.surgePlayback!.cutoff - 0.125) < 0.0001, "Surge lane interpolation")
        let encoded = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(StudioProject.self, from: encoded)
        try check(restored == project, "settings/automation JSON round trip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSurgeTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func render(_ project: StudioProject, name: String) throws -> [Float] {
            let url = directory.appendingPathComponent(name + ".wav")
            try OfflineMixRenderer.render(project: project, to: url)
            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            try check(samples.allSatisfy { $0.isFinite }, "nonfinite export")
            return samples
        }
        let automated = try render(project, name: "automated")
        try check(automated.count == 168_000, "export length")
        try check(automated.map(abs).max()! > 0.001, "live export is silent")
        try check(automated.prefix(23_999).allSatisfy { abs($0) < 0.000001 }, "played before clip starts")
        try check(automated.suffix(48_000).allSatisfy { abs($0) < 0.000001 }, "played after clip ends")
        var closed = project
        closed.tracks[0].automation = nil
        closed.tracks[0].surgePlayback!.cutoff = -0.5
        let filtered = try render(closed, name: "closed-filter")
        let difference = zip(automated, filtered).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) }
        try check(difference > 10, "automated cutoff has no audible effect in export")
        var muted = project
        muted.tracks[0].isMuted = true
        try check(try render(muted, name: "muted").allSatisfy { $0 == 0 }, "muted live synth audible")
        // Old projects remain on the WAV path. Use the generated audio as an original take.
        var originalAudio = project
        originalAudio.tracks[0].surgePlayback = nil
        originalAudio.tracks[0].clips[0].assetPath = directory.appendingPathComponent("automated.wav").path
        let originalSamples = try render(originalAudio, name: "original")
        try check(originalSamples.map(abs).max()! > 0.001, "original audio fallback silent")
        for rate in [44_100.0, 96_000.0] {
            var changedRate = project; changedRate.sampleRate = rate
            let samples = try render(changedRate, name: "rate-\(Int(rate))")
            try check(samples.count == Int(3.5 * rate) && samples.map(abs).max()! > 0.001, "sample rate \(rate)")
        }
        var padded = project
        padded.tracks[0].clips[0].leadingSilenceSeconds = 0.3
        padded.tracks[0].clips[0].trailingSilenceSeconds = 0.4
        let padding = try render(padded, name: "padding")
        try check(padding.prefix(38_399).allSatisfy { abs($0) < 0.000001 }, "leading padding not silent")
        let samePatch = ClipMerge.surgeConfiguration(for: [clip, clip])
        try check(samePatch == configuration, "merge lost same-patch Surge metadata")
        let studio = StudioModel()
        studio.project = project
        studio.setSurgeControl(on: project.tracks[0].id, parameter: .surgeWidth, value: -0.5)
        studio.undo()
        try check(studio.project.tracks[0].surgePlayback!.width == 0, "control undo")
        studio.redo()
        try check(studio.project.tracks[0].surgePlayback!.width == -0.5, "control redo")

        // Transport tests are silent at the output. Identical patches share one instance.
        var copy = clip; copy.id = UUID(); copy.startBeat = 5
        project.tracks[0].clips.append(copy)
        project.lengthBeats = 10
        project.tracks[0].volume = 0
        let audio = AudioEngineController()
        defer { audio.stop() }
        try audio.play(project: project, fromBeat: 2)
        try check(audio.liveInstrumentCount == 1 && audio.activePlayerCount == 0, "copied clips duplicate AU / play WAV too")
        try await Task.sleep(for: .milliseconds(250))
        project.tracks[0].surgePlayback!.resonance = 0.3
        audio.updateMix(project: project)
        project.tracks[0].isMuted = true; audio.updateMix(project: project)
        project.tracks[0].isMuted = false; audio.updateMix(project: project)
        try await Task.sleep(for: .milliseconds(250))
        try check(audio.isPlaying, "unmute stopped live transport")
        audio.stop()
        project.tracks[0].isMuted = true
        try audio.play(project: project)
        try check(audio.liveInstrumentCount == 0, "muted track loads Surge")
        project.tracks[0].isMuted = false; audio.updateMix(project: project)
        try check(audio.liveInstrumentCount == 1, "unmute did not load Surge")
        audio.stop()
        // Capture only this test AU's output, with the speaker mixer muted. This
        // verifies host-time scheduling produces audio, not just a moving cursor.
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(instrument.unit)
        engine.connect(instrument.unit, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        try engine.start()
        let anchor = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.15)
        let capturedURL = directory.appendingPathComponent("live.caf")
        let capture = try InstrumentAudioCapture(url: capturedURL, format: format, anchor: anchor)
        instrument.unit.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in capture.append(buffer, time: time) }
        instrument.play(at: AVAudioTime(hostTime: anchor), fromSeconds: 0, sampleRate: 48_000)
        try await Task.sleep(for: .milliseconds(1050))
        instrument.unit.removeTap(onBus: 0)
        engine.stop(); engine.detach(instrument.unit)
        try capture.finish()
        let captured = try AVAudioFile(forReading: capturedURL)
        let liveBuffer = AVAudioPCMBuffer(pcmFormat: captured.processingFormat, frameCapacity: AVAudioFrameCount(captured.length))!
        try captured.read(into: liveBuffer)
        let signal = UnsafeBufferPointer(start: liveBuffer.floatChannelData![0], count: Int(liveBuffer.frameLength))
        try check(signal.map(abs).max()! > 0.001, "host-time live audio is silent")
        try check(signal.prefix(23_000).allSatisfy { abs($0) < 0.00001 }, "live synth starts ahead of timeline")
        if CommandLine.arguments.contains("--surge-preview") {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
            var source = project
            source.lengthBeats = 4
            source.tracks[0].clips = [clip]; source.tracks[0].clips[0].startBeat = 0
            source.tracks[0].volume = 0.5; source.tracks[0].automation = nil
            let wav = output.appendingPathComponent("SurgePlaybackCheck.wav")
            try OfflineMixRenderer.render(project: source, to: wav)
            project.name = "Surge automation check (generated)"
            project.tracks[0].name = "Surge automation check"
            for i in project.tracks[0].clips.indices { project.tracks[0].clips[i].assetPath = wav.path }
            try JSONEncoder().encode(project).write(to: output.appendingPathComponent("SurgePlaybackCheck.aimusic.json"), options: .atomic)
            studio.project = project
            studio.selectTrack(project.tracks[0].id)
            studio.visibleAutomation[project.tracks[0].id] = .surgeCutoff
            _ = NSApplication.shared
            let preview = NSHostingView(rootView: ContentView().environmentObject(studio).frame(width: 1440, height: 860))
            preview.frame = NSRect(x: 0, y: 0, width: 1440, height: 860)
            preview.layoutSubtreeIfNeeded()
            if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/surge-automation-check.png"))
            }
        }
        print("PASS: five Surge controls A/B, reset, JSON, automation/export sound, clip boundaries, shared patch, silent transport/seek/mute/unmute")
    }
}
