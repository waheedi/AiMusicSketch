import Foundation

struct ClipMove: Equatable {
    let anchorID: UUID
    let ids: Set<UUID>
    let beatDelta: Double
    let trackDelta: Int
    let verticalOffsets: [UUID: Double]
}

enum ClipEditing {
    /// Outward edges add silence; inward edges consume padding, then trim audio.
    static func resize(_ clip: ClipModel, leftEdge: Bool, to beat: Double, bpm: Double, minimumBeats: Double = 0.0625) -> ClipModel {
        guard beat.isFinite, bpm.isFinite, bpm > 0 else { return clip }
        var result = clip
        let secondsPerBeat = 60 / bpm
        let phase = clip.playbackOffsetSeconds ?? 0
        let leading = clip.leadingSilenceSeconds ?? 0
        let trailing = clip.trailingSilenceSeconds ?? 0
        let minimum = min(minimumBeats, clip.durationBeats)
        if leftEdge {
            let start = max(0, min(clip.endBeat - minimum, beat))
            guard start != clip.startBeat else { return clip }
            let delta = (start - clip.startBeat) * secondsPerBeat
            let elapsed = phase + max(0, delta - leading)
            let region = clip.sourceRegionSeconds
            result.playbackOffsetSeconds = clip.loopEnabled
                ? (elapsed.truncatingRemainder(dividingBy: region) + region).truncatingRemainder(dividingBy: region)
                : max(0, elapsed)
            result.startBeat = start
            result.durationBeats = clip.endBeat - start
            result.leadingSilenceSeconds = max(0, leading - delta)
            result.trailingSilenceSeconds = min(trailing, result.durationBeats * secondsPerBeat)
        } else {
            let end = max(clip.startBeat + minimum, min(99_999, beat))
            guard end != clip.endBeat else { return clip }
            result.durationBeats = end - clip.startBeat
            result.trailingSilenceSeconds = max(0, trailing + (end - clip.endBeat) * secondsPerBeat)
            result.leadingSilenceSeconds = min(leading, result.durationBeats * secondsPerBeat)
        }
        if result.leadingSilenceSeconds == 0 { result.leadingSilenceSeconds = nil }
        if result.trailingSilenceSeconds == 0 { result.trailingSilenceSeconds = nil }
        return result
    }

    static func split(_ clip: ClipModel, at beat: Double, bpm: Double) throws -> (ClipModel, ClipModel) {
        guard beat > clip.startBeat, beat < clip.endBeat else {
            throw MessageError("Place the playhead inside the clip first.")
        }
        let left = resize(clip, leftEdge: false, to: beat, bpm: bpm, minimumBeats: 0)
        var right = resize(clip, leftEdge: true, to: beat, bpm: bpm, minimumBeats: 0)
        right.id = UUID()
        right.name += " 2"
        return (left, right)
    }

    static func trim(_ clip: ClipModel, from start: Double, to end: Double, bpm: Double) throws -> ClipModel {
        guard start.isFinite, end.isFinite, start >= clip.startBeat,
              end <= clip.endBeat + 0.0001, end - start >= 0.0625 else {
            throw MessageError("The trim range must be inside the clip and have a positive length.")
        }
        return resize(resize(clip, leftEdge: true, to: start, bpm: bpm), leftEdge: false, to: end, bpm: bpm)
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
        if (clip.leadingSilenceSeconds ?? 0) > 0 || (clip.trailingSilenceSeconds ?? 0) > 0 { return true }
        if !clip.loopEnabled && (clip.playbackOffsetSeconds ?? 0) + clip.durationBeats * 60 / bpm > clip.sourceRegionSeconds + 0.000001 { return true }
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
