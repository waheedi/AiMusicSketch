import Foundation

enum AutomationParameter: String, Codable, CaseIterable, Identifiable {
    case volume = "Volume", pan = "Pan", lowGain = "Low EQ", midGain = "Mid EQ", highGain = "High EQ"
    case compression = "Compression", reverb = "Reverb", delay = "Delay"
    var id: String { rawValue }
    var scale: Double {
        switch self { case .lowGain, .midGain, .highGain: 24; default: 1 }
    }
    func label(_ value: Double) -> String {
        let unit = scale == 24 ? "dB" : "%"
        return String(format: "%+.0f %@", value * (scale == 24 ? 24 : 100), unit)
    }
}

struct AutomationPoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var seconds: Double
    var value: Double
}

struct AutomationLane: Codable, Hashable, Identifiable {
    var parameter: AutomationParameter
    var points: [AutomationPoint] = []
    var id: AutomationParameter { parameter }
    func value(at seconds: Double) -> Double {
        let sorted = points.filter { $0.seconds.isFinite && $0.value.isFinite && $0.seconds >= 0 }
            .sorted { $0.seconds < $1.seconds }
        var previous = AutomationPoint(seconds: 0, value: 0)
        for point in sorted {
            if seconds < point.seconds {
                let span = point.seconds - previous.seconds
                let amount = span > 0 ? max(0, min(1, (seconds - previous.seconds) / span)) : 1
                return max(-1, min(1, previous.value + (point.value - previous.value) * amount))
            }
            previous = point
        }
        return max(-1, min(1, previous.value))
    }
}

extension TrackModel {
    func automated(at seconds: Double) -> TrackModel {
        var result = self
        for lane in automation ?? [] {
            let offset = lane.value(at: seconds) * lane.parameter.scale
            switch lane.parameter {
            case .volume: result.volume = max(0, min(1, volume + offset))
            case .pan: result.pan = max(-1, min(1, pan + offset))
            case .lowGain: result.effects.lowGain = max(-24, min(24, effects.lowGain + offset))
            case .midGain: result.effects.midGain = max(-24, min(24, effects.midGain + offset))
            case .highGain: result.effects.highGain = max(-24, min(24, effects.highGain + offset))
            case .compression: result.effects.compression = max(0, min(1, effects.compression + offset))
            case .reverb: result.effects.reverb = max(0, min(1, effects.reverb + offset))
            case .delay: result.effects.delay = max(0, min(1, effects.delay + offset))
            }
        }
        return result
    }
}
