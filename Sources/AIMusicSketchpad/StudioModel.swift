import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class StudioModel: ObservableObject {
    @Published var project = StudioProject() {
        didSet {
            audio.updateMix(project: project)
            if !suppressHistory && editDepth == 0 {
                history.record(before: oldValue, after: project, title: "Edit")
            }
        }
    }
    @Published private(set) var history = ProjectHistory()
    private var suppressHistory = false
    private var suppressInstrumentStore = false
    private var editDepth = 0
    private var editBefore: StudioProject?
    private var editTitle = "Edit"
    @Published var selectedTrackID: UUID? {
        didSet {
            guard oldValue != selectedTrackID else { return }
            if !suppressInstrumentStore { storeInstrument(on: oldValue) }
            restoreTrackInstrument()
        }
    }
    @Published var selectedClipID: UUID?
    @Published var status = "Ready"
    @Published var alertMessage: String?
    @Published var isBusy = false
    @Published var showGenerateSheet = false
    @Published var showRecordingPanel = false
    @Published var trimClipID: UUID?
    @Published var noteEditClipID: UUID?
    @Published var generationRequest = GenerationRequest()
    @Published var generationTrackID: UUID?
    @Published var visibleAutomation: [UUID: AutomationParameter] = [:]
    @Published var snapEnabled = true
    @Published var draggingClipID: UUID?
    private(set) var copiedClip: ClipModel?
    @Published var availableModels: [String] = []
    let audio = AudioEngineController()
    let recording = RecordingController()
    private let composer = OllamaComposer()
    private let audioGenerator = TextAudioGenerator()
    private var subscriptions = Set<AnyCancellable>()
    private var generationTask: Task<Void, Never>?
    private var recordingTrackID: UUID?
    private var recordingStartBeat = 0.0
    private var recordingBPM = 120.0
    var editingLocked: Bool { isBusy || recording.isRecording || recording.isLoadingInstrument }

    init() {
        selectedTrackID = project.tracks.first?.id
        // Forward nested observable objects so transport and recording updates redraw the UI.
        audio.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        recording.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.$playheadBeat.sink { [weak self] beat in
            guard let self, self.recording.isRecording, beat + 4 > self.project.lengthBeats else { return }
            self.suppressHistory = true
            self.project.lengthBeats = ceil((beat + 16) / 4) * 4
            self.suppressHistory = false
        }.store(in: &subscriptions)
        recording.onFailure = { [weak self] message in
            self?.stop()
            self?.alertMessage = message
        }
    }

    var selectedTrackIndex: Int? { project.tracks.firstIndex { $0.id == selectedTrackID } }
    var canUndo: Bool { !editingLocked && editDepth == 0 && history.canUndo }
    var canRedo: Bool { !editingLocked && editDepth == 0 && history.canRedo }

    func beginEdit(_ title: String) {
        if editDepth == 0 { editBefore = project; editTitle = title }
        editDepth += 1
    }
    func endEdit() {
        guard editDepth > 0 else { return }
        editDepth -= 1
        if editDepth == 0, let before = editBefore {
            history.record(before: before, after: project, title: editTitle)
            editBefore = nil
        }
    }
    func undo() {
        guard canUndo, editDepth == 0, let restored = history.undo() else { return }
        restoreHistory(restored, status: "Undo")
    }
    func redo() {
        guard canRedo, editDepth == 0, let restored = history.redo() else { return }
        restoreHistory(restored, status: "Redo")
    }
    private func restoreHistory(_ restored: StudioProject, status: String) {
        suppressInstrumentStore = true
        defer { suppressInstrumentStore = false }
        audio.stop()
        recording.panic()
        suppressHistory = true
        project = restored
        suppressHistory = false
        if selectedTrackIndex == nil { selectedTrackID = project.tracks.first?.id }
        restoreTrackInstrument()
        if location(selectedClipID) == nil { selectedClipID = nil }
        audio.playheadBeat = min(audio.playheadBeat, project.lengthBeats)
        self.status = status
    }
    func undoCommand() {
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { undo() }
    }
    func redoCommand() {
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { redo() }
    }
    var canUndoCommand: Bool { (NSApp?.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canUndo ?? canUndo }
    var canRedoCommand: Bool { (NSApp?.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo ?? canRedo }
    var generationTrack: TrackModel? { project.tracks.first { $0.id == (generationTrackID ?? selectedTrackID) } }

    func beginGeneration(trackID: UUID? = nil, clipID: UUID? = nil, useTrack: Bool? = nil) {
        guard !editingLocked, let id = trackID ?? selectedTrackID,
              let track = project.tracks.first(where: { $0.id == id }) else { return }
        generationTrackID = id
        selectedTrackID = id
        generationRequest = track.generationSettings ?? GenerationRequest()
        if useTrack == true || (track.generationSettings == nil && !track.clips.isEmpty) {
            generationRequest.input = .trackAudio
            generationRequest.engine = .audio
            generationRequest.prompt = "Develop this musical idea with a tasteful improvisation; keep its instrument and character"
        }
        if track.clips.isEmpty { generationRequest.input = .textOnly }
        let outputStart = GenerationOutputRange.start(project: project, trackID: id, request: generationRequest,
                                                     playhead: snappedBeat(audio.currentBeat))
        if let end = generationRequest.outputEndBeat, end <= outputStart { generationRequest.outputEndBeat = nil }
        if track.generationSettings == nil || useTrack == true || clipID != nil {
            resetReferenceRange(clipID: clipID)
        }
        showGenerateSheet = true
    }

    func resetReferenceRange(clipID: UUID? = nil) {
        guard let track = generationTrack,
              let range = TrackAudioReference.defaultRange(track: track, bpm: project.bpm, clipID: clipID) else { return }
        generationRequest.referenceStartBeat = range.lowerBound
        generationRequest.referenceEndBeat = range.upperBound
    }

    func rememberGenerationSettings() {
        guard let index = project.tracks.firstIndex(where: { $0.id == generationTrackID }) else { return }
        project.tracks[index].generationSettings = generationRequest
    }

    func setTempo(_ value: Double) {
        guard !editingLocked, !audio.isPlaying, value.isFinite, (40...240).contains(value) else { return }
        let old = project.bpm
        guard value != old else { return }
        beginEdit("Change Tempo"); defer { endEdit() }
        // Only explicit tempo edits rescale durations, never opening a saved project.
        var updated = project
        updated.bpm = value
        for t in updated.tracks.indices {
            for c in updated.tracks[t].clips.indices {
                if updated.tracks[t].clips[c].midiNotes != nil && updated.tracks[t].clips[c].midiSourceBPM == nil {
                    updated.tracks[t].clips[c].midiSourceBPM = old
                }
                updated.tracks[t].clips[c].durationBeats *= value / old
            }
        }
        updated.refreshLength()
        project = updated
    }
    var selectedClipLocation: (track: Int, clip: Int)? { location(selectedClipID) }
    func location(_ id: UUID?) -> (track: Int, clip: Int)? {
        guard let id else { return nil }
        for index in project.tracks.indices {
            if let clip = project.tracks[index].clips.firstIndex(where: { $0.id == id }) { return (index, clip) }
        }
        return nil
    }
    func clip(_ id: UUID?) -> ClipModel? {
        guard let p = location(id) else { return nil }
        return project.tracks[p.track].clips[p.clip]
    }

    func newProject() {
        guard !editingLocked else { return }
        suppressInstrumentStore = true
        defer { suppressInstrumentStore = false }
        audio.stop(resetPlayhead: true)
        suppressHistory = true
        project = StudioProject()
        suppressHistory = false
        history = ProjectHistory()
        editDepth = 0; editBefore = nil
        selectedTrackID = project.tracks.first?.id
        selectedClipID = nil
        status = "New project"
    }

    func addTrack() {
        guard !editingLocked else { return }
        guard project.tracks.count < StudioProject.maximumTrackCount else { present(StudioError.trackLimit); return }
        beginEdit("Add Track"); defer { endEdit() }
        let track = TrackModel.new(index: project.tracks.count)
        project.tracks.append(track)
        selectedTrackID = track.id
        selectedClipID = nil
    }

    func deleteSelectedTrack() {
        guard !editingLocked, let index = selectedTrackIndex else { return }
        beginEdit("Delete Track"); defer { endEdit() }
        audio.stop()
        project.tracks.remove(at: index)
        if project.tracks.isEmpty { project.tracks.append(.new(index: 0)) }
        selectedTrackID = project.tracks[min(index, project.tracks.count - 1)].id
        selectedClipID = nil
        project.refreshLength()
    }

    func selectTrack(_ id: UUID) {
        guard !recording.isRecording, let track = project.tracks.first(where: { $0.id == id }) else { return }
        selectedTrackID = id
        NSApp?.keyWindow?.makeFirstResponder(nil)
        if !track.clips.contains(where: { $0.id == selectedClipID }) { selectedClipID = nil }
    }

    func selectClip(trackID: UUID, clipID: UUID) {
        guard !recording.isRecording else { return }
        selectedTrackID = trackID
        selectedClipID = clipID
        NSApp?.keyWindow?.makeFirstResponder(nil)
    }

    func importAudio() {
        guard !editingLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let target = selectedTrackID else { return }
        let urls = panel.urls
        let start = snappedBeat(audio.currentBeat)
        audio.stop()
        isBusy = true
        status = "Importing audio…"
        Task {
            defer { isBusy = false }
            do {
                let sampleRate = project.sampleRate
                let clips = try await Task.detached(priority: .userInitiated) {
                    try urls.map { url in
                        let asset = try AssetManager.shared.importAudio(from: url, sampleRate: sampleRate)
                        return (url.deletingPathExtension().lastPathComponent, asset)
                    }
                }.value
                guard var index = project.tracks.firstIndex(where: { $0.id == target }) else { return }
                beginEdit("Import Audio"); defer { endEdit() }
                for (n, entry) in clips.enumerated() {
                    if n > 0 && project.tracks.count < StudioProject.maximumTrackCount {
                        project.tracks.append(.new(index: project.tracks.count))
                        index = project.tracks.count - 1
                    }
                    let clip = ClipModel(name: entry.0, assetPath: entry.1.url.path, startBeat: start,
                        durationBeats: entry.1.duration * project.bpm / 60, sourceDurationSeconds: entry.1.duration)
                    project.tracks[index].clips.append(clip)
                    selectedTrackID = project.tracks[index].id
                    selectedClipID = clip.id
                }
                project.refreshLength()
                status = "Imported \(clips.count) audio file(s)"
            } catch { present(error) }
        }
    }

    func moveClip(id: UUID, on trackID: UUID, to beat: Double) {
        guard !editingLocked, beat.isFinite, let p = location(id),
              let destination = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        beginEdit("Move Clip"); defer { endEdit() }
        audio.stop()
        var moved = project.tracks[p.track].clips.remove(at: p.clip)
        moved.startBeat = snappedBeat(max(0, beat))
        project.tracks[destination].clips.append(moved)
        selectedTrackID = trackID
        selectedClipID = id
        project.refreshLength()
    }

    func trackHeight(_ id: UUID) -> Double { visibleAutomation[id] == nil ? 76 : 176 }

    func resizeClip(_ id: UUID, leftEdge: Bool, to beat: Double) {
        guard !editingLocked, let p = location(id) else { return }
        let original = project.tracks[p.track].clips[p.clip]
        let resized = ClipEditing.resize(original, leftEdge: leftEdge, to: snappedBeat(beat), bpm: project.bpm)
        guard resized != original else { return }
        beginEdit("Resize Clip"); defer { endEdit() }
        audio.stop()
        project.tracks[p.track].clips[p.clip] = resized
        project.refreshLength()
        status = resized.loopEnabled ? "Loop resized" : "Clip resized • source audio preserved"
    }

    func dragDestination(trackID: UUID, deltaY: Double) -> UUID {
        var top = 0.0
        var origin = 0.0
        for track in project.tracks {
            if track.id == trackID { origin = top + 38; break }
            top += trackHeight(track.id)
        }
        let destinationY = max(0, origin + deltaY)
        top = 0
        for track in project.tracks {
            top += trackHeight(track.id)
            if destinationY < top { return track.id }
        }
        return project.tracks.last?.id ?? trackID
    }

    func copyClip(_ id: UUID) {
        guard let clip = clip(id) else { return }
        copiedClip = clip
        status = "Copied \(clip.name) • click a track/time, then paste"
    }
    func pasteClip() {
        guard !editingLocked, let clip = copiedClip, let track = selectedTrackIndex else { return }
        audio.stop()
        insertCopy(clip, track: track, beat: snappedBeat(audio.playheadBeat))
    }
    func duplicateClip(_ id: UUID) {
        guard !editingLocked, let p = location(id) else { return }
        audio.stop()
        let clip = project.tracks[p.track].clips[p.clip]
        insertCopy(clip, track: p.track, beat: clip.endBeat)
    }
    private func insertCopy(_ original: ClipModel, track: Int, beat: Double) {
        beginEdit("Copy Clip"); defer { endEdit() }
        var copy = original
        copy.id = UUID()
        copy.name += " copy"
        copy.startBeat = max(0, beat)
        project.tracks[track].clips.append(copy)
        selectedTrackID = project.tracks[track].id
        selectedClipID = copy.id
        project.refreshLength()
        status = "Pasted clip • source audio preserved"
    }
    func copyCommand() {
        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
        else if let selectedClipID { copyClip(selectedClipID) }
    }
    func pasteCommand() {
        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        else { pasteClip() }
    }

    func setAutomationPoint(trackID: UUID, parameter: AutomationParameter, id: UUID = UUID(), seconds: Double, value: Double) {
        guard !editingLocked, seconds.isFinite, value.isFinite,
              let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var lanes = project.tracks[index].automation ?? []
        let laneIndex = lanes.firstIndex { $0.parameter == parameter } ?? lanes.count
        if laneIndex == lanes.count { lanes.append(AutomationLane(parameter: parameter)) }
        let time = max(0, min(project.lengthBeats * 60 / project.bpm, (seconds * 20).rounded() / 20))
        lanes[laneIndex].points.removeAll { $0.id == id || abs($0.seconds - time) < 0.001 }
        lanes[laneIndex].points.append(AutomationPoint(id: id, seconds: time, value: max(-1, min(1, value))))
        lanes[laneIndex].points.sort { $0.seconds < $1.seconds }
        project.tracks[index].automation = lanes
    }
    func removeAutomationPoint(trackID: UUID, parameter: AutomationParameter, id: UUID) {
        guard !editingLocked, let t = project.tracks.firstIndex(where: { $0.id == trackID }),
              let lane = project.tracks[t].automation?.firstIndex(where: { $0.parameter == parameter }) else { return }
        project.tracks[t].automation?[lane].points.removeAll { $0.id == id }
    }
    func clearAutomation(trackID: UUID, parameter: AutomationParameter) {
        guard !editingLocked, let t = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        project.tracks[t].automation?.removeAll { $0.parameter == parameter }
    }

    func loopClip(_ id: UUID, times: Int = 2) {
        guard !editingLocked, let p = location(id) else { return }
        audio.stop()
        let original = project.tracks[p.track].clips[p.clip]
        if ClipEditing.needsLoopRender(original, bpm: project.bpm) {
            var renderProject = StudioProject()
            renderProject.bpm = project.bpm
            renderProject.sampleRate = project.sampleRate
            renderProject.lengthBeats = original.durationBeats
            var region = original
            region.startBeat = 0
            var track = TrackModel.new(index: 0)
            track.volume = 1
            track.clips = [region]
            renderProject.tracks = [track]
            let snapshot = renderProject
            isBusy = true
            status = "Preparing trimmed loop…"
            Task {
                defer { isBusy = false }
                do {
                    let url = AssetManager.shared.newAssetURL(prefix: "Trimmed-loop")
                    try await Task.detached(priority: .userInitiated) {
                        try OfflineMixRenderer.render(project: snapshot, to: url)
                    }.value
                    guard let destination = location(id) else { return }
                    beginEdit("Loop Clip"); defer { endEdit() }
                    var rendered = original
                    rendered.assetPath = url.path
                    rendered.midiNotes = ClipNoteLayout.rebasedNotes(for: original, bpm: snapshot.bpm)
                    rendered.midiSourceBPM = original.midiNotes == nil ? nil : snapshot.bpm
                    rendered.sourceDurationSeconds = original.durationBeats * 60 / snapshot.bpm
                    rendered.sourceOffsetSeconds = 0
                    rendered.playbackOffsetSeconds = 0
                    rendered.loopLengthSeconds = nil
                    rendered.loopEnabled = false
                    project.tracks[destination.track].clips[destination.clip] = ClipEditing.loop(rendered, times: times, bpm: snapshot.bpm)
                    project.refreshLength()
                    status = "Trimmed region looped ×\(times)"
                } catch { present(error) }
            }
            return
        }
        beginEdit("Loop Clip"); defer { endEdit() }
        project.tracks[p.track].clips[p.clip] = ClipEditing.loop(project.tracks[p.track].clips[p.clip], times: times, bpm: project.bpm)
        project.refreshLength()
        status = "Loop length extended ×\(times)"
    }

    func stopLooping(_ id: UUID) {
        guard !editingLocked, let p = location(id) else { return }
        beginEdit("Stop Looping"); defer { endEdit() }
        audio.stop()
        var clip = project.tracks[p.track].clips[p.clip]
        clip.loopEnabled = false
        clip.durationBeats = min(clip.durationBeats, max(0.01, clip.sourceRegionSeconds - (clip.playbackOffsetSeconds ?? 0)) * project.bpm / 60)
        project.tracks[p.track].clips[p.clip] = clip
        project.refreshLength()
    }

    func trimClip(_ id: UUID, from start: Double, to end: Double) {
        guard !editingLocked, let p = location(id) else { return }
        do {
            let trimmed = try ClipEditing.trim(project.tracks[p.track].clips[p.clip], from: start, to: end, bpm: project.bpm)
            beginEdit("Trim Clip"); defer { endEdit() }
            audio.stop()
            project.tracks[p.track].clips[p.clip] = trimmed
            project.refreshLength()
            status = "Clip trimmed"
        } catch { present(error) }
    }

    func splitSelectedClip() {
        guard !editingLocked, let p = selectedClipLocation else { return }
        do {
            let pair = try ClipEditing.split(project.tracks[p.track].clips[p.clip], at: snappedBeat(audio.currentBeat), bpm: project.bpm)
            beginEdit("Split Clip"); defer { endEdit() }
            audio.stop()
            project.tracks[p.track].clips[p.clip] = pair.0
            project.tracks[p.track].clips.insert(pair.1, at: p.clip + 1)
            selectedClipID = pair.1.id
            status = "Clip split"
        } catch { present(error) }
    }

    func deleteSelectedClip() {
        guard !editingLocked, let p = selectedClipLocation else { return }
        beginEdit("Delete Clip"); defer { endEdit() }
        audio.stop()
        project.tracks[p.track].clips.remove(at: p.clip)
        selectedClipID = nil
        project.refreshLength()
    }

    func seek(to beat: Double) {
        guard !editingLocked, beat.isFinite else { return }
        let beat = min(project.lengthBeats, max(0, beat))
        do {
            if audio.isPlaying { try audio.play(project: project, fromBeat: beat) }
            else { audio.playheadBeat = beat }
        } catch { present(error) }
    }

    func togglePlayback() {
        if recording.isRecording { stop(); return }
        guard !isBusy else { return }
        do { try audio.toggle(project: project) } catch { present(error) }
    }

    func stop() {
        if recording.isRecording { finishRecording() }
        else { audio.stop(); status = "Stopped" }
    }

    func startRecording() {
        guard !editingLocked, let target = selectedTrackID else { return }
        isBusy = true
        showRecordingPanel = true
        audio.stop()
        recordingStartBeat = snappedBeat(audio.playheadBeat)
        recordingTrackID = target
        recordingBPM = project.bpm
        Task {
            defer { isBusy = false }
            do {
                try await recording.prepare(sampleRate: project.sampleRate)
                let anchor = try audio.play(project: project, fromBeat: recordingStartBeat, recording: true)
                try recording.begin(anchor: anchor, bpm: recordingBPM)
                status = "Recording to \(project.tracks.first(where: { $0.id == target })?.name ?? "track")"
            } catch {
                audio.stop()
                recording.cancelPreparation()
                present(error)
            }
        }
    }

    private func finishRecording() {
        audio.stop()
        do {
            let take = try recording.finish()
            let start = recordingStartBeat
            let target = recordingTrackID
            let bpm = recordingBPM
            let sampleRate = project.sampleRate
            isBusy = true
            status = "Saving take…"
            Task {
                defer { isBusy = false }
                do {
                    let asset = try await Task.detached(priority: .userInitiated) { () -> (URL, Double) in
                        if let raw = take.url {
                            let result = try AssetManager.shared.importAudio(from: raw, sampleRate: sampleRate)
                            return (result.url, result.duration)
                        }
                        let url = AssetManager.shared.newAssetURL(prefix: "Keyboard-take")
                        let duration = try MIDIRenderer.render(notes: take.notes, instrument: take.instrument,
                            bpm: bpm, durationBeats: take.durationBeats + 0.5, sampleRate: sampleRate, to: url)
                        return (url, duration)
                    }.value
                    guard let index = project.tracks.firstIndex(where: { $0.id == target }) else { return }
                    beginEdit("Record Track"); defer { endEdit() }
                    let clip = ClipModel(name: take.addOn.map { "\($0.name) take" } ?? (take.url == nil ? "\(take.instrument.rawValue) take" : "Audio take"),
                        assetPath: asset.0.path, startBeat: start,
                        durationBeats: take.addOn == nil ? asset.1 * bpm / 60 : min(take.durationBeats, asset.1 * bpm / 60),
                        sourceDurationSeconds: asset.1, midiNotes: take.notes.isEmpty ? nil : take.notes,
                        instrument: take.url == nil ? take.instrument : nil,
                        midiSourceBPM: take.notes.isEmpty ? nil : bpm, instrumentAddOn: take.addOn,
                        notesEditable: !take.notes.isEmpty && take.addOn?.mode != .audioUnit)
                    project.tracks[index].clips.append(clip)
                    selectedTrackID = target
                    selectedClipID = clip.id
                    project.refreshLength()
                    status = "Take saved to \(project.tracks[index].name)"
                } catch { present(error) }
            }
        } catch { present(error) }
    }

    func prepareKeyboard() {
        Task {
            do { try await recording.prepareKeyboard() }
            catch is CancellationError { }
            catch { recording.instrumentMessage = error.localizedDescription; present(error) }
        }
    }

    func editNotes(_ id: UUID) {
        guard !editingLocked, clip(id)?.notesEditable == true else { return }
        audio.stop(); recording.panic()
        noteEditClipID = id
    }

    func applyNotes(_ notes: [MIDINote], to id: UUID) async throws {
        guard !editingLocked, let original = clip(id), original.notesEditable == true else { return }
        let configuration = original.instrumentAddOn ?? InstrumentConfiguration(builtIn: original.instrument ?? .piano)
        let bpm = original.midiSourceBPM ?? project.bpm
        let beats = original.sourceDurationSeconds * bpm / 60
        guard notes.allSatisfy({ (0..<128).contains($0.pitch) && $0.startBeat.isFinite && $0.startBeat >= 0
            && $0.startBeat < beats && $0.durationBeats.isFinite && $0.durationBeats > 0
            && $0.velocity.isFinite && $0.velocity > 0 && $0.velocity <= 1 }) else {
            throw MessageError("A note has invalid pitch, timing or velocity.")
        }
        let rate = project.sampleRate
        isBusy = true; audio.stop(); status = "Updating note audio…"
        defer { isBusy = false }
        do {
            let url = AssetManager.shared.newAssetURL(prefix: "Edited-notes")
            _ = try await Task.detached(priority: .userInitiated) {
                try MIDIRenderer.render(notes: notes, configuration: configuration, bpm: bpm,
                    durationBeats: beats, sampleRate: rate, to: url, allowEmpty: true)
            }.value
            guard let p = location(id) else { return }
            beginEdit("Edit Notes"); defer { endEdit() }
            var updated = original
            updated.assetPath = url.path
            updated.midiNotes = notes.sorted { $0.startBeat < $1.startBeat }
            updated.midiSourceBPM = bpm
            project.tracks[p.track].clips[p.clip] = updated
            status = "Notes updated • Undo restores the previous take"
        } catch {
            status = "Notes unchanged"
            throw error
        }
    }

    private func storeInstrument(on id: UUID?) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        do {
            let config = try recording.snapshotConfiguration()
            if project.tracks[index].instrumentConfiguration == nil && config == InstrumentConfiguration() { return }
            if project.tracks[index].instrumentConfiguration != config {
                project.tracks[index].instrumentConfiguration = config
            }
        } catch { present(error) }
    }
    func instrumentChanged(reload: Bool = true) {
        if let index = selectedTrackIndex { project.tracks[index].instrumentConfiguration = recording.configuration }
        if reload { prepareKeyboard() } else { recording.applySynthSettings() }
    }
    private func restoreTrackInstrument() {
        recording.panic()
        let track = selectedTrackIndex.map { project.tracks[$0] }
        recording.configuration = track?.instrumentConfiguration ?? InstrumentConfiguration(builtIn: track?.clips.last?.instrument ?? .piano)
        if showRecordingPanel && recording.source == .keyboard { prepareKeyboard() }
    }

    func saveProject() {
        guard !editingLocked else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).aimusic.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            storeInstrument(on: selectedTrackID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            status = "Saved \(url.lastPathComponent)"
        } catch { present(error) }
    }

    func openProject() {
        guard !editingLocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var opened = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: url))
            guard (40...240).contains(opened.bpm), [44_100, 48_000, 96_000].contains(opened.sampleRate),
                  opened.lengthBeats.isFinite, opened.lengthBeats > 0, opened.lengthBeats < 100_000,
                  opened.tracks.flatMap(\.clips).allSatisfy({
                      $0.startBeat.isFinite && $0.startBeat >= 0 && $0.durationBeats.isFinite &&
                      $0.durationBeats > 0 && $0.durationBeats < 100_000 && $0.sourceDurationSeconds.isFinite &&
                      $0.sourceDurationSeconds > 0 && $0.sourceOffsetSeconds.isFinite && $0.sourceOffsetSeconds >= 0 &&
                      ($0.playbackOffsetSeconds ?? 0).isFinite && ($0.playbackOffsetSeconds ?? 0) >= 0 &&
                      ($0.midiSourceBPM == nil || ($0.midiSourceBPM!.isFinite && $0.midiSourceBPM! > 0)) &&
                      ($0.loopLengthSeconds ?? 1).isFinite && ($0.loopLengthSeconds ?? 1) > 0
                  }) else { throw MessageError("This project contains invalid timing or audio settings.") }
            opened.tracks = Array(opened.tracks.prefix(StudioProject.maximumTrackCount))
            if opened.tracks.isEmpty { opened.tracks.append(.new(index: 0)) }
            audio.stop(resetPlayhead: true)
            suppressInstrumentStore = true
            defer { suppressInstrumentStore = false }
            suppressHistory = true
            project = opened
            suppressHistory = false
            history = ProjectHistory()
            editDepth = 0; editBefore = nil
            selectedTrackID = opened.tracks.first?.id
            restoreTrackInstrument()
            selectedClipID = nil
            status = "Opened \(url.lastPathComponent)"
        } catch { present(error) }
    }

    func exportMix() {
        guard !editingLocked else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name)-mix.wav"
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        let snapshot = project
        status = "Exporting WAV…"
        Task {
            defer { isBusy = false }
            do {
                try await audio.export(project: snapshot, to: url)
                status = "Exported \(url.lastPathComponent)"
            } catch { present(error) }
        }
    }

    func refreshModels() {
        Task {
            availableModels = await composer.availableModels(endpoint: generationRequest.endpoint)
            if let first = availableModels.first, !availableModels.contains(generationRequest.model) { generationRequest.model = first }
        }
    }

    func cancelGeneration() { generationTask?.cancel() }
    var isGenerating: Bool { generationTask != nil }

    func generateMusic() {
        guard !editingLocked else { return }
        rememberGenerationSettings()
        let request = generationRequest
        if request.input == .trackAudio && request.engine != .audio {
            present(MessageError("Use MusicGen for audio-conditioned improvisation.")); return
        }
        if request.engine == .audio { generateAudioLoop(request); return }
        let parts: [MusicalPart] = request.part == .fullArrangement ? [.drums, .bass, .chords, .melody] : [request.part]
        var next = project
        var destinations: [Int] = []
        for part in parts {
            if parts.count == 1, let index = selectedTrackIndex { destinations.append(index) }
            else if let index = next.tracks.indices.first(where: { next.tracks[$0].clips.isEmpty && !destinations.contains($0) }) {
                next.tracks[index].name = part.title
                destinations.append(index)
            } else if next.tracks.count < StudioProject.maximumTrackCount {
                var track = TrackModel.new(index: next.tracks.count)
                track.name = part.title
                destinations.append(next.tracks.count)
                next.tracks.append(track)
            } else { present(StudioError.trackLimit); return }
        }
        let start = snappedBeat(audio.currentBeat)
        audio.stop()
        showGenerateSheet = false
        isBusy = true
        generationTask = Task {
            defer { isBusy = false; generationTask = nil }
            do {
                for (index, part) in parts.enumerated() {
                    try Task.checkCancellation()
                    status = "\(index + 1)/\(parts.count): composing \(part.title.lowercased())…"
                    let result = try await composer.compose(part: part, request: request, bpm: next.bpm)
                    let url = AssetManager.shared.newAssetURL(prefix: "Loop-\(part.title)")
                    let bpm = next.bpm, rate = next.sampleRate
                    status = "\(index + 1)/\(parts.count): rendering \(part.title.lowercased()) audio…"
                    let duration = try await Task.detached(priority: .userInitiated) {
                        try MIDIRenderer.render(notes: result.notes, part: part, bpm: bpm,
                            bars: request.bars, sampleRate: rate, to: url)
                    }.value
                    try Task.checkCancellation()
                    let clip = ClipModel(name: "\(part.title) loop", assetPath: url.path, startBeat: start,
                        durationBeats: Double(request.bars * 4), sourceDurationSeconds: duration, loopEnabled: true,
                        midiNotes: result.notes, generatedPart: part, prompt: request.prompt,
                        instrument: .forPart(part), generationMethod: result.detail, midiSourceBPM: bpm)
                    next.tracks[destinations[index]].clips.append(clip)
                }
                next.key = request.key
                next.refreshLength()
                beginEdit("Generate Music"); defer { endEdit() }
                project = next
                selectedTrackID = next.tracks[destinations[0]].id
                selectedClipID = next.tracks[destinations[0]].clips.last?.id
                status = "Created \(parts.count) local audio loop(s) • \(request.useLocalModel ? request.model : "built-in composer")"
            } catch is CancellationError { status = "Generation cancelled" }
            catch {
                if Task.isCancelled { status = "Generation cancelled" }
                else { present(error) }
            }
        }
    }

    private func generateAudioLoop(_ request: GenerationRequest) {
        guard let track = generationTrack else { return }
        let trackID = track.id
        let referencePlan: TrackAudioReference?
        let outputRange: GenerationOutputRange
        do {
            referencePlan = request.input == .trackAudio
                ? try TrackAudioReference(project: project, trackID: trackID, start: request.referenceStartBeat, end: request.referenceEndBeat) : nil
            outputRange = try GenerationOutputRange(project: project, trackID: trackID, request: request,
                                                    playhead: snappedBeat(audio.currentBeat))
        } catch { present(error); return }
        let seconds = outputRange.seconds
        let start = outputRange.startBeat
        let bpm = project.bpm, sampleRate = project.sampleRate
        audio.stop()
        showGenerateSheet = false
        isBusy = true
        status = "Loading the local text-to-audio model…"
        generationTask = Task {
            defer { isBusy = false; generationTask = nil }
            do {
                let raw = AssetManager.shared.newAssetURL(prefix: "MusicGen-native")
                var reference: GenerationReference?
                if let referencePlan {
                    status = "Rendering only \(track.name) as the AI input…"
                    let referenceURL = AssetManager.shared.newAssetURL(prefix: "AI-reference")
                    reference = try await Task.detached(priority: .userInitiated) {
                        try referencePlan.render(to: referenceURL)
                    }.value
                    try Task.checkCancellation()
                }
                let description = request.part == .fullArrangement ? "instrumental full mix" : "isolated \(request.part.title.lowercased()), no other instruments"
                let direction = referencePlan == nil ? description : "Continue the supplied musical part with a coherent improvisation, preserving its instrument and character"
                let prompt = "\(request.prompt). \(direction). \(Int(bpm)) BPM, \(request.key)."
                try await audioGenerator.generate(prompt: prompt, seconds: seconds, seed: request.seed, output: raw,
                    referenceAudio: reference.map { URL(fileURLWithPath: $0.assetPath) }) { [weak self] message in
                    self?.status = message
                }
                try Task.checkCancellation()
                status = "Preparing the audio loop…"
                let asset = try await Task.detached(priority: .userInitiated) {
                    try AssetManager.shared.importAudio(from: raw, sampleRate: sampleRate)
                }.value
                try Task.checkCancellation()
                guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                beginEdit("Generate Audio"); defer { endEdit() }
                let previousLength = project.lengthBeats
                let name = referencePlan == nil ? "\(request.part == .fullArrangement ? "Full mix" : request.part.title) audio loop" : "\(track.name) • AI take"
                let clip = ClipModel(name: name,
                    assetPath: asset.url.path, startBeat: start, durationBeats: outputRange.endBeat - start,
                    sourceDurationSeconds: asset.duration, loopEnabled: true, prompt: request.prompt,
                    generationMethod: "MusicGen Small • \(reference == nil ? "text prompt" : "track audio + text") • seed \(request.seed) • native 32 kHz mono",
                    generationReference: reference)
                project.tracks[index].clips.append(clip)
                project.refreshLength()
                project.lengthBeats = max(previousLength, project.lengthBeats)
                selectedClipID = clip.id
                selectedTrackID = trackID
                status = String(format: "AI take ready • %.1f seconds • through beat %.2f", seconds, outputRange.endBeat)
                generationRequest.seed = Int.random(in: 1...999_999)
                rememberGenerationSettings()
            } catch {
                if Task.isCancelled { status = "Audio generation cancelled" }
                else { present(error) }
            }
        }
    }

    func snappedBeat(_ beat: Double) -> Double { snapEnabled ? (beat * 4).rounded() / 4 : beat }
    func present(_ error: Error) { alertMessage = error.localizedDescription; status = "Couldn’t complete the action" }
}
