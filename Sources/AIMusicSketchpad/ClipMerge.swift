import Foundation

enum ClipMerge {
    // Keep the rendered sound unchanged. Offer note editing only when one
    // instrument/preset can faithfully represent every source clip.
    static func editableConfiguration(for clips: [ClipModel]) -> InstrumentConfiguration? {
        guard let first = clips.first else { return nil }
        let configuration = first.instrumentAddOn ?? InstrumentConfiguration(builtIn: first.instrument ?? .piano)
        guard configuration.mode != .audioUnit, clips.allSatisfy({
            $0.notesEditable == true && $0.midiNotes != nil &&
            ($0.instrumentAddOn ?? InstrumentConfiguration(builtIn: $0.instrument ?? .piano)) == configuration
        }) else { return nil }
        return configuration
    }

    static func notes(for clips: [ClipModel], startingAt start: Double, bpm: Double) -> [MIDINote] {
        var result: [MIDINote] = []
        for clip in clips {
            for note in ClipNoteLayout.notes(for: clip, bpm: bpm) {
                let onset = clip.startBeat - start + note.startSeconds * bpm / 60
                result.append(MIDINote(pitch: note.pitch, velocity: note.velocity, startBeat: onset,
                                       durationBeats: note.durationSeconds * bpm / 60))
            }
        }
        return result.sorted { $0.startBeat == $1.startBeat ? $0.pitch < $1.pitch : $0.startBeat < $1.startBeat }
    }
}
