import Foundation

@MainActor
final class TextAudioGenerator {
    static let runtime = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AI Music Sketchpad/AudioRuntime")
    static var installed: Bool {
        FileManager.default.fileExists(atPath: runtime.appendingPathComponent("ready.json").path)
            && FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent(".venv/bin/python").path)
    }
    private var process: Process?

    func generate(prompt: String, seconds: Double, seed: Int, output: URL, referenceAudio: URL? = nil,
                  progress: @escaping (String) -> Void) async throws {
        guard Self.installed else {
            throw MessageError("Install the local audio model with scripts/setup-audio.sh in the project folder first.")
        }
        guard let worker = Bundle.main.url(forResource: "audio_worker", withExtension: "py")
            ?? Self.developmentWorker() else { throw MessageError("The audio generation worker is missing. Rebuild the app.") }
        let job = Self.runtime.appendingPathComponent("Jobs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let statusURL = job.appendingPathComponent("progress.json")
        let requestURL = job.appendingPathComponent("request.json")
        var request: [String: Any] = ["prompt": prompt, "seconds": seconds, "seed": seed,
                                    "output": output.path, "progress": statusURL.path]
        if let referenceAudio { request["referenceAudio"] = referenceAudio.path }
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
        let logURL = job.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = Self.runtime.appendingPathComponent(".venv/bin/python")
        child.arguments = [worker.path, "--request", requestURL.path]
        child.standardOutput = log
        child.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        child.environment = environment
        try child.run()
        process = child
        defer { process = nil }
        var latest = "Loading local audio model…"
        do {
            while child.isRunning {
                try Task.checkCancellation()
                if let data = try? Data(contentsOf: statusURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["message"] as? String, message != latest {
                    latest = message
                    progress(message)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            if child.isRunning { child.terminate() }
            // Wait off the main thread so cancellation doesn't leave an active model job.
            await Task.detached { child.waitUntilExit() }.value
            throw error
        }
        guard child.terminationStatus == 0 else {
            if let data = try? Data(contentsOf: statusURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String { latest = message }
            throw MessageError("Audio generation failed: \(latest)\nLog: \(logURL.path)")
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw StudioError.invalidAudio }
    }

    private static func developmentWorker() -> URL? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/audio_worker.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
