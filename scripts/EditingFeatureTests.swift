import AppKit
import AVFoundation
import Foundation

enum EditingFeatureTests {
    @MainActor static func run() async throws {
        try await checkProjectEnd()
        try checkGroupMove()
        try checkHeldNoteWaveform()
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

    @MainActor static func checkHeldNoteWaveform() throws {
        let preview = CommandLine.arguments.contains("--waveform-preview")
        let url = preview ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/held-synth-preview.wav")
            : FileManager.default.temporaryDirectory.appendingPathComponent("held-note-pulses-\(UUID()).wav")
        defer { if !preview { try? FileManager.default.removeItem(at: url) } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            // One held key drives eight pulses; those are sound, not eight MIDI notes.
            let value: Float = frame % 12_000 < 2_400 ? Float(sin(Double(frame) * 0.1)) * 0.5 : 0
            buffer.floatChannelData![0][frame] = 0
            buffer.floatChannelData![1][frame] = value
        }
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        let peaks = try AudioWaveform.loadPeaks(url)
        var pulses = 0, sounding = false
        for peak in peaks {
            if peak > 0.05 && !sounding { pulses += 1 }
            sounding = peak > 0.05
        }
        let clip = ClipModel(name: "Held synth key", assetPath: url.path, startBeat: 0,
                             durationBeats: 4, sourceDurationSeconds: 2,
                             midiNotes: [MIDINote(pitch: 60, velocity: 0.8, startBeat: 0, durationBeats: 4)], midiSourceBPM: 120)
        let notes = ClipNoteLayout.notes(for: clip, bpm: 120)
        try InstrumentTests.check(peaks.count == 4_096 && pulses == 8 && peaks.contains(0),
                                  "Recorded waveform must show stereo pulses and real silence")
        try InstrumentTests.check(notes.count == 1 && notes[0].durationSeconds == 2,
                                  "Sound pulses must not be invented as MIDI notes")
        print("PASS: one held MIDI key stays one note; recorded stereo waveform shows eight pulses and silent gaps")
    }

    @MainActor static func checkGroupMove() throws {
        let studio = StudioModel()
        let rows = studio.project.tracks.map(\.id)
        let a = ClipModel(name: "A", assetPath: "/unchanged.wav", startBeat: 1.1, durationBeats: 2,
                          sourceDurationSeconds: 1, loopEnabled: true,
                          midiNotes: [MIDINote(pitch: 64, velocity: 0.7, startBeat: 0.1, durationBeats: 0.4)],
                          notesEditable: true, leadingSilenceSeconds: 0.1)
        var b = a; b.id = UUID(); b.name = "B"; b.startBeat = 4.4; b.durationBeats = 5
        var c = a; c.id = UUID(); c.name = "C"; c.startBeat = 8.6
        var untouched = a; untouched.id = UUID(); untouched.startBeat = 15
        studio.project.tracks[0].clips = [a, b, untouched]
        studio.project.tracks[2].clips = [c]
        studio.visibleAutomation[rows[0]] = .volume
        studio.selectClip(trackID: rows[0], clipID: a.id)
        studio.selectClip(trackID: rows[0], clipID: b.id, additive: true)
        studio.selectClip(trackID: rows[2], clipID: c.id, additive: true)
        let before = studio.project
        let ids: Set<UUID> = [a.id, b.id, c.id]
        studio.previewClipMove(id: b.id, on: rows[2], to: 6.12)
        let preview = studio.clipMovePreview!
        try InstrumentTests.check(studio.selectedClipIDs == ids && studio.project == before,
                                  "Preview must not clear selection or change clips")
        try InstrumentTests.check(abs(preview.beatDelta - 1.6) < 0.000001 && preview.trackDelta == 1,
                                  "Group snap / last-track clamp")
        try InstrumentTests.check(preview.verticalOffsets[a.id] == 176 && preview.verticalOffsets[c.id] == 76,
                                  "Group preview must account for automation lane heights")
        studio.moveClip(id: b.id, on: rows[2], to: 6.12)
        for (original, row) in [(a, 1), (b, 1), (c, 3)] {
            var expected = original; expected.startBeat += preview.beatDelta
            try InstrumentTests.check(studio.clip(original.id) == expected && studio.location(original.id)?.track == row,
                                      "Group move changed clip length, notes, source, gaps or row spacing")
        }
        try InstrumentTests.check(studio.clip(untouched.id) == untouched && studio.selectedClipIDs == ids
                                  && studio.clipMovePreview == nil, "Group move affected unselected clip/selection")
        let moved = studio.project
        studio.undo(); try InstrumentTests.check(studio.project == before, "Group move must be one Undo")
        studio.redo(); try InstrumentTests.check(studio.project == moved, "Group move Redo")
        studio.previewClipMove(id: b.id, on: rows[0], to: -100)
        let left = studio.clipMovePreview!
        try InstrumentTests.check(abs(studio.clip(a.id)!.startBeat + left.beatDelta) < 0.000001
                                  && left.trackDelta == -1, "Group must clamp together at timeline/first track")
        studio.cancelClipMove()
        try InstrumentTests.check(studio.project == moved, "Cancelled preview must leave project unchanged")
        studio.previewClipMove(id: untouched.id, on: rows[0], to: 16)
        try InstrumentTests.check(studio.selectedClipIDs == [untouched.id] && studio.clipMovePreview?.ids == [untouched.id],
                                  "Dragging an unselected clip must move only that clip")
        studio.cancelClipMove()
        print("PASS: group drag selection/preview, one-delta timing, metadata, row bounds, automation heights, Undo/Redo/cancel")
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
