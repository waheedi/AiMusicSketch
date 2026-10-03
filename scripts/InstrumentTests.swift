import AppKit
import AVFoundation
import AudioToolbox
import SketchSynthDSP
import SwiftUI

enum InstrumentTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    @MainActor static func run() async throws {
        try testDSP()
        try testKick()
        try testFollow()
        try testCapture()
        var config = InstrumentConfiguration(mode: .synth)
        config.synth = .preset("Soft pad")
        var project = StudioProject()
        project.tracks[0].instrumentConfiguration = config
        let restored = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        try check(restored == project, "Synth preset project round-trip")
        let studio = StudioModel()
        studio.recording.configuration = config
        studio.instrumentChanged(reload: false)
        studio.selectTrack(studio.project.tracks[1].id)
        try check(studio.recording.configuration.mode == .builtIn, "Track instrument did not change")
        studio.selectTrack(studio.project.tracks[0].id)
        try check(studio.recording.configuration == config, "Per-track synth preset lost")
        studio.recording.configuration.synth.cutoff = 777
        studio.instrumentChanged(reload: false)
        studio.undo()
        try check(studio.recording.configuration.synth.cutoff == config.synth.cutoff, "Synth undo did not restore sound")
        studio.redo()
        try check(studio.recording.configuration.synth.cutoff == 777, "Synth redo did not restore sound")
        let synth = try await HostedInstrument.make(config, sampleRate: 48_000)
        try check(try render(synth) > 0.001, "Hosted Sketch Synth is silent")
        var kickConfig = InstrumentConfiguration(mode: .kick)
        kickConfig.kickSettings = .preset("Punch")
        project.tracks[2].instrumentConfiguration = kickConfig
        let kickRestored = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        try check(kickRestored == project, "Kick settings project round-trip")
        let kick = try await HostedInstrument.make(kickConfig, sampleRate: 48_000)
        try check(try render(kick) > 0.01, "Hosted Kick Lab is silent")
        let legacy = try JSONDecoder().decode(InstrumentConfiguration.self, from: Data(#"{"mode":"Sketch Synth","builtIn":"Piano","synth":{"waveform":1,"attack":0.01,"decay":0.2,"sustain":0.65,"release":0.3,"cutoff":4000,"gain":0.3}}"#.utf8))
        try check(legacy.kick == nil && legacy.kickSettings == KickSettings(), "Old instrument settings failed to load")
        let builtIn = try await HostedInstrument.make(InstrumentConfiguration(), sampleRate: 48_000)
        try check(try render(builtIn) > 0.001, "Library MIDI routing regressed")
        let installed = AudioUnitID.installed()
        print("Installed AU instruments: \(installed.map(\.name).joined(separator: ", "))")
        guard let dls = installed.first(where: { $0.subtype == kAudioUnitSubType_DLSSynth && $0.manufacturer == kAudioUnitManufacturer_Apple }) else {
            throw Failure(message: "Apple DLS instrument unavailable for AU host test")
        }
        var auConfig = InstrumentConfiguration(mode: .audioUnit, audioUnit: dls)
        let hosted = try await HostedInstrument.make(auConfig, sampleRate: 48_000)
        try check(try render(hosted) > 0.001, "Installed AU MIDI rendering silent")
        auConfig = try hosted.snapshot(auConfig)
        try check(auConfig.audioUnitState != nil, "AU preset state missing")
        let auRestored = try await HostedInstrument.make(auConfig, sampleRate: 48_000)
        try check(try render(auRestored) > 0.001, "Restored AU state is silent")
        project.tracks[1].instrumentConfiguration = auConfig
        let auProject = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        try check(auProject == project, "AU state project round-trip")
        auConfig.audioUnit?.subtype = 0x7A7A7A7A
        do {
            _ = try await HostedInstrument.make(auConfig, sampleRate: 48_000)
            throw Failure(message: "Missing plug-in unexpectedly loaded")
        } catch is MessageError { }
        // Exercise the real mixer tap → Stop → WAV clip path, with monitor muted.
        for liveConfig in [config, kickConfig] {
        let live = StudioModel()
        live.recording.source = .keyboard
        live.recording.configuration = liveConfig
        try await live.recording.prepareKeyboard()
        live.recording.hostedInstrument?.node.engine?.mainMixerNode.outputVolume = 0
        live.startRecording()
        for _ in 0..<100 where !live.recording.isRecording && live.alertMessage == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(live.recording.isRecording, "Live recording failed to start: \(live.alertMessage ?? "no error")")
        try await Task.sleep(for: .milliseconds(250))
        live.recording.noteOn(60)
        try await Task.sleep(for: .milliseconds(250))
        live.recording.noteOff(60)
        try await Task.sleep(for: .milliseconds(150))
        live.stop()
        for _ in 0..<100 where live.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        try check(live.alertMessage == nil, "Live take failed: \(live.alertMessage ?? "")")
        guard let take = live.project.tracks[0].clips.first else { throw Failure(message: "Live take missing") }
        try check(take.instrumentAddOn?.mode == liveConfig.mode && take.midiNotes?.count == 1 && take.midiSourceBPM == 120,
                  "Live instrument audio lost note/preset metadata")
        try check(take.durationBeats > 0.5 && FileManager.default.fileExists(atPath: take.assetPath), "Live WAV not saved")
        live.recording.unloadKeyboard()
        }
        print("PASS: real-time instrument tap → WAV clip with MIDI note/preset metadata (silent monitor)")
        // Render our own offscreen view only; no access to the user's screen/apps.
        _ = NSApplication.shared
        studio.recording.configuration = config
        let preview = NSHostingView(rootView: InstrumentControls(studio: studio).padding().frame(width: 1120).background(Color(nsColor: .windowBackgroundColor)))
        preview.frame = NSRect(x: 0, y: 0, width: 1120, height: 175)
        preview.layoutSubtreeIfNeeded()
        if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/sketch-synth-controls.png"))
        }
        studio.recording.configuration = kickConfig
        let kickPreview = NSHostingView(rootView: RecordingPanel(studio: studio).frame(width: 1120))
        kickPreview.frame = NSRect(x: 0, y: 0, width: 1120, height: 360)
        studio.recording.source = .keyboard
        kickPreview.layoutSubtreeIfNeeded()
        if let bitmap = kickPreview.bitmapImageRepForCachingDisplay(in: kickPreview.bounds) {
            kickPreview.cacheDisplay(in: kickPreview.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/kick-lab-controls.png"))
        }
        print("PASS: synth DSP, AU discovery/MIDI/state, missing AU handling, instrument capture, per-track presets and undo/redo")
    }
    static func testFollow() throws {
        let viewport = TimelineViewport(offset: 0, width: 600, contentWidth: 4000)
        try check(TimelineFollow.target(playheadX: 400, viewport: viewport, enabled: true, playing: true) == nil, "Follow moved before edge")
        try check(TimelineFollow.target(playheadX: 510, viewport: viewport, enabled: true, playing: true) == 360, "Follow lost cursor at edge")
        try check(TimelineFollow.target(playheadX: 2000, viewport: viewport, enabled: false, playing: true) == nil, "Follow off still scrolls")
        try check(TimelineFollow.target(playheadX: 2000, viewport: viewport, enabled: true, playing: false) == nil, "Stopped timeline moved")
        try check(TimelineFollow.target(playheadX: 2000, viewport: viewport, enabled: true, playing: false, force: true) == 1850, "Re-enabling follow did not reveal cursor")
        try check(TimelineFollow.target(playheadX: 3950, viewport: viewport, enabled: true, playing: true) == 3400, "Follow exceeded content")
        let scrolled = TimelineViewport(offset: 1800, width: 300, contentWidth: 5000)
        try check(TimelineFollow.target(playheadX: 500, viewport: scrolled, enabled: true, playing: true) == 425, "Backward seek or narrow viewport lost cursor")
        try check(TimelineFollow.target(playheadX: .nan, viewport: viewport, enabled: true, playing: true) == nil, "Invalid scroll target")
        print("PASS: viewport-based follow, off/stopped guards, re-enable, backward seek, resize and end clamp")
    }
    static func testKick() throws {
        func samples(_ settings: KickSettings, rate: Double = 48_000, pitch: Int32 = 60) throws -> [Float] {
            let storage = try SynthDSPStorage(sampleRate: rate, settings: SynthSettings())
            storage.configureKick(settings)
            var left = [Float](repeating: 0, count: Int(rate * 2.1)), right = left
            SketchSynthNote(storage.handle, pitch, 110, 1)
            SketchSynthNote(storage.handle, pitch, 0, 0) // note-off must not choke a one-shot
            SketchSynthRender(storage.handle, &left, &right, UInt32(left.count))
            try check(left.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Kick non-finite or clipped")
            try check(left.suffix(1000).allSatisfy { $0 == 0 }, "Kick did not decay to silence")
            return left
        }
        var energies: [Int] = []
        for name in ["Deep House", "909-inspired", "Punch", "Sub"] {
            let signal = try samples(.preset(name))
            try check(signal.map(abs).max()! > 0.05, "Silent kick preset")
            energies.append(Int(signal.reduce(0.0) { $0 + Double($1 * $1) } * 100))
        }
        try check(Set(energies).count == 4, "Kick presets sound identical")
        let base = try samples(KickSettings())
        for key in [\KickSettings.tune, \.decay, \.sweep, \.sweepTime, \.click, \.drive, \.gain] {
            var settings = KickSettings()
            settings[keyPath: key] *= 0.7
            let changed = try samples(settings)
            let difference = zip(base, changed).reduce(0.0) { $0 + abs(Double($1.0 - $1.1)) }
            try check(difference > 0.01, "Kick parameter had no effect")
        }
        for rate in [44_100.0, 96_000.0] { _ = try samples(KickSettings(), rate: rate) }
        for pitch in 0..<128 {
            let storage = try SynthDSPStorage(sampleRate: 48_000, settings: SynthSettings())
            storage.configureKick(KickSettings())
            var left = [Float](repeating: 0, count: 4096), right = left
            SketchSynthNote(storage.handle, Int32(pitch), 110, 1)
            SketchSynthRender(storage.handle, &left, &right, 4096)
            try check(left.map(abs).max()! > 0.05, "Kick key \(pitch) silent")
        }
        print("PASS: Kick Lab presets, seven audible controls, one-shot release, finite output and all 128 keys")
    }
    static func testDSP() throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let storage = try SynthDSPStorage(sampleRate: rate, settings: SynthSettings(attack: 0.002, cutoff: 18_000))
            var left = [Float](repeating: 0, count: 8192), right = left
            for pitch in 0..<128 {
                SketchSynthPanic(storage.handle)
                SketchSynthNote(storage.handle, Int32(pitch), 100, 1)
                SketchSynthRender(storage.handle, &left, &right, UInt32(left.count))
                try check(left.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Non-finite or unbounded synth output")
                try check(left.map(abs).max()! > 0.001, "Silent pitch \(pitch) at \(rate)")
            }
            for pitch in 40..<80 { SketchSynthNote(storage.handle, Int32(pitch), 127, 1) }
            SketchSynthRender(storage.handle, &left, &right, UInt32(left.count))
            try check(left.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Polyphony overflow")
            for _ in 0..<600 { SketchSynthNote(storage.handle, 60, 100, 1) }
            SketchSynthRender(storage.handle, &left, &right, UInt32(left.count))
            try check(left.allSatisfy { $0 == 0 }, "Event overflow did not release notes")
        }
        func energy(_ waveform: SynthWaveform, cutoff: Double, release: Bool = false) throws -> Double {
            let storage = try SynthDSPStorage(sampleRate: 48_000, settings: SynthSettings(waveform: waveform, attack: 0.002, release: 0.01, cutoff: cutoff))
            var l = [Float](repeating: 0, count: 8192), r = l
            SketchSynthNote(storage.handle, 72, 127, 1)
            SketchSynthRender(storage.handle, &l, &r, UInt32(l.count))
            if release {
                SketchSynthNote(storage.handle, 72, 0, 0)
                SketchSynthRender(storage.handle, &l, &r, UInt32(l.count))
                SketchSynthRender(storage.handle, &l, &r, UInt32(l.count))
            }
            return l.reduce(0) { $0 + Double($1 * $1) }
        }
        let energies = try SynthWaveform.allCases.map { try energy($0, cutoff: 18_000) }
        try check(Set(energies.map { Int($0 * 100) }).count == 4, "Waveforms are not distinct")
        let low = try energy(.saw, cutoff: 80), high = try energy(.saw, cutoff: 18_000)
        try check(low < high / 20, "Low-pass filter has no effect")
        let released = try energy(.square, cutoff: 18_000, release: true)
        try check(released == 0, "Envelope release left stuck notes")
    }
    static func render(_ hosted: HostedInstrument) throws -> Float {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(hosted.node)
        engine.connect(hosted.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        defer { hosted.panic(); engine.stop(); engine.disableManualRenderingMode(); engine.detach(hosted.node) }
        hosted.note(60, velocity: 100, on: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var peak: Float = 0
        for index in 0..<30 {
            let status = try engine.renderOffline(1024, to: buffer)
            try check(status == .success, "Instrument render status \(status)")
            for n in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][n])) }
            if index == 20 { hosted.note(60, velocity: 0, on: false) }
        }
        return peak
    }
    static func testCapture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("instrument-capture-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let anchor = AVAudioTime.hostTime(forSeconds: 100)
        do {
            let sink = try InstrumentAudioCapture(url: url, format: format, anchor: anchor)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0.25, count: 1024) }
            sink.append(buffer, time: AVAudioTime(hostTime: anchor - AVAudioTime.hostTime(forSeconds: 512.0 / 48_000)))
            sink.append(buffer, time: AVAudioTime(hostTime: anchor + AVAudioTime.hostTime(forSeconds: 1024.0 / 48_000)))
            try sink.finish()
        }
        let file = try AVAudioFile(forReading: url)
        try check(file.length == 2048, "Capture duration/alignment incorrect: \(file.length)")
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)!
        try file.read(into: result)
        let samples = result.floatChannelData![0]
        try check(abs(samples[100] - 0.25) < 0.0001 && samples[700] == 0 && abs(samples[1500] - 0.25) < 0.0001,
                  "Preroll trim or timestamp gap padding wrong")
    }
}
