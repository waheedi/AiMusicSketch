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
            }
            .disabled(studio.editingLocked)
            if studio.showRecordingPanel {
                Divider()
                RecordingPanel(studio: studio)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $studio.showGenerateSheet) {
            GenerationSheet(studio: studio)
        }
        .sheet(item: Binding(get: { studio.clip(studio.trimClipID) }, set: { if $0 == nil { studio.trimClipID = nil } })) { clip in
            TrimSheet(studio: studio, clip: clip)
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
            compactButton("Import", systemImage: "waveform.badge.plus", action: studio.importAudio)

            Button {
                studio.beginGeneration()
            } label: {
                Label("Generate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(studio.editingLocked)

            Button { studio.showRecordingPanel.toggle() } label: {
                Label("Record", systemImage: "mic")
            }
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

            Text(beatLabel(studio.audio.playheadBeat))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 64)

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
            Text("\(studio.project.tracks.count)/\(StudioProject.maximumTrackCount) tracks")
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

    private func beatLabel(_ beat: Double) -> String {
        let bar = Int(beat / 4) + 1
        let beatInBar = Int(beat.truncatingRemainder(dividingBy: 4)) + 1
        return String(format: "%02d.%02d", bar, beatInBar)
    }
}

private struct TimelineEditor: View {
    @ObservedObject var studio: StudioModel
    private let headerWidth = 208.0
    @State private var beatWidth = 34.0
    private let rowHeight = 76.0
    private let rulerHeight = 30.0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    trackHeaders
                        .frame(width: headerWidth)
                    Divider()
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal) { timeline }
                            .onChange(of: Int(studio.audio.playheadBeat / 16)) { _, page in
                                if studio.audio.isPlaying { scroll.scrollTo("bar-\(page * 4 + 1)", anchor: .leading) }
                            }
                    }
                }
            }
            Divider()
            HStack {
                Button { studio.addTrack() } label: {
                    Label("Add Track", systemImage: "plus")
                }
                Button(role: .destructive) { studio.deleteSelectedTrack() } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(studio.selectedTrackIndex == nil)
                Spacer()
                Toggle("Snap ¼ beat", isOn: $studio.snapEnabled).toggleStyle(.checkbox)
                Text("Zoom").font(.caption)
                Slider(value: $beatWidth, in: 16...100).frame(width: 100)
                Text("Drag body to move • edges to trim • ⌘C / ⌘V / ⌘D")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
        }
    }

    private var trackHeaders: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRACKS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("M  S").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: rulerHeight)
            .background(Color(nsColor: .controlBackgroundColor))

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
                    studio.selectedTrackID == track.id
                        ? Color.accentColor.opacity(0.12)
                        : Color(nsColor: .windowBackgroundColor)
                )
                .overlay(alignment: .bottom) { Divider() }
                .onTapGesture { studio.selectTrack(track.id) }
                .contextMenu {
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
        let width = max(900, studio.project.lengthBeats * beatWidth)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                BeatRuler(lengthBeats: studio.project.lengthBeats, beatWidth: beatWidth, bpm: studio.project.bpm)
                    .frame(width: width, height: rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { studio.seek(to: $0.location.x / beatWidth) })
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
            Rectangle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 1.5, height: studio.project.tracks.reduce(0) { $0 + studio.trackHeight($1.id) })
                .offset(x: studio.audio.playheadBeat * beatWidth, y: rulerHeight)
                .allowsHitTesting(false)
            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.red)
                .rotationEffect(.degrees(180))
                .offset(x: studio.audio.playheadBeat * beatWidth - 3.3, y: rulerHeight - 7)
                .allowsHitTesting(false)
        }
        .frame(width: width, alignment: .leading)
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
        ZStack(alignment: .topLeading) {
            Color(nsColor: .controlBackgroundColor)
            ForEach(0...Int(ceil(lengthBeats)), id: \.self) { beat in
                Rectangle()
                    .fill(beat.isMultiple(of: 4) ? Color.secondary.opacity(0.6) : Color.secondary.opacity(0.22))
                    .frame(width: 1, height: beat.isMultiple(of: 4) ? 12 : 6)
                    .offset(x: Double(beat) * beatWidth, y: 18)
                if beat.isMultiple(of: 4) {
                    Text("\(beat / 4 + 1) · \(Double(beat) * 60 / bpm, specifier: "%.1f")s")
                        .id("bar-\(beat / 4 + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: Double(beat) * beatWidth + 4, y: 3)
                }
            }
        }
    }
}

private struct TimelineLane: View {
    @ObservedObject var studio: StudioModel
    let track: TrackModel
    let beatWidth: Double
    let rowHeight: Double
    let width: Double

    var body: some View {
        ZStack(alignment: .leading) {
            BeatGrid(lengthBeats: studio.project.lengthBeats, beatWidth: beatWidth)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            studio.seek(to: value.location.x / beatWidth)
                            studio.selectTrack(track.id)
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

    var body: some View {
        let width = max(34, clip.durationBeats * beatWidth)
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
                    studio.selectedClipID == clip.id ? Color.white : color.opacity(0.8),
                    lineWidth: studio.selectedClipID == clip.id ? 2 : 1
                )
            if let notes = clip.midiNotes {
                MiniPianoRoll(notes: notes)
                    .padding(.top, 20)
                    .opacity(0.7)
            } else {
                AudioWaveform(clip: clip, bpm: studio.project.bpm)
                    .padding(.horizontal, 8)
                    .padding(.top, 18)
                    .padding(.bottom, 5)
            }
            HStack(spacing: 4) {
                if clip.generatedPart != nil { Image(systemName: "sparkles") }
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
            DragGesture(minimumDistance: 3)
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
        .onTapGesture { studio.selectClip(trackID: trackID, clipID: clip.id) }
        .contextMenu { ClipContextMenu(studio: studio, trackID: trackID, clip: clip) }
        .overlay(alignment: .leading) { trimHandle(left: true) }
        .overlay(alignment: .trailing) { trimHandle(left: false) }
        .offset(x: max(0, studio.snappedBeat(clip.startBeat + dragOffset.width / beatWidth)) * beatWidth, y: dragOffset.height)
        .zIndex(studio.draggingClipID == clip.id ? 10 : 0)
        .onChange(of: dragOffset) { _, offset in
            if offset == .zero, studio.draggingClipID == clip.id { studio.draggingClipID = nil }
        }
        .padding(.vertical, 7)
    }

    private func trimHandle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(studio.selectedClipID == clip.id ? 0.8 : 0.25))
            .frame(width: 5, height: 26)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 3).onEnded { value in
                let delta = studio.snappedBeat(value.translation.width / beatWidth)
                let start = left ? min(clip.endBeat - 0.25, max(clip.startBeat, clip.startBeat + delta)) : clip.startBeat
                let end = left ? clip.endBeat : max(clip.startBeat + 0.25, min(clip.endBeat, clip.endBeat + delta))
                studio.trimClip(clip.id, from: start, to: end)
            })
            .help(left ? "Drag right to trim start" : "Drag left to trim end")
    }
}

private struct MiniPianoRoll: View {
    let notes: [MIDINote]

    var body: some View {
        Canvas { context, size in
            guard let minPitch = notes.map(\.pitch).min(),
                  let maxPitch = notes.map(\.pitch).max(),
                  let maxBeat = notes.map({ $0.startBeat + $0.durationBeats }).max(),
                  maxBeat > 0 else { return }
            let range = max(1, maxPitch - minPitch + 1)
            for note in notes {
                let rect = CGRect(
                    x: note.startBeat / maxBeat * size.width,
                    y: size.height - Double(note.pitch - minPitch + 1) / Double(range) * size.height,
                    width: max(1, note.durationBeats / maxBeat * size.width),
                    height: max(1.5, size.height / Double(range) * 0.7)
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.8)))
            }
        }
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
            inspectorSlider("Reverb", value: $studio.project.tracks[index].effects.reverb, range: 0...1)
            inspectorSlider("Delay", value: $studio.project.tracks[index].effects.delay, range: 0...1)
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
            Slider(value: value, in: range)
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

    private var audioSeconds: Double { Double(studio.generationRequest.bars * 4) * 60 / studio.project.bpm }
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
                    HStack {
                        TextField("From beat", value: $studio.generationRequest.referenceStartBeat, format: .number.precision(.fractionLength(2)))
                        TextField("To beat", value: $studio.generationRequest.referenceEndBeat, format: .number.precision(.fractionLength(2)))
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
                Stepper("Bars: \(studio.generationRequest.bars)", value: $studio.generationRequest.bars, in: 1...32)
                TextField("Key", text: $studio.generationRequest.key)
                if studio.generationRequest.engine == .audio {
                    Text("New audio: \(audioSeconds, specifier: "%.1f") s • input + new audio: \(audioSeconds + referenceSeconds, specifier: "%.1f") / 29 s")
                        .font(.caption)
                        .foregroundStyle(audioSeconds + referenceSeconds > 29 ? Color.red : Color.secondary)
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
                    Text(isReference ? "MusicGen hears this track and improvises a continuation guided by your prompt. It does not repair or faithfully rewrite the original take. Only NEW audio is appended after this track's last clip. 32 kHz mono • model license: noncommercial." : generatorDetail)
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
                    .disabled(studio.generationRequest.engine == .audio && (!generatorReady || !validReference || audioSeconds < 1 || audioSeconds + referenceSeconds > 29))
            }
        }
        .padding(24)
        .frame(width: 680, height: 740)
        .onAppear { if studio.generationRequest.engine == .localNotes { studio.refreshModels() } }
        .onChange(of: studio.generationRequest.engine) { _, engine in
            if engine == .localNotes { studio.refreshModels() }
        }
        .onChange(of: studio.generationRequest.input) { _, input in
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
