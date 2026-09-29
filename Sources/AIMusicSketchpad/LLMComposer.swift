import Foundation

struct CompositionResult {
    let notes: [MIDINote]
    let usedLocalLLM: Bool
    let detail: String
}

final class OllamaComposer {
    private struct GenerateBody: Encodable {
        let model: String
        let prompt: String
        let stream = false
        let format: Schema
        let options = Options()
        struct Options: Encodable {
            let temperature = 0.7
            let num_predict = 4096
            let num_ctx = 8192
        }
    }

    private struct Schema: Encodable {
        let type: String
        var properties: [String: Schema]?
        var required: [String]?
        var items: [Schema]?
        var minItems: Int?
        var maxItems: Int?
        var minimum: Double?
        var maximum: Double?
        // Arrays use a homogeneous item schema, not a tuple schema.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try c.encodeIfPresent(properties, forKey: .properties)
            try c.encodeIfPresent(required, forKey: .required)
            try c.encodeIfPresent(items?.first, forKey: .items)
            try c.encodeIfPresent(minItems, forKey: .minItems)
            try c.encodeIfPresent(maxItems, forKey: .maxItems)
            try c.encodeIfPresent(minimum, forKey: .minimum)
            try c.encodeIfPresent(maximum, forKey: .maximum)
        }
        enum CodingKeys: String, CodingKey {
            case type, properties, required, items, minItems, maxItems, minimum, maximum
        }
        static var notes: Schema {
            Schema(type: "object", properties: ["notes": Schema(type: "array", items: [
                Schema(type: "object", properties: [
                    "pitch": Schema(type: "integer", minimum: 0, maximum: 127),
                    "velocity": Schema(type: "number", minimum: 0.1, maximum: 1),
                    "startBeat": Schema(type: "number", minimum: 0, maximum: 7.75),
                    "durationBeats": Schema(type: "number", minimum: 0.0625, maximum: 8)
                ], required: ["pitch", "velocity", "startBeat", "durationBeats"])
            ], minItems: 8, maxItems: 64)], required: ["notes"])
        }
    }

    private struct GenerateResponse: Decodable {
        let response: String
    }

    private struct NotePayload: Decodable {
        let notes: [Note]

        struct Note: Decodable {
            let pitch: Int
            let velocity: Double
            let startBeat: Double
            let durationBeats: Double
        }
    }

    func compose(
        part: MusicalPart,
        request: GenerationRequest,
        bpm: Double
    ) async throws -> CompositionResult {
        try Task.checkCancellation()
        if !request.useLocalModel {
            let notes = RuleBasedComposer.compose(
                part: part,
                bars: request.bars,
                key: request.key,
                prompt: request.prompt
            )
            return CompositionResult(
                notes: notes,
                usedLocalLLM: false,
                detail: "Built-in local composer"
            )
        }
        // Ask the small local model for a complete two-bar motif, then repeat it to
        // the requested bar count. Long note-by-note JSON responses used to truncate.
        var motifRequest = request
        motifRequest.bars = min(2, request.bars)
        let motif = try await requestFromOllama(part: part, request: motifRequest, bpm: bpm)
        let notes = try LoopNotes.expand(motif, motifBeats: Double(motifRequest.bars * 4),
                                        totalBeats: Double(request.bars * 4), part: part)
        return CompositionResult(notes: notes, usedLocalLLM: true, detail: "Local model: \(request.model)")
    }

    func availableModels(endpoint: String) async -> [String] {
        guard let url = try? localURL(endpoint, path: "api/tags") else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }.filter { !$0.contains("cloud") }
        } catch {
            return []
        }
    }

    private func requestFromOllama(
        part: MusicalPart,
        request: GenerationRequest,
        bpm: Double
    ) async throws -> [MIDINote] {
        guard !request.model.contains("cloud") else { throw MessageError("Choose a downloaded local model.") }
        let url = try localURL(request.endpoint, path: "api/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = try JSONEncoder().encode(
            GenerateBody(
                model: request.model,
                prompt: prompt(part: part, request: request, bpm: bpm),
                format: .notes
            )
        )

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw StudioError.llmUnavailable
        }
        let outer = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let cleaned = outer.response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payloadData = cleaned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(NotePayload.self, from: payloadData)
        else { throw StudioError.malformedLLMResponse }

        let maximumBeat = Double(request.bars * 4)
        let notes = payload.notes.compactMap { note -> MIDINote? in
            guard (0..<128).contains(note.pitch), note.startBeat.isFinite,
                  note.durationBeats.isFinite, note.velocity.isFinite, note.startBeat >= 0,
                  note.startBeat < maximumBeat, note.durationBeats > 0 else { return nil }
            return MIDINote(
                pitch: note.pitch,
                velocity: max(0.05, min(1, note.velocity)),
                startBeat: note.startBeat,
                durationBeats: min(note.durationBeats, maximumBeat - note.startBeat)
            )
        }
        guard !notes.isEmpty else { throw StudioError.malformedLLMResponse }
        return notes.sorted { $0.startBeat < $1.startBeat }
    }

    private func prompt(part: MusicalPart, request: GenerationRequest, bpm: Double) -> String {
        let guidance: String
        switch part {
        case .drums:
            guidance = "Use General MIDI drum pitches: kick 36, snare 38, closed hat 42, open hat 46."
        case .bass:
            guidance = "Use pitches 28 through 52 and make a coherent bass line."
        case .chords:
            guidance = "Use grouped triads or seventh chords between pitches 48 and 76."
        case .melody:
            guidance = "Use a memorable monophonic melody mainly between pitches 60 and 84."
        case .fullArrangement:
            guidance = "Generate one coherent musical part."
        }

        return """
        Compose a \(request.bars)-bar \(part.title.lowercased()) MIDI loop at \(bpm) BPM in \(request.key).
        Creative direction: \(request.prompt)
        \(guidance)
        The timeline is \(request.bars * 4) beats long and beat zero is the beginning.
        Write a COMPLETE musical pattern for EVERY bar, with at least 8 notes and at most 64 notes.
        Use the tonic key throughout so drums, bass, chords, and melody can be layered together.
        Include notes in the last bar. Do not return a single example note or a partial pattern.
        Use a 0.25-beat grid. Velocity ranges from 0.1 to 1.0.
        Return a JSON object with a notes array; each note has pitch, velocity, startBeat, durationBeats.
        Keep all notes inside the timeline. Include no prose.
        """
    }

    private func localURL(_ endpoint: String, path: String) throws -> URL {
        guard let url = URL(string: endpoint), url.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host ?? "") else {
            throw MessageError("Use a local Ollama address such as http://127.0.0.1:11434.")
        }
        return url.appendingPathComponent(path)
    }
}

enum LoopNotes {
    static func expand(_ notes: [MIDINote], motifBeats: Double, totalBeats: Double,
                       part: MusicalPart) throws -> [MIDINote] {
        let valid = notes.filter {
            $0.startBeat.isFinite && $0.durationBeats.isFinite && $0.velocity.isFinite &&
            (0..<128).contains($0.pitch) && $0.startBeat >= 0 && $0.startBeat < motifBeats && $0.durationBeats > 0
        }
        let minimum = part == .chords ? 6 : 8
        guard valid.count >= minimum,
              (valid.map(\.startBeat).max() ?? 0) >= max(0, motifBeats - 4) else {
            throw MessageError("The local model returned an incomplete loop. Try again, or choose Built-in composer.")
        }
        var result: [MIDINote] = []
        for offset in stride(from: 0.0, to: totalBeats, by: motifBeats) {
            for note in valid {
                let start = offset + (note.startBeat * 4).rounded() / 4
                guard start < totalBeats else { continue }
                result.append(MIDINote(pitch: note.pitch, velocity: max(0.05, min(1, note.velocity)),
                    startBeat: start, durationBeats: min(note.durationBeats, motifBeats - note.startBeat, totalBeats - start)))
            }
        }
        return result.sorted { $0.startBeat < $1.startBeat }
    }
}

enum RuleBasedComposer {
    static func compose(part: MusicalPart, bars: Int, key: String, prompt: String) -> [MIDINote] {
        let root = rootPitch(for: key)
        let minor = key.lowercased().contains("minor")
        let scale = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let progression = minor ? [0, 5, 2, 6] : [0, 4, 5, 3]

        switch part {
        case .drums:
            return drums(bars: bars, prompt: prompt)
        case .bass:
            return bass(bars: bars, root: root - 24, scale: scale, progression: progression)
        case .chords:
            return chords(bars: bars, root: root - 12, scale: scale, progression: progression)
        case .melody, .fullArrangement:
            return melody(bars: bars, root: root, scale: scale, seed: stableHash(prompt))
        }
    }

    private static func rootPitch(for key: String) -> Int {
        let names = ["C": 60, "C#": 61, "DB": 61, "D": 62, "D#": 63, "EB": 63,
                     "E": 64, "F": 65, "F#": 66, "GB": 66, "G": 67, "G#": 68,
                     "AB": 68, "A": 69, "A#": 70, "BB": 70, "B": 71]
        let token = key.uppercased().split(separator: " ").first.map(String.init) ?? "C"
        return names[token] ?? 60
    }

    private static func drums(bars: Int, prompt: String) -> [MIDINote] {
        var notes: [MIDINote] = []
        let energetic = prompt.lowercased().contains("energetic") || prompt.lowercased().contains("house")
        for bar in 0..<bars {
            let base = Double(bar * 4)
            for beat in 0..<4 {
                notes.append(MIDINote(pitch: 36, velocity: beat == 0 ? 1 : 0.82, startBeat: base + Double(beat), durationBeats: 0.35))
                if beat == 1 || beat == 3 {
                    notes.append(MIDINote(pitch: 38, velocity: 0.86, startBeat: base + Double(beat), durationBeats: 0.25))
                }
            }
            for step in 0..<8 {
                notes.append(MIDINote(pitch: step == 7 && energetic ? 46 : 42, velocity: step.isMultiple(of: 2) ? 0.58 : 0.42, startBeat: base + Double(step) * 0.5, durationBeats: 0.18))
            }
        }
        return notes
    }

    private static func bass(bars: Int, root: Int, scale: [Int], progression: [Int]) -> [MIDINote] {
        var notes: [MIDINote] = []
        for bar in 0..<bars {
            let degree = progression[bar % progression.count]
            let pitch = root + scale[degree % scale.count]
            for beat in 0..<4 {
                notes.append(MIDINote(pitch: pitch + (beat == 3 ? 7 : 0), velocity: beat == 0 ? 0.9 : 0.72, startBeat: Double(bar * 4 + beat), durationBeats: 0.8))
            }
        }
        return notes
    }

    private static func chords(bars: Int, root: Int, scale: [Int], progression: [Int]) -> [MIDINote] {
        var notes: [MIDINote] = []
        for bar in 0..<bars {
            let degree = progression[bar % progression.count]
            let chord = [degree, degree + 2, degree + 4].map { root + scale[$0 % scale.count] + ($0 >= scale.count ? 12 : 0) }
            for pitch in chord {
                notes.append(MIDINote(pitch: pitch, velocity: 0.62, startBeat: Double(bar * 4), durationBeats: 3.8))
            }
        }
        return notes
    }

    private static func melody(bars: Int, root: Int, scale: [Int], seed: UInt64) -> [MIDINote] {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }

        var notes: [MIDINote] = []
        var previousDegree = 0
        for step in 0..<(bars * 8) {
            if next() % 7 == 0 { continue }
            let movement = Int(next() % 5) - 2
            previousDegree = max(0, min(13, previousDegree + movement))
            let pitch = root + scale[previousDegree % scale.count] + (previousDegree / scale.count) * 12
            notes.append(MIDINote(
                pitch: pitch,
                velocity: 0.55 + Double(next() % 35) / 100,
                startBeat: Double(step) * 0.5,
                durationBeats: next().isMultiple(of: 4) ? 0.9 : 0.42
            ))
        }
        return notes
    }

    private static func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
