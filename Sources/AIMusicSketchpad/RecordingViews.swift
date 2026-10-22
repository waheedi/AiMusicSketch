import AppKit
import SwiftUI

struct RecordingPanel: View {
    @ObservedObject var studio: StudioModel
    @State private var focusToken = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(studio.project.tracks.first(where: { $0.id == studio.selectedTrackID })?.name ?? "Select track", systemImage: "record.circle")
                    .font(.headline)
                Picker("Input", selection: Binding(get: { studio.recording.source }, set: { studio.recording.source = $0 })) {
                    ForEach(RecordingSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 290)
                .disabled(studio.editingLocked)
                Spacer()
                Button(action: studio.toggleRecording) {
                    Label(studio.recording.isRecording ? "Stop & Save Take" : "Record Track",
                          systemImage: studio.recording.isRecording ? "stop.fill" : "record.circle.fill")
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(!studio.canToggleRecording)
                .help("R: record / stop and save take")
                Button {
                    studio.recording.panic()
                    studio.showRecordingPanel = false
                } label: { Image(systemName: "xmark") }
                .disabled(studio.editingLocked)
            }
            if studio.recording.source == .keyboard {
                InstrumentControls(studio: studio)
                HStack {
                    Text("Click keys • A W S E D F T G Y H U J K L Ö Ä # • 1–6 octave • Esc releases")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Octave \(studio.recording.octave)", value: Binding(get: { studio.recording.octave }, set: { studio.recording.octave = $0 }), in: 1...6)
                        .frame(width: 125)
                    Spacer()
                    Text(studio.recording.midiStatus).font(.caption).lineLimit(1)
                    Button("Refresh MIDI") { studio.recording.refreshMIDI() }
                }
                PianoKeyboard(recording: studio.recording, focusToken: focusToken)
                    .frame(height: 100)
                if studio.recording.configuration.mode == .builtIn && studio.recording.instrument.isOriginalKit {
                    Text("\(studio.recording.instrument.rawValue) • \(studio.recording.octave): \(studio.recording.instrument.bankNames[studio.recording.octave - 1]) • " + studio.recording.instrument.bankNames.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                } else if studio.recording.configuration.mode == .builtIn && studio.recording.instrument.isElectronicDrumKit {
                    Text("Drum sounds use octaves 2–3 (MIDI 36–58). Unassigned keys are silent; drums do not repeat across every octave.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Uses your macOS default audio input. Use headphones while recording alongside other tracks.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    InputLevelMeter(recording: studio.recording).frame(width: 160)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { if studio.recording.source == .keyboard { studio.prepareKeyboard() } }
        .onChange(of: studio.recording.source) { _, source in
            studio.recording.panic()
            if source == .keyboard { studio.prepareKeyboard(); focusToken += 1 }
        }
        .onChange(of: studio.recording.isRecording) { _, recording in
            if recording { focusToken += 1 }
        }
    }
}

private struct InputLevelMeter: View {
    @ObservedObject var recording: RecordingController
    var body: some View { ProgressView(value: Double(recording.inputLevel), total: 1) }
}

private struct PianoKeyboard: NSViewRepresentable {
    @ObservedObject var recording: RecordingController
    let focusToken: Int
    func makeNSView(context: Context) -> PianoKeyView {
        let view = PianoKeyView()
        view.recording = recording
        return view
    }
    func updateNSView(_ view: PianoKeyView, context: Context) {
        view.recording = recording
        view.needsDisplay = true
        if view.focusToken != focusToken {
            view.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
    static func dismantleNSView(_ view: PianoKeyView, coordinator: ()) { view.releaseKeys() }
}

final class PianoKeyView: NSView {
    weak var recording: RecordingController?
    var focusToken = 0
    private(set) var held: [UInt16: Int] = [:]
    private var mousePitch: Int?
    private static let keyCodes: [UInt16] = [0, 13, 1, 14, 2, 3, 17, 5, 16, 4, 32, 38, 40, 37, 41, 39, 42]
    private let labels = ["A", "W", "S", "E", "D", "F", "T", "G", "Y", "H", "U", "J", "K", "L", "Ö", "Ä", "#"]
    private let whites = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16]
    private let blacks = [1, 3, 6, 8, 10, 13, 15]
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    private func rect(_ semitone: Int) -> NSRect {
        let width = bounds.width / Double(whites.count)
        if let index = whites.firstIndex(of: semitone) {
            return NSRect(x: Double(index) * width + 1, y: 1, width: width - 2, height: bounds.height - 2)
        }
        let position = whites.filter { $0 < semitone }.count
        return NSRect(x: Double(position) * width - width * 0.29, y: 1, width: width * 0.58, height: bounds.height * 0.62)
    }
    override func draw(_ dirtyRect: NSRect) {
        let base = ((recording?.octave ?? 4) + 1) * 12
        for semitone in whites + blacks {
            let black = blacks.contains(semitone)
            let active = recording?.activePitches.contains(base + semitone) == true
            (active ? NSColor.systemPurple : black ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            let shape = NSBezierPath(roundedRect: rect(semitone), xRadius: 4, yRadius: 4)
            shape.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: black || active ? NSColor.white : NSColor.darkGray
            ]
            let area = rect(semitone)
            (labels[semitone] as NSString).draw(at: NSPoint(x: area.midX - 4, y: area.maxY - 20), withAttributes: attributes)
            if recording?.configuration.mode == .builtIn && recording?.instrument.isOriginalKit == true {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byTruncatingTail
                var soundAttributes = attributes
                soundAttributes[.font] = NSFont.systemFont(ofSize: 9)
                soundAttributes[.paragraphStyle] = paragraph
                ((recording?.instrument == .aurora ? AuroraKit.label(for: base + semitone) : SignatureKit.label(for: base + semitone)) as NSString).draw(
                    in: NSRect(x: area.minX + 2, y: area.maxY - 38, width: area.width - 4, height: 14),
                    withAttributes: soundAttributes)
            }
        }
        if window?.firstResponder === self {
            NSColor.systemPurple.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { releaseKeys(); needsDisplay = true; return true }
    static func octaveShortcut(from event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.characters, characters.count == 1,
              let octave = Int(characters), (1...6).contains(octave) else { return nil }
        return octave
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { recording?.panic(); held.removeAll(); return }
        if let octave = Self.octaveShortcut(from: event) {
            if !event.isARepeat { recording?.octave = octave; needsDisplay = true }
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        guard let semitone = Self.semitone(from: event) else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        let pitch = ((recording?.octave ?? 4) + 1) * 12 + semitone
        held[event.keyCode] = pitch
        recording?.noteOn(pitch)
    }
    static func semitone(from event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let extra = ["l": 13, "ö": 14, "ä": 15, "#": 16]
        if let text = event.charactersIgnoringModifiers?.lowercased(), let note = extra[text] { return note }
        return keyCodes.firstIndex(of: event.keyCode)
    }
    override func keyUp(with event: NSEvent) {
        if let pitch = held.removeValue(forKey: event.keyCode) { recording?.noteOff(pitch) }
        else { super.keyUp(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let semitone = (blacks + whites).first(where: { rect($0).contains(point) }) else { return }
        let pitch = ((recording?.octave ?? 4) + 1) * 12 + semitone
        mousePitch = pitch
        recording?.noteOn(pitch)
    }
    override func mouseUp(with event: NSEvent) {
        if let pitch = mousePitch { recording?.noteOff(pitch) }
        mousePitch = nil
    }
    func releaseKeys() {
        for pitch in held.values { recording?.noteOff(pitch) }
        held.removeAll()
        if let pitch = mousePitch { recording?.noteOff(pitch) }
        mousePitch = nil
    }
}
