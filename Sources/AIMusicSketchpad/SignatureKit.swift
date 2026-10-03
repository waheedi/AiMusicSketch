import AVFoundation
import AudioToolbox
import Foundation

/// Original, deterministic synthesis. No imported samples, model, or downloads.
enum SignatureKit {
    static let sampleRate = 48_000.0
    static let bankNames = ["Drums", "Percussion", "Bass", "Minor chords", "Plucks", "Leads"]
    static let drumNames = ["Sub kick", "Tight kick", "Snare", "Clap", "Closed hat", "Open hat",
                            "Low tom", "Mid tom", "High tom", "Rim", "Shaker", "Crash"]
    static let percussionNames = ["Low conga", "High conga", "Bongo", "Woodblock", "Claves", "Cowbell",
                                  "Tambourine", "Cabasa", "Metal hit", "Seed shaker", "Zap", "Riser"]
    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func bank(for note: Int) -> Int { max(0, min(5, note / 12 - 2)) }
    static func sourceIndex(for note: Int) -> Int {
        let group = bank(for: note)
        return group < 2 ? group * 12 + (max(0, note) % 12) : 22 + group
    }
    static func label(for note: Int) -> String {
        let group = bank(for: note), key = max(0, note) % 12
        if group == 0 { return drumNames[key] }
        if group == 1 { return percussionNames[key] }
        return "\(noteNames[key])\(group == 3 ? "m" : "") \(["Bass", "Chord", "Pluck", "Lead"][group - 2])"
    }

    static func load(into sampler: AVAudioUnitSampler) throws {
        let directory = try cacheDirectory()
        let url = directory.appendingPathComponent("Signature.sf2")
        if !FileManager.default.fileExists(atPath: url.path) {
            try SignatureSoundBank.make().write(to: url, options: .atomic)
        }
        try sampler.loadSoundBankInstrument(at: url, program: 0,
                                            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                            bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    }

    private static func cacheDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AI Music Sketchpad/SignatureKit-v4", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Diagnostic source WAVs; the app itself needs only the generated SoundFont.
    static func sampleURLs() throws -> [URL] {
        let manager = FileManager.default
        let directory = try cacheDirectory()
        return try (0..<28).map { index in
            let url = directory.appendingPathComponent("sound-\(index).wav")
            if manager.fileExists(atPath: url.path) { return url }
            let temporary = directory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? manager.removeItem(at: temporary) }
            let samples = synthesize(index)
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw StudioError.invalidAudio
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pointer in
                buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
            }
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
                try file.write(from: buffer)
            }
            do { try manager.moveItem(at: temporary, to: url) }
            catch { if !manager.fileExists(atPath: url.path) { throw error } }
            return url
        }
    }

    static func synthesize(_ index: Int) -> [Float] {
        precondition((0..<28).contains(index))
        let root = index >= 24 ? 440 * pow(2, Double(48 + (index - 24) * 12 - 69) / 12) : 0
        let looped = index == 24 || index == 25 || index == 27
        let cycles = index == 25 || index == 27 ? 2_048.0 : 128.0
        let frames = looped ? Int((sampleRate * cycles / root).rounded())
            : Int(sampleRate * (index == 26 ? 2.0 : (index == 11 || index == 23 ? 1.6 : 0.9)))
        var samples = [Float](repeating: 0, count: frames)
        var random = UInt64(index + 1) &* 0x9E3779B97F4A7C15
        var previousNoise = 0.0
        let tau = 2 * Double.pi
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(random >> 40) / Double(1 << 23) - 1
            let highNoise = (noise - previousNoise) * 0.5
            previousNoise = noise
            var value: Double
            switch index {
            case 0, 1: // Frequency-swept sine kick and a short noisy beater.
                let base = index == 0 ? 48.0 : 64.0
                let decay = index == 0 ? 0.24 : 0.13
                let phase = tau * (base * t + 4.2 * (1 - exp(-t / 0.022)))
                value = sin(phase) * exp(-t / decay) + 0.15 * highNoise * exp(-t / 0.007)
            case 2:
                value = (0.55 * sin(tau * 180 * t) + 0.22 * sin(tau * 327 * t)) * exp(-t / 0.055)
                    + 0.65 * highNoise * exp(-t / 0.12)
            case 3:
                let bursts = [0.0, 0.012, 0.024].reduce(0.0) { sum, start in
                    sum + (t >= start ? exp(-(t - start) / 0.014) : 0)
                }
                value = highNoise * (bursts + 0.4 * exp(-t / 0.12))
            case 4, 5:
                let metal = sin(tau * 7_110 * t) * sin(tau * 4_137 * t)
                value = (highNoise * 0.8 + metal * 0.2) * exp(-t / (index == 4 ? 0.035 : 0.22))
            case 6...8:
                let frequency = [92.0, 137.0, 203.0][index - 6]
                value = sin(tau * (frequency * t + 1.2 * (1 - exp(-t / 0.025)))) * exp(-t / 0.17)
                    + 0.12 * noise * exp(-t / 0.012)
            case 9:
                value = (sin(tau * 870 * t) + 0.5 * sin(tau * 2_310 * t)) * exp(-t / 0.023)
            case 10:
                value = highNoise * sin(tau * 27 * t) * exp(-t / 0.065)
            case 11:
                value = (0.6 * highNoise + 0.25 * sin(tau * 3_170 * t) * sin(tau * 4_913 * t)) * exp(-t / 0.4)
            case 12...14:
                let frequency = [180.0, 260.0, 390.0][index - 12]
                value = (sin(tau * frequency * t + 1.1 * sin(tau * frequency * 1.5 * t) * exp(-t / 0.015))
                    + 0.2 * sin(tau * frequency * 2.7 * t)) * exp(-t / 0.1)
            case 15, 16:
                let frequency = index == 15 ? 740.0 : 1_730.0
                value = (sin(tau * frequency * t) + 0.3 * sin(tau * frequency * 2.23 * t)) * exp(-t / 0.035)
            case 17:
                value = (sin(tau * 540 * t) + 0.6 * sin(tau * 800 * t) + 0.2 * sin(tau * 1_600 * t)) * exp(-t / 0.12)
            case 18:
                value = (highNoise + 0.3 * sin(tau * 6_319 * t) * sin(tau * 8_123 * t)) * exp(-t / 0.15)
            case 19:
                value = highNoise * pow(max(0, sin(tau * 43 * t)), 2) * exp(-t / 0.08)
            case 20:
                value = (sin(tau * 1_440 * t) + 0.45 * sin(tau * 2_141 * t) + 0.25 * sin(tau * 3_711 * t)) * exp(-t / 0.19)
            case 21:
                value = noise * (0.3 + 0.7 * pow(max(0, sin(tau * 19 * t)), 4)) * exp(-t / 0.11)
            case 22:
                value = sin(tau * (210 * t + 18 * (1 - exp(-t / 0.055)))) * exp(-t / 0.11)
            case 23:
                value = (0.5 * highNoise + 0.3 * sin(tau * (160 * t + 700 * t * t)))
                    * pow(sin(.pi * Double(frame) / Double(frames)), 2)
            case 24:
                let phase = tau * cycles * Double(frame) / Double(frames)
                value = 0.7 * sin(phase) + 0.35 * sin(phase / 2) + 0.18 * sin(phase * 2) + 0.08 * sin(phase * 3)
            case 25:
                // Whole cycles give seamless loops; the chord is equal-tempered to <1 cent.
                value = [0.0, 3.0, 7.0].reduce(0) { sum, interval in
                    let n = (cycles * pow(2, interval / 12)).rounded()
                    let phase = tau * n * Double(frame) / Double(frames)
                    return sum + sin(phase) * 0.24 + sin(phase * 2) * 0.065
                }
            case 26:
                value = (sin(tau * root * t) + 0.45 * sin(tau * root * 2 * t) * exp(-t / 0.13)
                    + 0.2 * sin(tau * root * 3 * t) * exp(-t / 0.07)) * exp(-t / 0.36)
            default:
                let phase = tau * cycles * Double(frame) / Double(frames)
                value = sin(phase) + 0.32 * sin(phase * 2) + 0.17 * sin(phase * 3) + 0.07 * sin(phase * 4)
            }
            if !looped {
                value *= min(1, t / 0.0015, Double(frames - 1 - frame) / (sampleRate * 0.015))
            }
            samples[frame] = Float(value)
        }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let gain: Float = (index >= 24 ? 0.42 : 0.65) / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return samples
    }
}
