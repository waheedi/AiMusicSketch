import Foundation

enum AutomationParameter: String, Codable, CaseIterable, Identifiable {
    case volume = "Volume", pan = "Pan", lowGain = "Low EQ", midGain = "Mid EQ", highGain = "High EQ"
    case compression = "Compression", reverb = "Reverb", delay = "Delay"
    case drive = "Drive", bitCrush = "Bit-crush", filterCutoff = "Filter cutoff", filterResonance = "Filter resonance"
    case delayTime = "Delay time", delayFeedback = "Delay feedback"
    var id: String { rawValue }
    var scale: Double {
        switch self { case .lowGain, .midGain, .highGain: 24; default: 1 }
    }
    func label(_ value: Double) -> String {
        if self == .filterCutoff { return String(format: "%+.1f octaves", value * 5) }
        if self == .delayTime { return String(format: "%+.2f s", value) }
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
    var sortedPoints: [AutomationPoint] {
        points.filter { $0.seconds.isFinite && $0.value.isFinite && $0.seconds >= 0 }.sorted { $0.seconds < $1.seconds }
    }
    func value(at seconds: Double, presorted: Bool = false) -> Double {
        let sorted = presorted ? points : sortedPoints
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
    func automated(at seconds: Double, presorted: Bool = false) -> TrackModel {
        var result = self
        for lane in automation ?? [] {
            let offset = lane.value(at: seconds, presorted: presorted) * lane.parameter.scale
            switch lane.parameter {
            case .volume: result.volume = max(0, min(1, volume + offset))
            case .pan: result.pan = max(-1, min(1, pan + offset))
            case .lowGain: result.effects.lowGain = max(-24, min(24, effects.lowGain + offset))
            case .midGain: result.effects.midGain = max(-24, min(24, effects.midGain + offset))
            case .highGain: result.effects.highGain = max(-24, min(24, effects.highGain + offset))
            case .compression: result.effects.compression = max(0, min(1, effects.compression + offset))
            case .reverb: result.effects.reverb = max(0, min(1, effects.reverb + offset))
            case .delay: result.effects.delay = max(0, min(1, effects.delay + offset))
            case .drive: result.effects.drive = max(0, min(1, effects.drive + offset))
            case .bitCrush: result.effects.bitCrush = max(0, min(1, effects.bitCrush + offset))
            case .filterCutoff: result.effects.filterCutoff = max(20, min(20_000, effects.filterCutoff * pow(2, offset * 5)))
            case .filterResonance: result.effects.filterResonance = max(0, min(1, effects.filterResonance + offset))
            case .delayTime: result.effects.delayTime = max(0.01, min(2, effects.delayTime + offset))
            case .delayFeedback: result.effects.delayFeedback = max(0, min(0.85, effects.delayFeedback + offset))
            }
        }
        return result
    }
}

extension StudioProject {
    // Prepare once per edit/start, never sort/allocate automation points on each transport tick.
    func preparedForPlayback() -> StudioProject {
        var result = self
        for index in result.tracks.indices {
            result.tracks[index].automation = tracks[index].automation?.compactMap { lane in
                let points = lane.sortedPoints
                return points.isEmpty ? nil : AutomationLane(parameter: lane.parameter, points: points)
            }
        }
        return result
    }
}
