import Foundation

/// Output placement is independent of the reference/input selection and the
/// existing timeline length. No project mutation occurs until audio is ready.
struct GenerationOutputRange {
    static let maximumSeconds = 300.0
    let startBeat: Double
    let endBeat: Double
    let seconds: Double

    static func start(project: StudioProject, trackID: UUID, request: GenerationRequest, playhead: Double) -> Double {
        if request.input == .trackAudio {
            return project.tracks.first { $0.id == trackID }?.clips.map(\.endBeat).max() ?? 0
        }
        return max(0, playhead)
    }

    init(project: StudioProject, trackID: UUID, request: GenerationRequest, playhead: Double) throws {
        guard project.tracks.contains(where: { $0.id == trackID }) else { throw StudioError.noTrackSelected }
        let start = Self.start(project: project, trackID: trackID, request: request, playhead: playhead)
        let end = request.outputEndBeat ?? (start + Double(request.bars) * 4)
        guard project.bpm.isFinite, project.bpm > 0, start.isFinite, start >= 0,
              end.isFinite, end > start, end < 99_996 else {
            throw MessageError("Generate through beat must be after the new audio's start beat.")
        }
        let duration = (end - start) * 60 / project.bpm
        guard duration >= 1, duration <= Self.maximumSeconds else {
            throw MessageError("Choose 1–300 seconds of new audio. The end beat can be beyond the track or timeline.")
        }
        startBeat = start
        endBeat = end
        seconds = duration
    }
}
