import AVFoundation
import Foundation

enum PlaybackPerformanceTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SketchpadPlayback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.017)) * 0.05
            }
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings)
            try file.write(from: buffer)
        }
        var clip = ClipModel(name: "Trimmed loop", assetPath: source.path, startBeat: 0.4,
                             durationBeats: 8, sourceDurationSeconds: 1, loopEnabled: true)
        clip.sourceOffsetSeconds = 0.1
        clip.loopLengthSeconds = 0.2
        clip.playbackOffsetSeconds = 0.05
        var project = StudioProject()
        project.tracks = [TrackModel.new(index: 0)]
        project.tracks[0].volume = 1
        project.tracks[0].clips = [clip]
        var overlap = clip
        overlap.id = UUID(); overlap.startBeat = 4; overlap.durationBeats = 2
        project.tracks[0].clips.append(overlap)
        project.lengthBeats = 10
        let output = directory.appendingPathComponent("loop-mix.wav")
        try OfflineMixRenderer.render(project: project, to: output)
        let result = try AVAudioFile(forReading: output)
        let rendered = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length))!
        try result.read(into: rendered)
        // Compare source samples, including trim phase, repeats, overlap and end silence.
        var worst: Float = 0
        for frame in 0..<Int(rendered.frameLength) {
            var expected: Float = 0
            for region in project.tracks[0].clips {
                let elapsed = frame - Int((region.startBeat / 2 * 48_000).rounded())
                if elapsed >= 0 && elapsed < Int((region.durationBeats / 2 * 48_000).rounded()) {
                    let index = 4_800 + (elapsed + 2_400) % 9_600
                    expected += buffer.floatChannelData![0][index]
                }
            }
            worst = max(worst, abs(rendered.floatChannelData![0][frame] - expected))
        }
        try check(worst < 0.0001, "Loop scheduling changed samples or repeated/dropped audio: \(worst)")

        var silent = project
        silent.tracks[0].isMuted = true
        silent.tracks[0].clips[0].assetPath = "/missing-muted-file.wav"
        for empty in [false, true] {
            if empty { silent.tracks = [] }
            let silentURL = directory.appendingPathComponent("silence-\(empty).wav")
            try OfflineMixRenderer.render(project: silent, to: silentURL)
            let silentFile = try AVAudioFile(forReading: silentURL)
            let silence = AVAudioPCMBuffer(pcmFormat: silentFile.processingFormat, frameCapacity: AVAudioFrameCount(silentFile.length))!
            try silentFile.read(into: silence)
            try check(silentFile.length == 240_000, "Silent export duration changed")
            try check((0..<Int(silence.frameLength)).allSatisfy { abs(silence.floatChannelData![0][$0]) < 0.000001 },
                      "Muted/empty export wasn't silent")
        }

        // Hundreds of loop repetitions and many muted tracks must not create hundreds of players/files.
        clip.startBeat = 0; clip.durationBeats = 1_200
        project.lengthBeats = 1_200
        project.tracks = (0..<12).map { index in
            var track = TrackModel.new(index: index)
            track.clips = [clip]
            track.clips[0].id = UUID()
            track.isMuted = index != 0
            track.volume = 0 // Test transport/scheduling without sending test tones to speakers.
            return track
        }
        let audio = AudioEngineController()
        defer { audio.stop() }
        let began = Date()
        try audio.play(project: project, fromBeat: 20)
        try check(audio.playerCount == 12 && audio.activePlayerCount == 1, "Muted/looped tracks still multiply players/files")
        try await Task.sleep(for: .milliseconds(240))
        let before = audio.currentBeat
        project.tracks[1].isMuted = false
        audio.updateMix(project: project)
        try check(audio.activePlayerCount == 2 && audio.currentBeat >= before, "Unmute restarted transport or failed to schedule")
        project.tracks[1].isSolo = true
        audio.updateMix(project: project)
        try check(audio.activePlayerCount == 1, "Solo did not suspend other tracks")
        project.tracks[1].isMuted = true
        audio.updateMix(project: project)
        try check(audio.activePlayerCount == 0 && audio.isPlaying, "All-muted transport should advance without files")
        project.tracks[1].isSolo = false
        audio.updateMix(project: project)
        try check(audio.activePlayerCount == 1, "Leaving solo failed to resume the remaining audible track")
        for index in project.tracks.indices { project.tracks[index].isMuted = false }
        audio.updateMix(project: project)
        try check(audio.activePlayerCount == 12 && audio.playerCount == 12, "Unmuting all tracks multiplied players")
        try await Task.sleep(for: .milliseconds(200))
        for index in project.tracks.indices { project.tracks[index].isMuted = index != 0 }
        audio.updateMix(project: project)
        try check(audio.activePlayerCount == 1, "Re-muting did not release audio files")
        audio.stop()
        try check(audio.playerCount == 0 && audio.activePlayerCount == 0, "Stop leaked playback resources")
        project.tracks[0].clips[0].startBeat = 100
        try audio.play(project: project, fromBeat: 99)
        try await Task.sleep(for: .milliseconds(200))
        try check(audio.currentBeat >= 99 && audio.currentBeat < 100, "Seek changed shared transport origin")
        audio.stop()
        print("PASS: 12 tracks × 3,000 loop repeats: 12 players, 1 active file; mute/unmute/solo and cleanup (\(String(format: "%.2f", Date().timeIntervalSince(began)))s)")

        // Muted missing files must not break export/playback; changing mute reports errors cleanly.
        project.tracks[1].clips[0].assetPath = directory.appendingPathComponent("missing.wav").path
        var reported = false
        audio.onFailure = { _ in reported = true }
        try audio.play(project: project)
        project.tracks[1].isMuted = false
        audio.updateMix(project: project)
        try check(reported && !audio.isPlaying && audio.playerCount == 0, "Unmute read failure wasn't safely reported")
        var automation = project
        automation.tracks[0].automation = [AutomationLane(parameter: .volume, points: [
            AutomationPoint(seconds: 2, value: 0.5), AutomationPoint(seconds: 0, value: -0.5)
        ])]
        let prepared = automation.preparedForPlayback()
        for second in stride(from: 0.0, through: 3.0, by: 0.1) {
            try check(automation.tracks[0].automated(at: second).volume == prepared.tracks[0].automated(at: second, presorted: true).volume,
                      "Prepared automation changed interpolation")
        }
        print("PASS: sample-accurate trimmed/overlapping loops, mute error recovery, cached automation")
    }
}
