import Foundation

/// A frozen, single-track render. No other track can enter the model's audio input.
struct TrackAudioReference {
    static let maximumSeconds = 12.0
    let project: StudioProject
    let trackID: UUID
    let trackName: String
    let startBeat: Double
    let endBeat: Double
    var seconds: Double { (endBeat - startBeat) * 60 / project.bpm }

    static func defaultRange(track: TrackModel, bpm: Double, clipID: UUID? = nil) -> ClosedRange<Double>? {
        let clips = clipID.map { id in track.clips.filter { $0.id == id } } ?? track.clips
        guard let start = clips.map(\.startBeat).min(), let end = clips.map(\.endBeat).max(), end > start else { return nil }
        return max(start, end - 8 * bpm / 60)...end
    }

    init(project: StudioProject, trackID: UUID, start: Double, end: Double) throws {
        guard let original = project.tracks.first(where: { $0.id == trackID }) else { throw StudioError.noTrackSelected }
        guard start.isFinite, end.isFinite, start >= 0, project.bpm.isFinite, project.bpm > 0,
              (0.25...Self.maximumSeconds + 0.000001).contains((end - start) * 60 / project.bpm) else {
            throw MessageError("Choose 0.25–12 seconds of this track as the AI reference.")
        }
        let cropped = original.clips.compactMap { clip -> ClipModel? in
            let lower = max(start, clip.startBeat), upper = min(end, clip.endBeat)
            guard upper > lower else { return nil }
            var result = ClipEditing.resize(ClipEditing.resize(clip, leftEdge: true, to: lower, bpm: project.bpm, minimumBeats: 0),
                                            leftEdge: false, to: upper, bpm: project.bpm, minimumBeats: 0)
            result.startBeat = lower - start
            result.durationBeats = upper - lower
            return result
        }
        guard !cropped.isEmpty else { throw MessageError("There are no clips in this track's chosen reference range.") }
        var track = original
        track.clips = cropped
        // Include the instrument and effects, even when the user muted the track.
        track.isMuted = false
        track.isSolo = false
        track.volume = 1
        track.pan = 0
        // Rebase automation time so the reference hears the same effects as the
        // original timeline range, rather than restarting its envelopes at zero.
        let lowerSeconds = start * 60 / project.bpm
        let upperSeconds = end * 60 / project.bpm
        track.automation = original.automation?.map { lane in
            var result = lane
            result.points = [AutomationPoint(seconds: 0, value: lane.value(at: lowerSeconds))]
                + lane.points.filter { $0.seconds > lowerSeconds && $0.seconds < upperSeconds }.map {
                    AutomationPoint(seconds: $0.seconds - lowerSeconds, value: $0.value)
                }
                + [AutomationPoint(seconds: upperSeconds - lowerSeconds, value: lane.value(at: upperSeconds))]
            return result
        }
        var snapshot = project
        snapshot.tracks = [track]
        snapshot.lengthBeats = end - start
        self.project = snapshot
        self.trackID = trackID
        self.trackName = original.name
        startBeat = start
        endBeat = end
    }

    func render(to url: URL) throws -> GenerationReference {
        try OfflineMixRenderer.render(project: project, to: url)
        return GenerationReference(trackID: trackID, trackName: trackName,
                                   startBeat: startBeat, endBeat: endBeat, assetPath: url.path)
    }
}
