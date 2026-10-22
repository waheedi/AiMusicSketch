import AVFoundation
import Foundation

enum SurgePatchBank {
    struct Preset: Identifiable {
        let name: String
        let octave: Int
        let file: String
        var id: String { file }
    }
    static let presets = [
        Preset(name: "Deep Pulse Kick", octave: 2, file: "01 Deep Pulse Kick"),
        Preset(name: "Round Sub", octave: 2, file: "02 Round Sub"),
        Preset(name: "Rolling Harmonic Bass", octave: 2, file: "03 Rolling Harmonic Bass"),
        Preset(name: "Resonant Pulse Pluck", octave: 4, file: "04 Resonant Pulse Pluck"),
        Preset(name: "Metal Tick", octave: 4, file: "05 Metal Tick"),
        Preset(name: "Air Shaker", octave: 4, file: "06 Air Shaker")
    ]
    static var resourceDirectory: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("SketchpadPulse")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/SketchpadPulse")
    }
    static func configuration(for preset: Preset) throws -> InstrumentConfiguration {
        guard let id = AudioUnitID.installed().first(where: \.isSurgeXT) else {
            throw MessageError("Install Surge XT's Audio Unit first to play Sketchpad Pulse.")
        }
        let data = try Data(contentsOf: resourceDirectory.appendingPathComponent(preset.file + ".fxp"))
        guard data.count > 92, data.prefix(4) == Data("CcnK".utf8),
              data[60..<64] == Data("sub3".utf8) else { throw MessageError("The bundled Surge patch is invalid.") }
        // Surge's JUCE AU state uses the raw patch chunk, without the FXP wrapper.
        let state: [String: Any] = ["version": 0, "type": id.type, "subtype": id.subtype,
            "manufacturer": id.manufacturer, "name": preset.name, "jucePluginState": Data(data.dropFirst(60))]
        return InstrumentConfiguration(mode: .audioUnit, audioUnit: id,
            audioUnitState: try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0))
    }
    @discardableResult static func installInSurge() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Surge XT/Patches/Sketchpad Pulse", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for preset in presets {
            let destination = directory.appendingPathComponent(preset.file + ".fxp")
            // User edits to an installed patch must never be replaced by an update.
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: resourceDirectory.appendingPathComponent(preset.file + ".fxp"), to: destination)
            }
        }
        return directory
    }
}
