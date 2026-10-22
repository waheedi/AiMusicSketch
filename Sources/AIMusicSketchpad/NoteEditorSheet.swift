import SwiftUI

struct NoteEditorSheet: View {
    @ObservedObject var studio: StudioModel
    let clip: ClipModel
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [MIDINote]
    @State private var selected = Set<UUID>()
    @State private var drawMode = false
    @State private var beats: Double
    @State private var zoom = 56.0
    @GestureState private var selectionRect: CGRect?
    @State private var newLength = 0.5
    @State private var errorMessage: String?
    private let rowHeight = 20.0
    private var displayedBeats: Double { ceil(max(16, beats + 4) / 4) * 4 }
    private var beatWidth: Double { min(zoom, 24_000 / displayedBeats) }
    private var gridWidth: Double { max(680, displayedBeats * beatWidth) }

    init(studio: StudioModel, clip: ClipModel) {
        self.studio = studio; self.clip = clip
        _notes = State(initialValue: clip.midiNotes ?? [])
        _beats = State(initialValue: clip.sourceDurationSeconds * (clip.midiSourceBPM ?? studio.project.bpm) / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Notes · \(clip.name)").font(.title2.bold())
            Text(drawMode ? "Click empty space to draw a note. Drawing past the pattern end extends it."
                 : "⌘/Shift-click or drag a box to select notes. Delete removes them. Double-click empty space to add.")
                .font(.callout)
            Text("Editing this clip’s source pattern, including its loop repeats. Apply rebuilds audio from the take’s starting preset; live knob movements are not retained.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Tool", selection: $drawMode) {
                    Label("Select", systemImage: "cursorarrow").tag(false)
                    Label("Draw", systemImage: "pencil").tag(true)
                }.pickerStyle(.segmented).frame(width: 155)
                Picker("New note length", selection: $newLength) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { length in
                        Text("\(length, specifier: "%g") beats").tag(length)
                    }
                }.frame(width: 210)
                Button("Select All") { selected = Set(notes.map(\.id)) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Delete \(selected.count)", role: .destructive, action: deleteSelection)
                    .keyboardShortcut(.delete, modifiers: []).disabled(selected.isEmpty)
                Spacer()
                Image(systemName: "magnifyingglass")
                Slider(value: $zoom, in: 24...112).frame(width: 90).help("Horizontal zoom")
            }.disabled(studio.isBusy)
            ScrollViewReader { scroll in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach((0...127).reversed(), id: \.self) { pitch in
                                noteRow(pitch).id(pitch)
                            }
                        } header: {
                            HStack(spacing: 0) {
                                Text("Pitch").frame(width: 44)
                                Canvas { context, size in
                                    for beat in stride(from: 0.0, through: displayedBeats, by: max(1, ceil(displayedBeats / 500))) {
                                        context.draw(Text("\(beat, specifier: "%g")").font(.caption2),
                                                     at: CGPoint(x: beat * beatWidth + 3, y: 10), anchor: .leading)
                                    }
                                }
                                .frame(width: gridWidth, height: 22)
                            }.font(.caption).background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .coordinateSpace(name: "noteGrid")
                    .overlay(alignment: .topLeading) {
                        if let rect = selectionRect {
                            Rectangle().fill(Color.accentColor.opacity(0.18))
                                .overlay(Rectangle().stroke(Color.accentColor))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("noteGrid"))
                        .updating($selectionRect) { value, state, _ in
                            guard !drawMode, value.startLocation.x >= 44, value.startLocation.y >= 22 else { return }
                            state = selectionBox(value)
                        }
                        .onEnded { value in
                            guard !drawMode, value.startLocation.x >= 44, value.startLocation.y >= 22 else { return }
                            let box = selectionBox(value)
                            let ids = Set(notes.filter { note in
                                box.intersects(CGRect(x: 44 + note.startBeat * beatWidth, y: 22 + Double(127 - note.pitch) * rowHeight + 2,
                                                      width: max(3, note.durationBeats * beatWidth), height: rowHeight - 4))
                            }.map(\.id))
                            selected = extendingSelection ? selected.union(ids) : ids
                        })
                }
                .frame(height: 360)
                .background(Color(nsColor: .textBackgroundColor))
                .disabled(studio.isBusy)
                .onAppear { scroll.scrollTo(min(127, (notes.map(\.pitch).max() ?? 72) + 3), anchor: .topLeading) }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(studio.isBusy)
                Spacer()
                if studio.isBusy { ProgressView().controlSize(.small); Text("Updating audio…").font(.caption) }
                Button("Apply") {
                    Task {
                        do { try await studio.applyNotes(notes, to: clip.id, durationBeats: beats); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(studio.editingLocked || notes == clip.midiNotes)
            }
        }
        .padding(20).frame(width: 860)
        .interactiveDismissDisabled(studio.isBusy)
    }

    private func noteRow(_ pitch: Int) -> some View {
        let rowNotes = notes.filter { $0.pitch == pitch }
        let black = [1, 3, 6, 8, 10].contains(pitch % 12)
        return HStack(spacing: 0) {
            Text(["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][pitch % 12] + String(pitch / 12 - 1))
                .font(.caption2.monospaced()).frame(width: 44, height: rowHeight)
                .background(Color.secondary.opacity(black ? 0.22 : 0.08))
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(black ? 0.10 : 0.03)))
                context.fill(Path(CGRect(x: beats * beatWidth, y: 0, width: max(0, size.width - beats * beatWidth), height: size.height)),
                             with: .color(.secondary.opacity(0.12)))
                for beat in stride(from: 0.0, through: displayedBeats, by: max(1, ceil(displayedBeats / 500))) {
                    var line = Path()
                    line.move(to: CGPoint(x: beat * beatWidth, y: 0))
                    line.addLine(to: CGPoint(x: beat * beatWidth, y: rowHeight))
                    context.stroke(line, with: .color(.secondary.opacity(Int(beat).isMultiple(of: 4) ? 0.4 : 0.2)), lineWidth: 0.5)
                }
                for note in rowNotes {
                    let rect = CGRect(x: note.startBeat * beatWidth, y: 2,
                                      width: max(3, note.durationBeats * beatWidth), height: rowHeight - 4)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(selected.contains(note.id) ? .orange : .purple))
                }
            }
            .frame(width: gridWidth, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture())
                .onEnded { result in
                    switch result {
                    case .first(let tap): tapRow(pitch, x: tap.location.x, add: true)
                    case .second(let tap): tapRow(pitch, x: tap.location.x, add: drawMode)
                    }
                })
        }
    }
    private func tapRow(_ pitch: Int, x: Double, add: Bool) {
        if let hit = notes.last(where: { $0.pitch == pitch && x >= $0.startBeat * beatWidth
            && x <= $0.startBeat * beatWidth + max(3, $0.durationBeats * beatWidth) }) {
            if extendingSelection {
                if !selected.insert(hit.id).inserted { selected.remove(hit.id) }
            } else { selected = [hit.id] }
        } else if add {
            let start = floor(max(0, x / beatWidth) * 4) / 4
            let end = start + newLength
            let extended = end > beats ? ceil(end / 4) * 4 : beats
            guard extended * 60 / (clip.midiSourceBPM ?? studio.project.bpm) < 3_600 else {
                errorMessage = "A note pattern must be shorter than one hour."; return
            }
            beats = extended
            let note = MIDINote(pitch: pitch, velocity: 0.8, startBeat: start, durationBeats: newLength)
            notes.append(note); selected = [note.id]
            errorMessage = nil
        } else if !extendingSelection { selected = [] }
    }
    private var extendingSelection: Bool { !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty }
    private func selectionBox(_ value: DragGesture.Value) -> CGRect {
        CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
               width: abs(value.translation.width), height: abs(value.translation.height))
    }
    private func deleteSelection() {
        notes.removeAll { selected.contains($0.id) }
        selected = []
    }
}
