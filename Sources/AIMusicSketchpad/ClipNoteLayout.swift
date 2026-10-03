import Foundation

struct DisplayNote: Equatable {
    var pitch: Int
    var velocity: Double
    var startSeconds: Double
    var durationSeconds: Double
}

enum ClipNoteLayout {
    /// Project beats describe the clip's placement, while source beats retain
    /// the tempo at which MIDI was rendered. Use the same source slices as audio.
    static func notes(for clip: ClipModel, bpm: Double) -> [DisplayNote] {
        guard bpm.isFinite, bpm > 0, let notes = clip.midiNotes else { return [] }
        let sourceBPM = clip.midiSourceBPM ?? bpm
        guard sourceBPM.isFinite, sourceBPM > 0 else { return [] }
        let sourceNotes = notes.filter {
            (0..<128).contains($0.pitch) && $0.startBeat.isFinite && $0.startBeat >= 0
                && $0.durationBeats.isFinite && $0.durationBeats > 0 && $0.velocity.isFinite && $0.velocity > 0
        }
        let origin = clip.startBeat * 60 / bpm
        var result: [DisplayNote] = []
        for segment in scheduledSegments(for: clip, bpm: bpm, fromBeat: clip.startBeat) {
            let sourceStart = segment.sourceOffsetSeconds
            let sourceEnd = sourceStart + segment.durationSeconds
            for note in sourceNotes {
                let start = max(sourceStart, note.startBeat * 60 / sourceBPM)
                let end = min(sourceEnd, (note.startBeat + note.durationBeats) * 60 / sourceBPM)
                guard end > start + 0.000001 else { continue }
                result.append(DisplayNote(pitch: note.pitch, velocity: max(0, min(1, note.velocity)),
                    startSeconds: max(0, segment.timelineStartSeconds - origin + start - sourceStart),
                    durationSeconds: end - start))
            }
        }
        return result.sorted { $0.startSeconds == $1.startSeconds ? $0.pitch < $1.pitch : $0.startSeconds < $1.startSeconds }
    }

    static func pitchRange(for clip: ClipModel) -> ClosedRange<Int> {
        let pitches = (clip.midiNotes ?? []).map(\.pitch).filter { (0..<128).contains($0) }
        let low = (pitches.min() ?? 60) / 12 * 12
        let high = min(127, ((pitches.max() ?? 71) / 12 + 1) * 12 - 1)
        return low...max(low + 1, high)
    }

    /// Consolidation creates a new source WAV; its note metadata must be rebased
    /// to that same source, including partial notes and wrapped repetitions.
    static func rebasedNotes(for clip: ClipModel, bpm: Double) -> [MIDINote]? {
        guard clip.midiNotes != nil else { return nil }
        return notes(for: clip, bpm: bpm).map {
            MIDINote(pitch: $0.pitch, velocity: $0.velocity, startBeat: $0.startSeconds * bpm / 60,
                     durationBeats: $0.durationSeconds * bpm / 60)
        }
    }
}
