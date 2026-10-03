import SwiftUI

struct NoteEditorSheet: View {
    @ObservedObject var studio: StudioModel
    let clip: ClipModel
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [MIDINote]
    @State private var selected: UUID?
    @State private var newLength = 0.5
    @State private var errorMessage: String?
    private let rowHeight = 20.0
    private var beats: Double { clip.sourceDurationSeconds * (clip.midiSourceBPM ?? studio.project.bpm) / 60 }
    private var beatWidth: Double { min(56, 24_000 / max(1, beats)) }
    private var gridWidth: Double { max(680, beats * beatWidth) }

    init(studio: StudioModel, clip: ClipModel) {
        self.studio = studio; self.clip = clip
        _notes = State(initialValue: clip.midiNotes ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Notes · \(clip.name)").font(.title2.bold())
            Text("Click a note, then Delete. Double-click empty space to add a note (¼-beat snap).")
                .font(.callout)
            Text("Editing this clip’s source pattern, including its loop repeats. Apply rebuilds audio from the take’s starting preset; live knob movements are not retained.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("New note length", selection: $newLength) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { length in
                        Text("\(length, specifier: "%g") beats").tag(length)
                    }
                }.frame(width: 230)
                Button("Delete Note", role: .destructive, action: deleteSelection)
                    .keyboardShortcut(.delete, modifiers: []).disabled(selected == nil)
                Spacer()
                Text("\(notes.count) notes").font(.caption).monospacedDigit()
            }.disabled(studio.isBusy)
            ScrollViewReader { scroll in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Pitch").frame(width: 44)
                            Canvas { context, size in
                                for beat in stride(from: 0.0, through: beats, by: max(1, ceil(beats / 500))) {
                                    context.draw(Text("\(beat, specifier: "%g")").font(.caption2),
                                                 at: CGPoint(x: beat * beatWidth + 3, y: 10), anchor: .leading)
                                }
                            }.frame(width: gridWidth, height: 22)
                        }.font(.caption)
                        ForEach((0...127).reversed(), id: \.self) { pitch in
                            noteRow(pitch).id(pitch)
                        }
                    }
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
                        do { try await studio.applyNotes(notes, to: clip.id); dismiss() }
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
                for beat in stride(from: 0.0, through: beats, by: max(1, ceil(beats / 500))) {
                    var line = Path()
                    line.move(to: CGPoint(x: beat * beatWidth, y: 0))
                    line.addLine(to: CGPoint(x: beat * beatWidth, y: rowHeight))
                    context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
                }
                for note in rowNotes {
                    let rect = CGRect(x: note.startBeat * beatWidth, y: 2,
                                      width: max(3, note.durationBeats * beatWidth), height: rowHeight - 4)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(note.id == selected ? .orange : .purple))
                }
            }
            .frame(width: gridWidth, height: rowHeight)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture())
                .onEnded { result in
                    switch result {
                    case .first(let tap): tapRow(pitch, x: tap.location.x, add: true)
                    case .second(let tap): tapRow(pitch, x: tap.location.x, add: false)
                    }
                })
        }
    }
    private func tapRow(_ pitch: Int, x: Double, add: Bool) {
        if let hit = notes.last(where: { $0.pitch == pitch && x >= $0.startBeat * beatWidth
            && x <= $0.startBeat * beatWidth + max(3, $0.durationBeats * beatWidth) }) {
            selected = hit.id
        } else if add {
            let start = floor(max(0, x / beatWidth) * 4) / 4
            guard start < beats else { return }
            let note = MIDINote(pitch: pitch, velocity: 0.8, startBeat: start, durationBeats: min(newLength, beats - start))
            notes.append(note); selected = note.id
        } else { selected = nil }
    }
    private func deleteSelection() {
        guard let selected else { return }
        notes.removeAll { $0.id == selected }
        self.selected = nil
    }
}
