import SwiftUI

@main
struct AIMusicSketchpadApp: App {
    @StateObject private var studio = StudioModel()

    var body: some Scene {
        WindowGroup("AI Music Sketchpad") {
            ContentView()
                .environmentObject(studio)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { studio.copyCommand() }.keyboardShortcut("c")
                Button("Paste") { studio.pasteCommand() }.keyboardShortcut("v")
                Button("Duplicate Clip") { if let id = studio.selectedClipID { studio.duplicateClip(id) } }
                    .keyboardShortcut("d").disabled(studio.selectedClipID == nil || studio.editingLocked)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { studio.newProject() }
                    .keyboardShortcut("n")
                Button("Open…") { studio.openProject() }
                    .keyboardShortcut("o")
                Button("Save…") { studio.saveProject() }
                    .keyboardShortcut("s")
            }
            CommandMenu("Studio") {
                Button("Import Audio…") { studio.importAudio() }
                    .keyboardShortcut("i")
                Button("Generate Audio…") { studio.beginGeneration() }
                    .keyboardShortcut("g")
                    .disabled(studio.editingLocked)
                Button("Recording Controls") { studio.showRecordingPanel = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(studio.audio.isPlaying ? "Stop" : "Play") { studio.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Export Mix…") { studio.exportMix() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}
