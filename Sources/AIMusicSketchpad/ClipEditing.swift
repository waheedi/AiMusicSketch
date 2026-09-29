import Foundation

enum ClipEditing {
    static func split(_ clip: ClipModel, at beat: Double, bpm: Double) throws -> (ClipModel, ClipModel) {
        guard beat > clip.startBeat, beat < clip.endBeat else {
            throw MessageError("Place the playhead inside the clip first.")
        }
        var left = clip
        var right = clip
        left.durationBeats = beat - clip.startBeat
        right.id = UUID()
        right.name += " 2"
        right.startBeat = beat
        right.durationBeats = clip.endBeat - beat
        let elapsed = (clip.playbackOffsetSeconds ?? 0) + left.durationBeats * 60 / bpm
        right.playbackOffsetSeconds = clip.loopEnabled
            ? elapsed.truncatingRemainder(dividingBy: clip.sourceRegionSeconds) : elapsed
        return (left, right)
    }

    static func trim(_ clip: ClipModel, from start: Double, to end: Double, bpm: Double) throws -> ClipModel {
        guard start.isFinite, end.isFinite, start >= clip.startBeat,
              end <= clip.endBeat + 0.0001, end - start >= 0.0625 else {
            throw MessageError("The trim range must be inside the clip and have a positive length.")
        }
        var trimmed = clip
        let elapsed = (clip.playbackOffsetSeconds ?? 0) + (start - clip.startBeat) * 60 / bpm
        trimmed.playbackOffsetSeconds = clip.loopEnabled
            ? elapsed.truncatingRemainder(dividingBy: clip.sourceRegionSeconds) : elapsed
        trimmed.startBeat = start
        trimmed.durationBeats = end - start
        return trimmed
    }

    static func loop(_ clip: ClipModel, times: Int, bpm: Double) -> ClipModel {
        var result = clip
        let duration = clip.durationBeats * 60 / bpm
        let phase = clip.playbackOffsetSeconds ?? 0
        if !result.loopEnabled || phase + duration <= clip.sourceRegionSeconds + 0.000001 {
            // Repeat precisely the audible trimmed region, not the rest of its source file.
            result.sourceOffsetSeconds += result.playbackOffsetSeconds ?? 0
            result.playbackOffsetSeconds = 0
            result.loopLengthSeconds = min(result.sourceRegionSeconds, clip.durationBeats * 60 / bpm)
        }
        result.loopEnabled = true
        result.durationBeats *= Double(max(1, times))
        return result
    }

    static func needsLoopRender(_ clip: ClipModel, bpm: Double) -> Bool {
        guard clip.loopEnabled else { return false }
        let duration = clip.durationBeats * 60 / bpm
        let region = clip.sourceRegionSeconds
        let phase = clip.playbackOffsetSeconds ?? 0
        if phase + duration <= region + 0.000001 { return false }
        let remainder = duration.truncatingRemainder(dividingBy: region)
        // A selection crossing a wrap with a partial cycle must be consolidated
        // so repetition returns to the selection's start, not the original cycle.
        return remainder > 0.000001 && region - remainder > 0.000001
    }
}
