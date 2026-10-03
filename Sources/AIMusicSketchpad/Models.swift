import Foundation

enum MusicalPart: String, Codable, CaseIterable, Identifiable {
    case drums
    case bass
    case chords
    case melody
    case fullArrangement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drums: "Drums"
        case .bass: "Bass"
        case .chords: "Chords"
        case .melody: "Melody"
        case .fullArrangement: "Full Arrangement"
        }
    }
}

struct MIDINote: Codable, Hashable, Identifiable {
    var id = UUID()
    var pitch: Int
    var velocity: Double
    var startBeat: Double
    var durationBeats: Double
}

struct EffectSettings: Codable, Hashable {
    var lowGain = 0.0
    var midGain = 0.0
    var highGain = 0.0
    var compression = 0.0
    var reverb = 0.0
    var delay = 0.0
    var drive = 0.0
    var bitCrush = 0.0
    var filterMode: FilterMode = .off
    var filterCutoff = 8_000.0
    var filterResonance = 0.0
    var reverbSpace: ReverbSpace = .hall
    var delayTime = 0.25
    var delayFeedback = 0.22

    init() {}
    private enum CodingKeys: String, CodingKey {
        case lowGain, midGain, highGain, compression, reverb, delay, drive, bitCrush
        case filterMode, filterCutoff, filterResonance, reverbSpace, delayTime, delayFeedback
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowGain = try c.decodeIfPresent(Double.self, forKey: .lowGain) ?? 0
        midGain = try c.decodeIfPresent(Double.self, forKey: .midGain) ?? 0
        highGain = try c.decodeIfPresent(Double.self, forKey: .highGain) ?? 0
        compression = try c.decodeIfPresent(Double.self, forKey: .compression) ?? 0
        reverb = try c.decodeIfPresent(Double.self, forKey: .reverb) ?? 0
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        drive = try c.decodeIfPresent(Double.self, forKey: .drive) ?? 0
        bitCrush = try c.decodeIfPresent(Double.self, forKey: .bitCrush) ?? 0
        filterMode = try c.decodeIfPresent(FilterMode.self, forKey: .filterMode) ?? .off
        filterCutoff = try c.decodeIfPresent(Double.self, forKey: .filterCutoff) ?? 8_000
        filterResonance = try c.decodeIfPresent(Double.self, forKey: .filterResonance) ?? 0
        reverbSpace = try c.decodeIfPresent(ReverbSpace.self, forKey: .reverbSpace) ?? .hall
        delayTime = try c.decodeIfPresent(Double.self, forKey: .delayTime) ?? 0.25
        delayFeedback = try c.decodeIfPresent(Double.self, forKey: .delayFeedback) ?? 0.22
    }
}

enum FilterMode: String, Codable, CaseIterable, Identifiable {
    case off = "Off", lowPass = "Low-pass", highPass = "High-pass", bandPass = "Band-pass"
    var id: String { rawValue }
}
enum ReverbSpace: String, Codable, CaseIterable, Identifiable {
    case room = "Small Room", plate = "Plate", hall = "Medium Hall", cathedral = "Cathedral"
    var id: String { rawValue }
}

struct ClipModel: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var assetPath: String
    var startBeat: Double
    var durationBeats: Double
    var sourceOffsetSeconds = 0.0
    var sourceDurationSeconds: Double
    var loopEnabled = false
    var midiNotes: [MIDINote]?
    var generatedPart: MusicalPart?
    var prompt: String?
    // Optional fields keep projects made by the first version readable.
    var loopLengthSeconds: Double?
    var playbackOffsetSeconds: Double?
    var instrument: KeyboardInstrument?
    var generationMethod: String?
    var generationReference: GenerationReference?
    // Tempo of the MIDI source WAV, independent of subsequent project tempo edits.
    var midiSourceBPM: Double?
    var instrumentAddOn: InstrumentConfiguration?
    // Opt-in on new supported keyboard takes only; legacy recordings stay audio.
    var notesEditable: Bool?

    var endBeat: Double { startBeat + durationBeats }
    var assetURL: URL { URL(fileURLWithPath: assetPath) }
    var sourceRegionSeconds: Double {
        max(0.001, min(loopLengthSeconds ?? sourceDurationSeconds,
                       sourceDurationSeconds - sourceOffsetSeconds))
    }
}

struct TrackModel: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
    var volume = 0.85
    var pan = 0.0
    var isMuted = false
    var isSolo = false
    var effects = EffectSettings()
    var clips: [ClipModel] = []
    var generationSettings: GenerationRequest?
    var automation: [AutomationLane]?
    var instrumentConfiguration: InstrumentConfiguration?

    static func new(index: Int) -> TrackModel {
        let colors = ["4F8CFF", "A66BFF", "FF6B87", "F2A93B", "39B98A", "54B9D1", "D16BA5", "8BBF4D"]
        return TrackModel(name: "Track \(index + 1)", colorHex: colors[index % colors.count])
    }
}

struct StudioProject: Codable, Hashable {
    static let maximumTrackCount = 8

    var id = UUID()
    var name = "Untitled Sketch"
    var bpm = 120.0
    var key = "C minor"
    var sampleRate = 48_000.0
    var lengthBeats = 64.0
    var tracks: [TrackModel] = (0..<4).map(TrackModel.new)

    mutating func refreshLength() {
        let clipEnd = tracks.flatMap(\.clips).map(\.endBeat).max() ?? 0
        lengthBeats = max(16, ceil(clipEnd / 4) * 4)
    }
}

struct GenerationRequest: Hashable, Codable {
    var prompt = "Warm organic house groove with a spacious, uplifting feel"
    var part: MusicalPart = .fullArrangement
    var bars = 8
    var key = "C minor"
    var model = "qwen2.5:3b"
    var endpoint = "http://127.0.0.1:11434"
    var engine: GenerationEngine = .audio
    var seed = Int.random(in: 1...999_999)
    var input: GenerationInput = .textOnly
    var referenceStartBeat = 0.0
    var referenceEndBeat = 8.0
    // Absolute output boundary; nil keeps the existing bars-based behavior.
    var outputEndBeat: Double?
    var useLocalModel: Bool { engine == .localNotes }
}

enum GenerationInput: String, CaseIterable, Codable, Identifiable {
    case textOnly = "New sound from prompt"
    case trackAudio = "Improvise from this track"
    var id: String { rawValue }
}

struct GenerationReference: Codable, Hashable {
    var trackID: UUID
    var trackName: String
    var startBeat: Double
    var endBeat: Double
    var assetPath: String
}

enum GenerationEngine: String, CaseIterable, Codable, Identifiable {
    case audio = "Text → Audio (MusicGen)"
    case localNotes = "Text → Instrument notes (Ollama)"
    case builtIn = "Built-in instrument patterns"
    var id: String { rawValue }
}

enum RecordingSource: String, CaseIterable, Identifiable {
    case microphone = "Microphone / audio input"
    case keyboard = "Keyboard / MIDI"
    var id: String { rawValue }
}

enum KeyboardInstrument: String, CaseIterable, Codable, Identifiable {
    case piano = "Piano", electricPiano = "Electric piano", bass = "Bass"
    case strings = "Strings", lead = "Synth lead", drums = "Drum kit"
    case house = "House Kit", oriental = "Oriental Kit", oud = "Oud"
    case deepHouse = "Deep House Kit", tr909 = "TR-909 Kit"
    case signature = "Signature Kit", aurora = "Aurora Kit"
    var isOriginalKit: Bool { self == .signature || self == .aurora }
    var bankNames: [String] { self == .aurora ? AuroraKit.bankNames : SignatureKit.bankNames }
    var id: String { rawValue }
    var program: UInt8 {
        switch self {
        case .piano, .drums, .house, .oriental, .oud, .deepHouse, .tr909, .signature, .aurora: 0
        case .electricPiano: 4
        case .bass: 33
        case .strings: 48
        case .lead: 80
        }
    }
    var isPercussion: Bool { [.drums, .house, .oriental, .deepHouse, .tr909].contains(self) }
    var isElectronicDrumKit: Bool { [.house, .deepHouse, .tr909].contains(self) }
    var libraryPath: String? {
        switch self {
        case .house: "/Library/Application Support/Logic/Sampler Instruments/03 Drums & Percussion/02 Electronic Drum Kits/Pure House Kit.exs"
        case .deepHouse: "/Library/Application Support/Logic/Sampler Instruments/03 Drums & Percussion/02 Electronic Drum Kits/Deep Bass House Kit.exs"
        case .tr909: "/Library/Application Support/Logic/Sampler Instruments/03 Drums & Percussion/02 Electronic Drum Kits/Roland TR-909 Unprocessed Kit.exs"
        case .oriental: "/Library/Application Support/Logic/Sampler Instruments/10 World/08 South Asian/Indian & Middle Eastern Kit.exs"
        case .oud: "/Library/Application Support/Logic/Sampler Instruments/10 World/05 Middle Eastern/Turkish Oud Lute+.exs"
        default: nil
        }
    }
    static func forPart(_ part: MusicalPart) -> Self {
        switch part {
        case .drums: .drums
        case .bass: .bass
        case .chords: .electricPiano
        default: .lead
        }
    }
}

struct MessageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum StudioError: LocalizedError {
    case trackLimit
    case noTrackSelected
    case noClipSelected
    case invalidAudio
    case llmUnavailable
    case malformedLLMResponse

    var errorDescription: String? {
        switch self {
        case .trackLimit: "The project supports up to eight tracks."
        case .noTrackSelected: "Select a track first."
        case .noClipSelected: "Select a clip first."
        case .invalidAudio: "The selected audio file could not be imported."
        case .llmUnavailable: "The local Ollama service is not available."
        case .malformedLLMResponse: "The local model returned invalid MIDI data."
        }
    }
}
