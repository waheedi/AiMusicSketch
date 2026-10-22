import AppKit
import SwiftUI

enum StudioKeyAction {
    case record, zoomIn, zoomOut, deleteClips, selectAllClips

    static func action(for event: NSEvent) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers.isEmpty && key == "r" { return .record }
        if modifiers.isEmpty && [51, 117].contains(event.keyCode) { return .deleteClips }
        if modifiers == .command && key == "a" { return .selectAllClips }
        if modifiers == .command || modifiers == [.command, .shift] {
            if key == "+" || key == "=" { return .zoomIn }
            if key == "-" { return .zoomOut }
        }
        return nil
    }
}

// App-local shortcuts: typing in names, numbers and plug-in searches stays untouched.
struct StudioShortcuts: NSViewRepresentable {
    let studio: StudioModel
    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.studio = studio
        return view
    }
    func updateNSView(_ view: ShortcutView, context: Context) { view.studio = studio }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        weak var studio: StudioModel?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let studio = self.studio, let target = event.window,
                      let action = StudioKeyAction.action(for: event),
                      NSApp.modalWindow == nil, target.attachedSheet == nil,
                      !studio.showGenerateSheet, studio.trimClipID == nil, studio.noteEditClipID == nil,
                      !InstrumentEditorWindow.isEditingText(in: target) else { return event }
                let isMain = target === self.window
                let isPlayableEditor = (target.delegate as? InstrumentEditorWindow)?.acceptsComputerShortcuts == true
                guard isMain || (action == .record && isPlayableEditor) else { return event }
                guard !event.isARepeat else { return nil }
                switch action {
                case .record: studio.toggleRecording()
                case .zoomIn: studio.zoomTimeline(inward: true)
                case .zoomOut: studio.zoomTimeline(inward: false)
                case .deleteClips: studio.deleteSelection()
                case .selectAllClips: studio.selectAll()
                }
                return nil
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
