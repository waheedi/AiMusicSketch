import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var studio: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            studioToolbar
            Divider()
            HStack(spacing: 0) {
                TimelineEditor(studio: studio)
                Divider()
                InspectorView(studio: studio)
                    .frame(width: 292)
                    .disabled(studio.editingLocked)
            }
            if studio.showRecordingPanel {
                Divider()
                RecordingPanel(studio: studio)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(StudioShortcuts(studio: studio).frame(width: 0, height: 0))
        .sheet(isPresented: $studio.showGenerateSheet) {
            GenerationSheet(studio: studio)
        }
        .sheet(item: Binding(get: { studio.clip(studio.trimClipID) }, set: { if $0 == nil { studio.trimClipID = nil } })) { clip in
            TrimSheet(studio: studio, clip: clip)
        }
        .sheet(item: Binding(get: { studio.clip(studio.noteEditClipID) }, set: { if $0 == nil { studio.noteEditClipID = nil } })) { clip in
            NoteEditorSheet(studio: studio, clip: clip)
        }
        .alert(
            "AI Music Sketchpad",
            isPresented: Binding(
                get: { studio.alertMessage != nil },
                set: { if !$0 { studio.alertMessage = nil } }
            )
        ) {
            Button("OK") { studio.alertMessage = nil }
        } message: {
            Text(studio.alertMessage ?? "")
        }
    }

    private var studioToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.sparkles")
                .font(.title2)
                .foregroundStyle(.purple)
            TextField("Project name", text: $studio.project.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(width: 180)

            Divider().frame(height: 24)
            compactButton("New", systemImage: "doc.badge.plus", action: studio.newProject)
            compactButton("Open", systemImage: "folder", action: studio.openProject)
            compactButton("Save", systemImage: "square.and.arrow.down", action: studio.saveProject)
            compactButton("Undo (⌘Z)", systemImage: "arrow.uturn.backward", action: studio.undo)
                .disabled(!studio.canUndo)
            compactButton("Redo (⇧⌘Z)", systemImage: "arrow.uturn.forward", action: studio.redo)
                .disabled(!studio.canRedo)
            compactButton("Import", systemImage: "waveform.badge.plus", action: studio.importAudio)

            Button {
                studio.beginGeneration()
            } label: {
                Label("Generate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(studio.editingLocked)

            Button(action: studio.toggleRecording) {
                Label(studio.recording.isRecording ? "Stop & Save" : "Record",
                      systemImage: studio.recording.isRecording ? "stop.fill" : "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!studio.canToggleRecording)
            .help("R: record / stop and save take")
            compactButton("Recording Controls (⇧⌘R)", systemImage: "pianokeys") { studio.showRecordingPanel.toggle() }
            .disabled(studio.recording.isRecording)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                TextField("BPM", value: Binding(get: { studio.project.bpm }, set: studio.setTempo), format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 46)
                    .disabled(studio.recording.isRecording || studio.audio.isPlaying)
                    .onSubmit {
                        studio.project.bpm = min(240, max(40, studio.project.bpm))
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

            Text("\(studio.project.sampleRate / 1_000, specifier: "%g") kHz")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button { studio.audio.stop(resetPlayhead: true) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(studio.recording.isRecording)

            Button(action: studio.togglePlayback) {
                Image(systemName: studio.audio.isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderedProminent)
            .tint(studio.audio.isPlaying ? .red : .blue)
            .keyboardShortcut(.space, modifiers: [])

            TransportReadout(audio: studio.audio)

            compactButton("Export", systemImage: "square.and.arrow.up", action: studio.exportMix)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .disabled(studio.isBusy)
    }

    private var statusBar: some View {
        HStack {
            if studio.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
            }
            Text(studio.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if studio.isGenerating { Button("Cancel", action: studio.cancelGeneration).controlSize(.small) }
            Spacer()
            Text("\(studio.project.tracks.count) tracks")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func compactButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .help(title)
    }

}

private struct TransportReadout: View {
    @ObservedObject var audio: AudioEngineController
    var body: some View {
        Text(String(format: "%02d.%02d", Int(audio.playheadBeat / 4) + 1,
                    Int(audio.playheadBeat.truncatingRemainder(dividingBy: 4)) + 1))
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .frame(width: 64)
    }
}

private struct PlayheadOverlay: View {
    @ObservedObject var audio: AudioEngineController
    let beatWidth: Double
    var scrollOffset = 0.0
    var ruler = false
    var body: some View {
        Group {
            if ruler {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8)).foregroundStyle(.red).rotationEffect(.degrees(180))
                    .offset(x: audio.playheadBeat * beatWidth - scrollOffset - 3.3, y: 23)
            } else {
                Rectangle().fill(Color.red.opacity(0.9)).frame(width: 1.5)
                    .offset(x: audio.playheadBeat * beatWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TimelineEditor: View {
    @ObservedObject var studio: StudioModel
    private let headerWidth = 208.0
    private var beatWidth: Double { studio.timelineBeatWidth }
    private var visibleBeats: Double { max(studio.project.contentEndBeat, max(studio.project.lengthBeats, displayedEndBeat)) + 16 }
    private var timelineWidth: Double { max(900, visibleBeats * beatWidth) }
    @GestureState private var draggedEndBeat: Double?
    private var displayedEndBeat: Double { draggedEndBeat ?? studio.project.lengthBeats }
    @AppStorage("timelineFollowPlayhead") private var followPlayhead = true
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var viewport = TimelineViewport()
    private let rowHeight = 76.0
    private let rulerHeight = 30.0

    var body: some View {
        VStack(spacing: 0) {
            pinnedRuler
            Divider()
            ScrollViewReader { verticalScroll in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    trackHeaders
                        .frame(width: headerWidth)
                        .disabled(studio.editingLocked)
                    Divider()
                    ScrollView(.horizontal) { timeline.disabled(studio.editingLocked) }
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: TimelineViewport.self) { geometry in
                            TimelineViewport(offset: geometry.contentOffset.x, width: geometry.containerSize.width,
                                             contentWidth: geometry.contentSize.width)
                        } action: { old, new in
                            viewport = new
                            if old.width != new.width || old.contentWidth != new.contentWidth { followCursor() }
                        }
                        .onReceive(studio.audio.$playheadBeat) { beat in followCursor(beat: beat) }
                        .onChange(of: studio.audio.isPlaying) { _, playing in
                            if playing { followCursor(force: true) }
                        }
                        .onChange(of: followPlayhead) { _, enabled in
                            if enabled { followCursor(force: true) }
                        }
                        .onChange(of: beatWidth) { old, new in
                            // Keep the same left-edge beat when zooming a scrolled timeline.
                            scrollPosition.scrollTo(x: max(0, viewport.offset / old * new))
                            if studio.audio.isPlaying && followPlayhead { followCursor(force: true) }
                        }
                }
            }
            .onChange(of: studio.project.tracks.count) { old, new in
                if new > old, let id = studio.selectedTrackID { verticalScroll.scrollTo(id, anchor: .bottom) }
            }
            }
            Divider()
            HStack {
                Button { studio.addTrack() } label: {
                    Label("Add Track", systemImage: "plus")
                }
                .disabled(studio.editingLocked)
                Button(role: .destructive) { studio.deleteSelectedTrack() } label: {
                    Label(studio.selectedTrackIDs.count > 1 ? "Remove \(studio.selectedTrackIDs.count) Tracks" : "Remove Track", systemImage: "minus")
                }
                .disabled(studio.selectedTrackIndex == nil || studio.editingLocked)
                Spacer()
                Toggle(isOn: $followPlayhead) { Label("Follow Playhead", systemImage: "arrow.right.to.line") }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .help(followPlayhead ? "Follow Playhead is on — click to scroll freely" : "Follow Playhead is off — click to follow playback")
                    .accessibilityLabel("Follow Playhead")
                Toggle("Snap ¼ beat", isOn: $studio.snapEnabled).toggleStyle(.checkbox)
                Text("Zoom").font(.caption)
                Button { studio.zoomTimeline(inward: false) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)")
                Slider(value: $studio.timelineBeatWidth, in: 8...160).frame(width: 90)
                Button { studio.zoomTimeline(inward: true) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+ or ⌘=)")
                Text(studio.selectedClipIDs.count > 1 ? "\(studio.selectedClipIDs.count) clips selected • Delete to remove"
                     : "⌘/Shift-click selects • drag END to resize project")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
        }
    }

    private func followCursor(force: Bool = false, beat: Double? = nil) {
        if let target = TimelineFollow.target(playheadX: (beat ?? studio.audio.playheadBeat) * beatWidth,
            viewport: viewport, enabled: followPlayhead, playing: studio.audio.isPlaying, force: force) {
            scrollPosition.scrollTo(x: target)
        }
    }

    private var pinnedRuler: some View {
        HStack(spacing: 0) {
            HStack {
                Text("TRACKS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("M  S").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(width: headerWidth, height: rulerHeight)
            Divider()
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    BeatRuler(lengthBeats: visibleBeats, beatWidth: beatWidth, bpm: studio.project.bpm)
                        .frame(width: timelineWidth, height: rulerHeight)
                        .offset(x: -viewport.offset)
                        .allowsHitTesting(false)
                    PlayheadOverlay(audio: studio.audio, beatWidth: beatWidth, scrollOffset: viewport.offset, ruler: true)
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded {
                            studio.seek(to: ($0.location.x + viewport.offset) / beatWidth)
                        })
                    projectEndHandle
                }
                .coordinateSpace(name: "projectRuler")
            }
            .clipped()
            .disabled(studio.editingLocked)
        }
        .frame(height: rulerHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var projectEndHandle: some View {
        Label("END", systemImage: "arrow.left.and.right")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
            .frame(width: 54, height: 24)
            .background(.yellow, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .offset(x: displayedEndBeat * beatWidth - viewport.offset - 27, y: 3)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("projectRuler"))
                .updating($draggedEndBeat) { value, state, _ in
                    let delta = value.translation.width / beatWidth
                    state = studio.projectEndBeat(for: studio.project.lengthBeats + delta)
                }
                .onEnded { value in
                    studio.setProjectEnd(to: studio.project.lengthBeats + value.translation.width / beatWidth)
                })
            .contextMenu {
                Button("Fit End to Clips") {
                    studio.setProjectEnd(to: max(4, ceil(studio.project.contentEndBeat / 4) * 4))
                }
            }
            .help(String(format: "Project end: %.1f s. Drag to shorten/extend playback and export. Clips are not deleted.", displayedEndBeat * 60 / studio.project.bpm))
            .accessibilityLabel("Project end")
            .accessibilityValue("\(displayedEndBeat) beats")
            .accessibilityAdjustableAction { direction in
                studio.setProjectEnd(to: studio.project.lengthBeats + (direction == .increment ? 4 : -4))
            }
    }

    private var trackHeaders: some View {
        VStack(spacing: 0) {
            ForEach(studio.project.tracks.indices, id: \.self) { index in
                let track = studio.project.tracks[index]
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: track.colorHex))
                        .frame(width: 5, height: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(track.clips.count) clip\(track.clips.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let parameter = studio.visibleAutomation[track.id] {
                            Picker("Automation", selection: Binding(get: { studio.visibleAutomation[track.id] ?? parameter }, set: { studio.visibleAutomation[track.id] = $0 })) {
                                ForEach(AutomationParameter.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 104)
                            Text("Click curve to add points\nDrag points • zero = base")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 2)
                    Button {
                        if studio.visibleAutomation[track.id] == nil { studio.visibleAutomation[track.id] = .volume }
                        else { studio.visibleAutomation.removeValue(forKey: track.id) }
                    } label: { Image(systemName: "point.3.connected.trianglepath.dotted").font(.caption) }
                    .buttonStyle(.plain).help("Show/hide track automation")
                    miniToggle("M", isOn: track.isMuted) {
                        studio.project.tracks[index].isMuted.toggle()
                    }
                    miniToggle("S", isOn: track.isSolo) {
                        studio.project.tracks[index].isSolo.toggle()
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: studio.trackHeight(track.id))
                .contentShape(Rectangle())
                .background(
                    studio.selectedTrackIDs.contains(track.id)
                        ? Color.accentColor.opacity(0.22)
                        : Color(nsColor: .windowBackgroundColor)
                )
                .overlay(alignment: .bottom) { Divider() }
                .id(track.id)
                .onTapGesture {
                    studio.selectTrack(track.id, additive: NSEvent.modifierFlags.contains(.command),
                                       range: NSEvent.modifierFlags.contains(.shift))
                }
                .help("Shift-click selects a track range; ⌘-click toggles tracks. Delete removes selected tracks.")
                .draggable("track:\(track.id.uuidString)")
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item.hasPrefix("track:"),
                          let id = UUID(uuidString: String(item.dropFirst(6))) else { return false }
                    return studio.moveTrack(id, to: track.id)
                }
                .contextMenu {
                    Button("Duplicate Track") { studio.duplicateTrack(track.id) }
                    Button("Merge Clips (Keep Notes When Compatible)") { studio.mergeClips(on: track.id) }
                        .disabled(track.clips.count < 2 || studio.editingLocked)
                    Button(studio.selectedTrackIDs.contains(track.id) && studio.selectedTrackIDs.count > 1
                           ? "Delete \(studio.selectedTrackIDs.count) Selected Tracks" : "Delete Track", role: .destructive) {
                        if !studio.selectedTrackIDs.contains(track.id) { studio.selectTrack(track.id) }
                        studio.deleteSelectedTrack()
                    }.disabled(studio.editingLocked)
                    Button("AI • Improvise from this track…") { studio.beginGeneration(trackID: track.id, useTrack: true) }
                        .disabled(track.clips.isEmpty)
                    Button("Paste clip at playhead") { studio.selectTrack(track.id); studio.pasteClip() }
                    if let parameter = studio.visibleAutomation[track.id] {
                        Button("Clear \(parameter.rawValue) automation") { studio.clearAutomation(trackID: track.id, parameter: parameter) }
                    }
                    Button("Record on this track…") {
                        studio.selectTrack(track.id)
                        studio.showRecordingPanel = true
                    }
                    Menu("Loop clip ×2") {
                        ForEach(track.clips) { clip in Button(clip.name) { studio.loopClip(clip.id) } }
                    }
                    .disabled(track.clips.isEmpty)
                    Menu("Trim clip") {
                        ForEach(track.clips) { clip in Button(clip.name) { studio.trimClipID = clip.id } }
                    }
                    .disabled(track.clips.isEmpty)
                }
            }
        }
    }

    private var timeline: some View {
        let width = timelineWidth
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(studio.project.tracks) { track in
                    VStack(spacing: 0) {
                    TimelineLane(
                        studio: studio,
                        track: track,
                        beatWidth: beatWidth,
                        rowHeight: rowHeight,
                        width: width
                    )
                    if let parameter = studio.visibleAutomation[track.id] {
                        AutomationEditor(studio: studio, track: track, parameter: parameter, beatWidth: beatWidth)
                    }
                    }
                    .zIndex(track.clips.contains { $0.id == studio.draggingClipID } ? 10 : 0)
                }
            }
            Rectangle().fill(Color.black.opacity(0.2))
                .frame(width: max(0, width - displayedEndBeat * beatWidth))
                .offset(x: displayedEndBeat * beatWidth)
                .allowsHitTesting(false)
            Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 1)
                .offset(x: displayedEndBeat * beatWidth).allowsHitTesting(false)
            PlayheadOverlay(audio: studio.audio, beatWidth: beatWidth)
                .frame(height: studio.project.tracks.reduce(0) { $0 + studio.trackHeight($1.id) })
        }
        .frame(width: width, alignment: .leading)
        .coordinateSpace(name: "timeline")
    }

    private func miniToggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption2.bold()).frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? .white : .secondary)
        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct BeatRuler: View {
    let lengthBeats: Double
    let beatWidth: Double
    let bpm: Double

    var body: some View {
        Canvas { context, _ in
            for beat in 0...Int(ceil(lengthBeats)) {
                context.fill(Path(CGRect(x: Double(beat) * beatWidth, y: 18, width: 1,
                                         height: beat.isMultiple(of: 4) ? 12 : 6)),
                             with: .color(.secondary.opacity(beat.isMultiple(of: 4) ? 0.6 : 0.22)))
                if beat.isMultiple(of: beatWidth < 14 ? 16 : beatWidth < 28 ? 8 : 4) {
                    context.draw(Text("\(beat / 4 + 1) · \(Double(beat) * 60 / bpm, specifier: "%.1f")s")
                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                                 at: CGPoint(x: Double(beat) * beatWidth + 4, y: 3), anchor: .topLeading)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Timeline ruler, bars and seconds")
    }
}

private struct TimelineLane: View {
    @ObservedObject var studio: StudioModel
    let track: TrackModel
    let beatWidth: Double
    let rowHeight: Double
    let width: Double
    @GestureState private var selectionRange: ClosedRange<Double>?

    var body: some View {
        ZStack(alignment: .leading) {
            BeatGrid(lengthBeats: width / beatWidth, beatWidth: beatWidth)
                .contentShape(Rectangle())
                .onTapGesture { studio.selectClips(trackID: track.id, ids: []) }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($selectionRange) { value, state, _ in
                            state = min(value.startLocation.x, value.location.x)...max(value.startLocation.x, value.location.x)
                        }
                        .onEnded { value in
                            let lower = min(value.startLocation.x, value.location.x) / beatWidth
                            let upper = max(value.startLocation.x, value.location.x) / beatWidth
                            let ids = Set(track.clips.filter { $0.startBeat < upper && $0.endBeat > lower }.map(\.id))
                            studio.selectClips(trackID: track.id, ids: ids,
                                               additive: NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty == false)
                        }
                )
            ForEach(track.clips) { clip in
                TimelineClip(
                    studio: studio,
                    trackID: track.id,
                    clip: clip,
                    color: Color(hex: track.colorHex),
                    beatWidth: beatWidth,
                    height: rowHeight - 14
                )
            }
            if let range = selectionRange {
                Rectangle().fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: range.upperBound - range.lowerBound, height: rowHeight)
                    .offset(x: range.lowerBound).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: rowHeight)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct BeatGrid: View {
    let lengthBeats: Double
    let beatWidth: Double

    var body: some View {
        Canvas { context, size in
            for beat in 0...Int(ceil(lengthBeats)) {
                var path = Path()
                let x = Double(beat) * beatWidth
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let shade = beat.isMultiple(of: 4)
                    ? Color.secondary.opacity(0.22)
                    : Color.secondary.opacity(0.08)
                context.stroke(path, with: .color(shade), lineWidth: 1)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

private struct TimelineClip: View {
    @ObservedObject var studio: StudioModel
    let trackID: UUID
    let clip: ClipModel
    let color: Color
    let beatWidth: Double
    let height: Double
    @GestureState private var dragOffset = CGSize.zero
    private struct ResizeDrag: Equatable { var left: Bool; var delta: Double }
    @GestureState private var resizeDrag: ResizeDrag?
    private var preview: ClipModel {
        guard let resizeDrag else { return clip }
        let edge = resizeDrag.left ? clip.startBeat : clip.endBeat
        return ClipEditing.resize(clip, leftEdge: resizeDrag.left,
                                  to: studio.snappedBeat(edge + resizeDrag.delta / beatWidth), bpm: studio.project.bpm)
    }

    var body: some View {
        let width = max(18, preview.durationBeats * beatWidth)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.95), color.opacity(0.64)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    studio.selectedClipIDs.contains(clip.id) ? Color.white : color.opacity(0.8),
                    lineWidth: studio.selectedClipIDs.contains(clip.id) ? 2 : 1
                )
            Group {
                if preview.midiNotes != nil {
                    ClipNoteView(clip: preview, bpm: studio.project.bpm)
                } else {
                    AudioWaveform(clip: preview, bpm: studio.project.bpm)
                }
            }
            // No horizontal inset: source time zero must align with the clip edge.
            .padding(.top, 18)
            .padding(.bottom, 5)
            .frame(width: preview.durationBeats * beatWidth)
            .clipped()
            HStack(spacing: 4) {
                if clip.generatedPart != nil { Image(systemName: "sparkles") }
                else if clip.midiNotes != nil { Image(systemName: "pianokeys") }
                Text(clip.name).lineLimit(1)
                if clip.loopEnabled { Image(systemName: "repeat") }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.top, 5)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("timeline"))
                .updating($dragOffset) { value, state, _ in state = value.translation }
                .onChanged { _ in
                    if studio.draggingClipID != clip.id {
                        studio.draggingClipID = clip.id
                        studio.selectClip(trackID: trackID, clipID: clip.id)
                    }
                }
                .onEnded { value in
                    studio.draggingClipID = nil
                    studio.moveClip(
                        id: clip.id,
                        on: studio.dragDestination(trackID: trackID, deltaY: value.translation.height),
                        to: clip.startBeat + value.translation.width / beatWidth
                    )
                }
        )
        .onTapGesture(count: 2) {
            studio.selectClip(trackID: trackID, clipID: clip.id)
            studio.editNotes(clip.id)
        }
        .onTapGesture {
            studio.selectClip(trackID: trackID, clipID: clip.id,
                              additive: NSEvent.modifierFlags.contains(.command),
                              range: NSEvent.modifierFlags.contains(.shift))
        }
        .help("⌘-click to toggle selection; Shift-click to select a range. Delete removes selected clips. Seek using the ruler above.")
        .contextMenu { ClipContextMenu(studio: studio, trackID: trackID, clip: clip) }
        .overlay(alignment: .leading) { trimHandle(left: true) }
        .overlay(alignment: .trailing) { trimHandle(left: false) }
        .offset(x: (dragOffset == .zero ? preview.startBeat : max(0, studio.snappedBeat(clip.startBeat + dragOffset.width / beatWidth))) * beatWidth, y: dragOffset.height)
        .zIndex(studio.draggingClipID == clip.id ? 10 : 0)
        .onChange(of: dragOffset) { _, offset in
            if offset == .zero, studio.draggingClipID == clip.id { studio.draggingClipID = nil }
        }
        .padding(.vertical, 7)
    }

    private func trimHandle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(studio.selectedClipIDs.contains(clip.id) ? 0.9 : 0.45))
            .frame(width: 4, height: 30)
            .frame(width: min(16, max(18, preview.durationBeats * beatWidth) / 3), height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
                .updating($resizeDrag) { value, state, _ in state = ResizeDrag(left: left, delta: value.translation.width) }
                .onChanged { _ in studio.selectClip(trackID: trackID, clipID: clip.id) }
                .onEnded { value in
                    studio.resizeClip(clip.id, leftEdge: left,
                                      to: (left ? clip.startBeat : clip.endBeat) + value.translation.width / beatWidth)
                })
            .help("Drag outward to add empty space; inward to trim. Loop ×2/×4 repeats the whole block, including its empty space.")
    }
}

private struct InspectorView: View {
    @ObservedObject var studio: StudioModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("INSPECTOR")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let trackIndex = studio.selectedTrackIndex {
                    trackInspector(index: trackIndex)
                } else {
                    ContentUnavailableView("No Track Selected", systemImage: "slider.horizontal.3")
                }

                if let location = studio.selectedClipLocation {
                    Divider()
                    clipInspector(trackIndex: location.track, clipIndex: location.clip)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func trackInspector(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRACK").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            TextField("Track name", text: $studio.project.tracks[index].name)
            HStack {
                Toggle("Mute", isOn: $studio.project.tracks[index].isMuted)
                Toggle("Solo", isOn: $studio.project.tracks[index].isSolo)
            }
            inspectorSlider("Volume", value: $studio.project.tracks[index].volume, range: 0...1)
            inspectorSlider("Pan", value: $studio.project.tracks[index].pan, range: -1...1)

            Text("MIX EFFECTS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            inspectorSlider("Low EQ", value: $studio.project.tracks[index].effects.lowGain, range: -18...18, suffix: " dB")
            inspectorSlider("Mid EQ", value: $studio.project.tracks[index].effects.midGain, range: -18...18, suffix: " dB")
            inspectorSlider("High EQ", value: $studio.project.tracks[index].effects.highGain, range: -18...18, suffix: " dB")
            inspectorSlider("Compression", value: $studio.project.tracks[index].effects.compression, range: 0...1)
            inspectorSlider("Drive", value: $studio.project.tracks[index].effects.drive, range: 0...1)
            inspectorSlider("Bit-crush", value: $studio.project.tracks[index].effects.bitCrush, range: 0...1)
            Picker("Reverb space", selection: $studio.project.tracks[index].effects.reverbSpace) {
                ForEach(ReverbSpace.allCases) { Text($0.rawValue).tag($0) }
            }
            inspectorSlider("Reverb", value: $studio.project.tracks[index].effects.reverb, range: 0...1)
            inspectorSlider("Delay", value: $studio.project.tracks[index].effects.delay, range: 0...1)
            inspectorSlider("Delay time", value: $studio.project.tracks[index].effects.delayTime, range: 0.01...2, suffix: " s")
            inspectorSlider("Delay feedback", value: $studio.project.tracks[index].effects.delayFeedback, range: 0...0.85)

            Text("FILTER").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Picker("Type", selection: $studio.project.tracks[index].effects.filterMode) {
                ForEach(FilterMode.allCases) { Text($0.rawValue).tag($0) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Cutoff • \(studio.project.tracks[index].effects.filterCutoff, specifier: "%.0f") Hz").font(.caption)
                Slider(value: Binding(get: { log2(max(20, studio.project.tracks[index].effects.filterCutoff)) },
                                      set: { studio.project.tracks[index].effects.filterCutoff = pow(2, $0) }),
                       in: log2(20)...log2(20_000), onEditingChanged: { editing in
                    if editing { studio.beginEdit("Filter Cutoff") } else { studio.endEdit() }
                })
            }
            .disabled(studio.project.tracks[index].effects.filterMode == .off)
            inspectorSlider("Resonance", value: $studio.project.tracks[index].effects.filterResonance, range: 0...1)
                .disabled(studio.project.tracks[index].effects.filterMode == .off)
            Button("Automate filter cutoff") {
                studio.visibleAutomation[studio.project.tracks[index].id] = .filterCutoff
            }
            Text("Automation zero keeps these base settings. Enable a filter type to hear its cutoff curve.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func clipInspector(trackIndex: Int, clipIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("CLIP").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            TextField("Clip name", text: $studio.project.tracks[trackIndex].clips[clipIndex].name)
            let clip = studio.project.tracks[trackIndex].clips[clipIndex]
            Text("Beat \(clip.startBeat, format: .number.precision(.fractionLength(2))) • \(clip.durationBeats, format: .number.precision(.fractionLength(2))) beats")
                .font(.caption.monospacedDigit())
            HStack {
                Button("Trim…") { studio.trimClipID = clip.id }
                Button("Loop ×2") { studio.loopClip(clip.id) }
            }
            if clip.loopEnabled { Button("Stop looping") { studio.stopLooping(clip.id) } }
            if clip.generatedPart == nil, let prompt = clip.prompt {
                Text(prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }

            if let part = studio.project.tracks[trackIndex].clips[clipIndex].generatedPart {
                Label("AI \(part.title) • \(studio.project.tracks[trackIndex].clips[clipIndex].midiNotes?.count ?? 0) notes", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
                if let prompt = studio.project.tracks[trackIndex].clips[clipIndex].prompt {
                    Text(prompt).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            if let method = clip.generationMethod { Text(method).font(.caption2).foregroundStyle(.secondary) }

            HStack {
                Button("Split", systemImage: "scissors", action: studio.splitSelectedClip)
                Button("Delete", systemImage: "trash", role: .destructive, action: studio.deleteSelectedClip)
            }
        }
    }

    private func inspectorSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String = ""
    ) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(value.wrappedValue, format: .number.precision(.fractionLength(1)))\(suffix)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing { studio.beginEdit(title) } else { studio.endEdit() }
            })
        }
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct GenerationSheet: View {
    @ObservedObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss

    private var outputStart: Double {
        guard let id = studio.generationTrack?.id else { return 0 }
        return GenerationOutputRange.start(project: studio.project, trackID: id, request: studio.generationRequest,
                                           playhead: studio.snappedBeat(studio.audio.currentBeat))
    }
    private var outputEnd: Double { studio.generationRequest.outputEndBeat ?? (outputStart + Double(studio.generationRequest.bars) * 4) }
    private var audioSeconds: Double { (outputEnd - outputStart) * 60 / studio.project.bpm }
    private var outputError: String? {
        guard let id = studio.generationTrack?.id else { return "Select a track first." }
        do {
            _ = try GenerationOutputRange(project: studio.project, trackID: id, request: studio.generationRequest,
                                           playhead: studio.snappedBeat(studio.audio.currentBeat))
            return nil
        } catch { return error.localizedDescription }
    }
    private var isReference: Bool { studio.generationRequest.input == .trackAudio }
    private var referenceSeconds: Double { isReference ? (studio.generationRequest.referenceEndBeat - studio.generationRequest.referenceStartBeat) * 60 / studio.project.bpm : 0 }
    private var validReference: Bool {
        guard isReference else { return true }
        guard let track = studio.generationTrack else { return false }
        return (try? TrackAudioReference(project: studio.project, trackID: track.id,
            start: studio.generationRequest.referenceStartBeat, end: studio.generationRequest.referenceEndBeat)) != nil
    }
    private var generatorReady: Bool {
        switch studio.generationRequest.engine {
        case .audio: TextAudioGenerator.installed
        case .localNotes: !studio.availableModels.isEmpty
        case .builtIn: true
        }
    }
    private var generatorDetail: String {
        switch studio.generationRequest.engine {
        case .audio:
            return TextAudioGenerator.installed
                ? "MusicGen generates sound directly on this Mac. Native audio: 32 kHz mono; converted to the project rate. Tempo and key are guidance, so check the groove before layering. Model weights: CC BY-NC 4.0 (noncommercial)."
                : "Audio model not installed. Run scripts/setup-audio.sh from the project folder, then reopen this sheet."
        case .localNotes:
            return studio.availableModels.isEmpty
                ? "No local model detected. Start Ollama and press Check, or choose Built-in instrument patterns."
                : "Ollama is ready with \(studio.availableModels.count) local model(s). It generates notes, which are rendered with native instruments."
        case .builtIn:
            return "Built-in patterns use native instruments and need no model or network connection. This mode does not generate sounds from a prompt-to-audio model."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple).font(.title2)
                VStack(alignment: .leading) {
                    Text("AI • \(studio.generationTrack?.name ?? "Selected track")").font(.title2.bold())
                    Text(isReference ? "Uses this track's sound and adds a new take. Originals stay intact." : "Create a new sound on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Input", selection: $studio.generationRequest.input) {
                    Text(GenerationInput.textOnly.rawValue).tag(GenerationInput.textOnly)
                    if studio.generationTrack?.clips.isEmpty == false {
                        Text(GenerationInput.trackAudio.rawValue).tag(GenerationInput.trackAudio)
                    }
                }
                if isReference {
                    Text("AI INPUT • existing music to learn from").font(.caption2.bold()).foregroundStyle(.secondary)
                    HStack {
                        TextField("Reference from beat", value: $studio.generationRequest.referenceStartBeat, format: .number.precision(.fractionLength(2)))
                        TextField("Reference to beat", value: $studio.generationRequest.referenceEndBeat, format: .number.precision(.fractionLength(2)))
                        Button("Use ending") { studio.resetReferenceRange() }
                    }
                    Text("Reference: \(referenceSeconds, specifier: "%.2f") seconds (0.25–12). MIDI is heard through its recorded instrument; other tracks are excluded.")
                        .font(.caption).foregroundStyle(validReference ? Color.secondary : Color.red)
                }
                Picker("Generator", selection: $studio.generationRequest.engine) {
                    ForEach(GenerationEngine.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(isReference)
                TextField("Creative direction", text: $studio.generationRequest.prompt, axis: .vertical)
                    .lineLimit(3...6)
                if !isReference { Picker("Part", selection: $studio.generationRequest.part) {
                    ForEach(MusicalPart.allCases) { part in
                        Text(part == .fullArrangement && studio.generationRequest.engine == .audio ? "Full mix (one audio clip)" : part.title).tag(part)
                    }
                }
                }
                Stepper("Bars: \(studio.generationRequest.bars)\(studio.generationRequest.outputEndBeat == nil ? "" : " (preset)")",
                        value: Binding(get: { studio.generationRequest.bars }, set: {
                            studio.generationRequest.bars = $0; studio.generationRequest.outputEndBeat = nil
                        }), in: 1...32)
                TextField("Key", text: $studio.generationRequest.key)
                if studio.generationRequest.engine == .audio {
                    Text("AI OUTPUT • new music to add").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text("Starts at beat \(outputStart, specifier: "%.2f")\(isReference ? " • after the last clip" : " • at the playhead")")
                        .font(.caption)
                    HStack {
                        TextField("Generate through beat", value: Binding(get: { outputEnd }, set: { studio.generationRequest.outputEndBeat = $0 }),
                                  format: .number.precision(.fractionLength(2)))
                        Button("Use bars") { studio.generationRequest.outputEndBeat = nil }
                    }
                    if let outputError {
                        Text(outputError).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("New music: \(audioSeconds, specifier: "%.1f") s. \(outputEnd > studio.project.lengthBeats ? "The timeline will extend to fit." : "Existing clips stay intact.")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Up to 5 minutes of new audio. Longer requests use connected continuation sections and take more time. Cancel leaves your track unchanged.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        TextField("Seed", value: $studio.generationRequest.seed, format: .number.grouping(.never))
                        Button("Randomize") { studio.generationRequest.seed = Int.random(in: 1...999_999) }
                    }
                }
                if studio.generationRequest.engine == .localNotes {
                Picker("Local model", selection: $studio.generationRequest.model) {
                    if studio.availableModels.isEmpty {
                        Text(studio.generationRequest.model).tag(studio.generationRequest.model)
                    } else {
                        ForEach(studio.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                .disabled(!studio.generationRequest.useLocalModel)
                HStack {
                    TextField("Ollama endpoint", text: $studio.generationRequest.endpoint)
                    Button("Check") { studio.refreshModels() }
                }
                }
            }
            .formStyle(.grouped)

            GroupBox {
                HStack(alignment: .top) {
                    Image(systemName: generatorReady ? "checkmark.circle.fill" : "cpu")
                        .foregroundStyle(generatorReady ? Color.green : Color.secondary)
                    Text(isReference ? "MusicGen hears the reference and generates NEW music from the last clip through your chosen output end beat, extending the timeline as needed. It does not replace existing clips. Longer continuations can drift in style or tempo. 32 kHz mono • model license: noncommercial." : generatorDetail)
                    .font(.caption)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isReference ? "Improvise New Take" : "Generate") { studio.generateMusic() }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(studio.generationRequest.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .disabled(studio.generationRequest.engine == .audio && (!generatorReady || !validReference || outputError != nil))
            }
        }
        .padding(24)
        .frame(width: 680, height: 740)
        .onAppear { if studio.generationRequest.engine == .localNotes { studio.refreshModels() } }
        .onChange(of: studio.generationRequest.engine) { _, engine in
            if engine != .audio { studio.generationRequest.outputEndBeat = nil }
            if engine == .localNotes { studio.refreshModels() }
        }
        .onChange(of: studio.generationRequest.input) { _, input in
            studio.generationRequest.outputEndBeat = nil
            if input == .trackAudio { studio.generationRequest.engine = .audio; studio.resetReferenceRange() }
        }
        .onDisappear { studio.rememberGenerationSettings() }
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x777777
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
