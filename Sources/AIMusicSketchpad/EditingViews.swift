import SwiftUI

struct ClipContextMenu: View {
    @ObservedObject var studio: StudioModel
    let trackID: UUID
    let clip: ClipModel
    var body: some View {
        if clip.notesEditable == true {
            Button("Edit Notes…") { studio.editNotes(clip.id) }
            Divider()
        }
        Button("Copy Clip") { studio.copyClip(clip.id) }
        Button("Duplicate After This Clip") { studio.duplicateClip(clip.id) }
        Button("AI • Improvise from this clip…") { studio.beginGeneration(trackID: trackID, clipID: clip.id, useTrack: true) }
        Divider()
        Button("Loop ×2") { studio.loopClip(clip.id, times: 2) }
        Button("Loop ×4") { studio.loopClip(clip.id, times: 4) }
        if clip.loopEnabled { Button("Stop looping") { studio.stopLooping(clip.id) } }
        Divider()
        Button("Trim…") { studio.trimClipID = clip.id }
        Button("Trim start to playhead") {
            studio.trimClip(clip.id, from: studio.snappedBeat(studio.audio.currentBeat), to: clip.endBeat)
        }
        .disabled(studio.audio.currentBeat <= clip.startBeat || studio.audio.currentBeat >= clip.endBeat)
        Button("Trim end to playhead") {
            studio.trimClip(clip.id, from: clip.startBeat, to: studio.snappedBeat(studio.audio.currentBeat))
        }
        .disabled(studio.audio.currentBeat <= clip.startBeat || studio.audio.currentBeat >= clip.endBeat)
        Button("Split at playhead") {
            studio.selectClip(trackID: trackID, clipID: clip.id)
            studio.splitSelectedClip()
        }
        Divider()
        Button("Delete clip", role: .destructive) {
            studio.selectClip(trackID: trackID, clipID: clip.id)
            studio.deleteSelectedClip()
        }
    }
}

struct TrimSheet: View {
    @ObservedObject var studio: StudioModel
    let clip: ClipModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = 0.0
    @State private var end = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trim \(clip.name)").font(.title2.bold())
            Text("Keep a range inside this clip. The source audio file stays intact.")
                .foregroundStyle(.secondary)
            HStack {
                Text("Start beat")
                TextField("Start", value: $start, format: .number.precision(.fractionLength(2)))
                Text("End beat")
                TextField("End", value: $end, format: .number.precision(.fractionLength(2)))
            }
            .textFieldStyle(.roundedBorder)
            Slider(value: $start, in: clip.startBeat...clip.endBeat, step: 0.25)
            Slider(value: $end, in: clip.startBeat...clip.endBeat, step: 0.25)
            Text("Kept length: \(max(0, end - start), format: .number.precision(.fractionLength(2))) beats")
                .font(.caption)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Trim") {
                    studio.trimClip(clip.id, from: start, to: end)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!start.isFinite || !end.isFinite || start < clip.startBeat || end > clip.endBeat || end - start < 0.0625)
            }
        }
        .padding(24)
        .frame(width: 510)
        .onAppear { start = clip.startBeat; end = clip.endBeat }
    }
}
