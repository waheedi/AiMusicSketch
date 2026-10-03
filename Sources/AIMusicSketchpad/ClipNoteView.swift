import SwiftUI

/// Read-only piano-roll preview: the full clip time is the horizontal scale,
/// with stable semitone rows from the original take (not just visible notes).
struct ClipNoteView: View {
    let clip: ClipModel
    let bpm: Double

    var body: some View {
        let notes = ClipNoteLayout.notes(for: clip, bpm: bpm)
        let range = ClipNoteLayout.pitchRange(for: clip)
        let duration = clip.durationBeats * 60 / bpm
        Canvas { context, size in
            guard duration > 0, duration.isFinite else { return }
            let rowHeight = size.height / Double(range.count)
            for pitch in range {
                let y = Double(range.upperBound - pitch) * rowHeight
                if [1, 3, 6, 8, 10].contains(pitch % 12) {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)),
                                 with: .color(.black.opacity(0.14)))
                }
                if pitch % 12 == 0 {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y + rowHeight))
                    line.addLine(to: CGPoint(x: size.width, y: y + rowHeight))
                    context.stroke(line, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                    if rowHeight >= 10 {
                        context.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 8)).foregroundColor(.white.opacity(0.55)),
                                     at: CGPoint(x: 3, y: y), anchor: .topLeading)
                    }
                }
            }
            for note in notes {
                let x = note.startSeconds / duration * size.width
                let width = min(size.width - x, max(1, note.durationSeconds / duration * size.width))
                let y = Double(range.upperBound - note.pitch) * rowHeight
                let rect = CGRect(x: x, y: y + min(0.6, rowHeight * 0.1), width: width,
                                  height: max(0.5, rowHeight * 0.8))
                context.fill(Path(roundedRect: rect, cornerRadius: min(1, rowHeight / 4)),
                             with: .color(.white.opacity(0.45 + 0.5 * note.velocity)))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityLabel("Recorded notes; horizontal position is time, vertical position is pitch")
    }
}
