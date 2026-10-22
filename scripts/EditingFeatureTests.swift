import AppKit
import AVFoundation
import Foundation

enum EditingFeatureTests {
    @MainActor static func run() async throws {
        try await checkProjectEnd()
        let studio = StudioModel()
        let original = studio.project
        let ids = original.tracks.map(\.id)
        studio.selectTrack(ids[0]); studio.selectTrack(ids[3], range: true)
        try InstrumentTests.check(studio.selectedTrackIDs == Set(ids), "Shift track range")
        studio.selectTrack(ids[2], range: true)
        try InstrumentTests.check(studio.selectedTrackIDs == Set(ids.prefix(3)), "Stable Shift anchor")
        studio.selectTrack(ids[1], additive: true)
        try InstrumentTests.check(studio.selectedTrackIDs == [ids[0], ids[2]], "Command track toggle")
        studio.deleteSelection()
        try InstrumentTests.check(studio.project.tracks.map(\.id) == [ids[1], ids[3]], "Bulk track deletion")
        studio.undo()
        try InstrumentTests.check(studio.project == original, "Bulk track Undo must be atomic")
        studio.selectTrack(ids[0]); studio.selectAll(); studio.deleteSelection()
        try InstrumentTests.check(studio.project.tracks.count == 1, "Deleting all tracks must leave a usable track")
        studio.undo()
        var config = InstrumentConfiguration(mode: .synth)
        config.synth = .preset("Glass pluck")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("merge-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let notes = [MIDINote(pitch: 60, velocity: 0.8, startBeat: 0.5, durationBeats: 0.5)]
        _ = try MIDIRenderer.render(notes: notes, configuration: config, bpm: 120, durationBeats: 2, sampleRate: 48_000, to: url)
        let a = ClipModel(name: "A", assetPath: url.path, startBeat: 2, durationBeats: 2, sourceDurationSeconds: 1,
                          midiNotes: notes, midiSourceBPM: 120, instrumentAddOn: config, notesEditable: true)
        var b = a; b.id = UUID(); b.startBeat = 6; b.durationBeats = 4; b.loopEnabled = true
        var c = a; c.id = UUID(); c.startBeat = 12
        studio.project.tracks[0].clips = [a, b, c]
        studio.selectClip(trackID: ids[0], clipID: a.id)
        studio.selectClip(trackID: ids[0], clipID: b.id, additive: true)
        let before = studio.project
        studio.mergeClips(on: ids[0], selectedOnly: true)
        for _ in 0..<300 where studio.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        try InstrumentTests.check(!studio.isBusy && studio.alertMessage == nil, "Merge failed")
        let merged = studio.project.tracks[0].clips.first { $0.id != c.id }!
        defer { try? FileManager.default.removeItem(at: merged.assetURL) }
        try InstrumentTests.check(studio.project.tracks[0].clips.count == 2 && merged.notesEditable == true,
                                  "Merge lost notes or unselected clip")
        try InstrumentTests.check(merged.midiNotes!.map(\.startBeat) == [0.5, 4.5, 6.5], "Looped note merge timing")
        try await studio.applyNotes(Array(merged.midiNotes!.dropLast()), to: merged.id)
        let editedURL = studio.clip(merged.id)!.assetURL
        defer { try? FileManager.default.removeItem(at: editedURL) }
        try InstrumentTests.check(studio.clip(merged.id)!.midiNotes!.count == 2, "Merged notes cannot be edited")
        studio.undo(); studio.undo()
        try InstrumentTests.check(studio.project == before, "Merge / note-edit Undo")
        b.instrumentAddOn?.synth.cutoff = 123
        try InstrumentTests.check(ClipMerge.editableConfiguration(for: [a, b]) == nil, "Mixed presets must not lose their sound")
        print("PASS: multi-track selection/delete/Undo; selective MIDI merge, loop timing, note edits and mixed-preset fallback")
        if AudioUnitID.installed().contains(where: \.isSurgeXT) { try await checkBank() }
    }

    @MainActor static func checkProjectEnd() async throws {
        let studio = StudioModel()
        let clip = ClipModel(name: "Preserved beyond end", assetPath: "/not-loaded-outside-project.wav",
                             startBeat: 32, durationBeats: 8, sourceDurationSeconds: 4)
        studio.project.tracks[0].clips = [clip]
        let original = studio.project
        studio.audio.playheadBeat = 40
        studio.setProjectEnd(to: 8.13)
        try InstrumentTests.check(studio.project.lengthBeats == 8.25 && studio.audio.playheadBeat == 8.25,
                                  "End marker snapping / playhead clamp")
        studio.project.refreshLength()
        try InstrumentTests.check(studio.project.lengthBeats == 8.25 && studio.project.tracks == original.tracks,
                                  "Shortened ending must survive refresh without trimming clips")
        let restored = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(studio.project))
        try InstrumentTests.check(restored == studio.project, "Manual end must survive save/open")
        studio.undo()
        try InstrumentTests.check(studio.project == original, "Resize end must Undo atomically")
        studio.redo()
        studio.isBusy = true; studio.setProjectEnd(to: 20); studio.isBusy = false
        try InstrumentTests.check(studio.project.lengthBeats == 8.25, "Busy end edit guard")
        studio.setProjectEnd(to: .nan)
        try InstrumentTests.check(studio.project.lengthBeats == 8.25, "Invalid end guard")
        studio.setProjectEnd(to: -1)
        try InstrumentTests.check(studio.project.lengthBeats == 0.25, "Minimum ending")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("end-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: output) }
        try OfflineMixRenderer.render(project: studio.project, to: output)
        try InstrumentTests.check(try AVAudioFile(forReading: output).length == 6_000,
                                  "Export must respect end and ignore files outside it")
        try studio.audio.play(project: studio.project)
        try await Task.sleep(for: .milliseconds(500))
        try InstrumentTests.check(!studio.audio.isPlaying && studio.audio.playheadBeat == 0.25,
                                  "Playback must stop at manual end")
        var extended = studio.project
        extended.refreshLength(extendingTo: 17)
        try InstrumentTests.check(extended.lengthBeats == 20, "New material must extend a manual end")
        var padded = clip
        padded.startBeat = 0; padded.durationBeats = 8; padded.trailingSilenceSeconds = 2
        let segments = scheduledSegments(for: padded, bpm: 120, fromBeat: 0, toBeat: 2)
        try InstrumentTests.check(segments.count == 1 && segments[0].durationSeconds == 1,
                                  "End clipping must not move trailing silence into audible audio")
        print("PASS: project-end snap, persistence, Undo/Redo, guards, extension, padding, bounded playback/export")
    }

    @MainActor static func checkBank() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Sketchpad-Pulse-preview.wav")
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: output, settings: settings)
        for preset in SurgePatchBank.presets {
            let configuration = try SurgePatchBank.configuration(for: preset)
            let hosted = try await HostedInstrument.make(configuration, sampleRate: 48_000)
            let engine = AVAudioEngine()
            engine.attach(hosted.node); engine.connect(hosted.node, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            try engine.start()
            defer { hosted.panic(); engine.stop(); engine.disableManualRenderingMode(); engine.detach(hosted.node) }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            func render(_ blocks: Int, write: Bool = false) throws -> Float {
                var peak: Float = 0
                for _ in 0..<blocks {
                    try InstrumentTests.check(try engine.renderOffline(1024, to: buffer) == .success, "Surge render failed")
                    for channel in 0..<2 {
                        for frame in 0..<Int(buffer.frameLength) {
                            let value = buffer.floatChannelData![channel][frame]
                            try InstrumentTests.check(value.isFinite && abs(value) < 1, "Surge patch has invalid/clipping output")
                            peak = max(peak, abs(value))
                        }
                    }
                    if write { try file.write(from: buffer) }
                }
                return peak
            }
            _ = try render(2)
            let saved = try hosted.snapshot(configuration)
            let state = try PropertyListSerialization.propertyList(from: saved.audioUnitState!, format: nil) as! [String: Any]
            let chunk = state["jucePluginState"] as! Data
            try InstrumentTests.check(chunk.range(of: Data("name=\"\(preset.name)\"".utf8)) != nil, "Wrong Surge patch loaded")
            var lowestPeak: Float = 1
            for pitch in 24...100 {
                hosted.panic(); _ = try render(2)
                hosted.note(UInt8(pitch), velocity: 100, on: true)
                let peak = try render(6)
                lowestPeak = min(lowestPeak, peak)
                try InstrumentTests.check(peak > 0.001, "\(preset.name): silent key \(pitch)")
                hosted.note(UInt8(pitch), velocity: 0, on: false)
            }
            hosted.panic(); _ = try render(12)
            for offset in [0, 4, 7] {
                let pitch = UInt8((preset.octave + 1) * 12 + offset)
                hosted.note(pitch, velocity: 100, on: true)
                _ = try render(20, write: true)
                hosted.note(pitch, velocity: 0, on: false)
                _ = try render(10, write: true)
            }
            print("PASS: \(preset.name), 77 keys including extended keyboard, lowest peak \(lowestPeak), preset state retained")
        }
        print("Bank preview: \(output.path)")
    }
}
