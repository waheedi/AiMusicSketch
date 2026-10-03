import AVFoundation
import AudioToolbox
import Foundation

/// A second original palette: electronic drums, tuned metallic percussion,
/// rounded bass, major-seventh pads, glass keys, and a bright FM lead.
enum AuroraKit {
    static let bankNames = ["Neon drums", "Prism percussion", "Pulse bass", "Major 7 pads", "Glass keys", "Orbit leads"]
    static let drumNames = ["Round kick", "FM kick", "Snap snare", "Air clap", "Tick hat", "Sizzle hat",
                            "FM low tom", "FM mid tom", "FM high tom", "Laser rim", "Dust shaker", "Splash"]
    static let percussionNames = ["Copper bell", "Crystal bell", "Steel bell", "Hollow block", "Marimba", "Kalimba",
                                  "Chime", "Glass hit", "Water drop", "Pulse tick", "Star zap", "Noise swell"]
    static func label(for note: Int) -> String {
        let bank = SignatureKit.bank(for: note), key = max(0, note) % 12
        if bank == 0 { return drumNames[key] }
        if bank == 1 { return percussionNames[key] }
        let name = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][key]
        return "\(name) \(["Bass", "maj7", "Glass", "Orbit"][bank - 2])"
    }
    static func load(into sampler: AVAudioUnitSampler) throws {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AI Music Sketchpad/AuroraKit-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Aurora.sf2")
        if !FileManager.default.fileExists(atPath: url.path) {
            try SignatureSoundBank.make(aurora: true).write(to: url, options: .atomic)
        }
        try sampler.loadSoundBankInstrument(at: url, program: 0,
            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    }
    static func synthesize(_ index: Int) -> [Float] {
        precondition((0..<28).contains(index))
        let rate = SignatureKit.sampleRate, tau = 2 * Double.pi
        let root = index >= 24 ? 440 * pow(2, Double(48 + (index - 24) * 12 - 69) / 12) : 0
        let looping = [24, 25, 27].contains(index)
        let cycles = index == 24 ? 128.0 : 2_048.0
        let frames = looping ? Int((rate * cycles / root).rounded())
            : Int(rate * (index == 26 ? 2.4 : index == 23 ? 1.8 : 1.2))
        var samples = [Float](repeating: 0, count: frames)
        var seed = UInt64(index + 91) &* 0x9E3779B97F4A7C15
        var lastNoise = 0.0
        for i in 0..<frames {
            let t = Double(i) / rate, position = Double(i) / Double(frames)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(seed >> 40) / Double(1 << 23) - 1
            let brightNoise = (noise - lastNoise) * 0.5
            lastNoise = noise
            var value: Double
            switch index {
            case 0, 1:
                let phase = tau * ((index == 0 ? 53.0 : 72.0) * t + 6 * (1 - exp(-t / 0.016)))
                value = sin(phase + (index == 0 ? 0.2 : 1.7) * sin(phase * 2) * exp(-t / 0.025)) * exp(-t / 0.19)
            case 2:
                value = 0.6 * noise * exp(-t / 0.07) + sin(tau * 235 * t + 0.6 * sin(tau * 470 * t)) * exp(-t / 0.045)
            case 3:
                let burst = [0.0, 0.018, 0.031, 0.047].reduce(0.0) { $0 + (t >= $1 ? exp(-(t - $1) / 0.009) : 0) }
                value = brightNoise * (burst + 0.3 * exp(-t / 0.2))
            case 4, 5:
                value = (sin(tau * 8_211 * t) * sin(tau * 5_533 * t) + 0.5 * brightNoise) * exp(-t / (index == 4 ? 0.018 : 0.32))
            case 6...8:
                let f = [112.0, 167.0, 249.0][index - 6]
                value = sin(tau * f * t + 2.5 * sin(tau * f * 1.98 * t) * exp(-t / 0.03)) * exp(-t / 0.14)
            case 9:
                value = sin(tau * 1_170 * t + 3 * sin(tau * 1_877 * t)) * exp(-t / 0.012)
            case 10:
                value = noise * pow(sin(tau * 63 * t), 2) * exp(-t / 0.042)
            case 11:
                value = (brightNoise + 0.4 * sin(tau * 6_017 * t) * sin(tau * 7_971 * t)) * exp(-t / 0.27)
            case 12...19:
                let n = index - 12
                let f = [320.0, 690, 455, 530, 410, 610, 1_130, 1_490][n]
                let ratio = [2.71, 3.14, 1.42, 2.0, 4.0, 3.0, 2.39, 1.71][n]
                value = (sin(tau * f * t + (1.2 + Double(n) * 0.23) * sin(tau * f * ratio * t) * exp(-t / 0.12))
                         + 0.2 * sin(tau * f * 2 * t)) * exp(-t / (0.16 + Double(n % 3) * 0.14))
            case 20:
                value = sin(tau * (600 * t + 7 * (1 - exp(-t / 0.024)))) * exp(-t / 0.11)
            case 21:
                value = sin(tau * 1_270 * t + 4 * sin(tau * 2_540 * t)) * exp(-t / 0.035)
            case 22:
                value = sin(tau * (130 * t + 36 * (1 - exp(-t / 0.07)))) * exp(-t / 0.18)
            case 23:
                value = (0.5 * noise + 0.3 * sin(tau * (320 * t + 430 * t * t))) * pow(sin(.pi * position), 3)
            case 24:
                let p = tau * cycles * position
                value = sin(p) + 0.25 * sin(3 * p) + 0.16 * sin(5 * p) + 0.28 * sin(p / 2)
                value = tanh(value * 1.8)
            case 25:
                value = [0.0, 4, 7, 11].reduce(0.0) { sum, interval in
                    let n = (cycles * pow(2, interval / 12)).rounded()
                    return sum + 0.18 * sin(tau * n * position) + 0.07 * sin(tau * (n + 2) * position)
                        + 0.04 * sin(tau * (n * 2 - 3) * position)
                }
            case 26:
                value = (sin(tau * root * t + 2.3 * sin(tau * root * 3 * t) * exp(-t / 0.09))
                    + 0.15 * sin(tau * root * 7 * t) * exp(-t / 0.18)) * exp(-t / 0.58)
            default:
                let p = tau * cycles * position
                value = sin(p + 1.25 * sin(2 * p)) + 0.18 * sin(p * 3)
            }
            if !looping { value *= min(1, t / 0.002, Double(frames - 1 - i) / (rate * 0.02)) }
            samples[i] = Float(value)
        }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let gain: Float = (index >= 24 ? 0.42 : 0.65) / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return samples
    }
}
