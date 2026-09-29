import AVFoundation
import AudioToolbox
import Foundation

final class AssetManager {
    static let shared = AssetManager()

    let assetsDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        assetsDirectory = base
            .appendingPathComponent("AI Music Sketchpad", isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )
    }

    func newAssetURL(prefix: String) -> URL {
        let safePrefix = prefix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return assetsDirectory.appendingPathComponent("\(safePrefix)-\(UUID().uuidString).wav")
    }

    func importAudio(from sourceURL: URL, sampleRate: Double) throws -> (url: URL, duration: Double) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let destination = newAssetURL(prefix: sourceURL.deletingPathExtension().lastPathComponent)
        try convert(sourceURL: sourceURL, outputURL: destination, sampleRate: sampleRate)
        let file = try AVAudioFile(forReading: destination)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        return (destination, duration)
    }

    func convert(sourceURL: URL, outputURL: URL, sampleRate: Double) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        guard inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw StudioError.invalidAudio
        }

        converter.sampleRateConverterQuality = Int(kAudioConverterQuality_Max)
        var settings = outputFormat.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else {
            throw StudioError.invalidAudio
        }
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, state in
                let remaining = inputFile.length - inputFile.framePosition
                guard remaining > 0 else {
                    state.pointee = .endOfStream
                    return nil
                }
                let count = AVAudioFrameCount(min(Int64(requested), remaining))
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: count) else {
                    readError = StudioError.invalidAudio
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: input, frameCount: count)
                    state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? StudioError.invalidAudio }
            if outputBuffer.frameLength > 0 { try outputFile.write(from: outputBuffer) }
            if status == .endOfStream { break }
        }
    }
}
