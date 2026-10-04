import AppKit
import AVFoundation
import AudioToolbox
import AudioToolbox.AUCocoaUIView
import CoreAudioKit
import Foundation
import SketchSynthDSP

enum InstrumentMode: String, Codable, CaseIterable, Identifiable {
    case builtIn = "Sound library", synth = "Sketch Synth", kick = "Kick Lab", oud = "Oud Lab"
    case violin = "Violin Lab", shaker = "Shaker Lab", audioUnit = "Audio Unit plug-in"
    var id: String { rawValue }
}
enum SynthWaveform: Int, Codable, CaseIterable, Identifiable {
    case sine, saw, square, triangle
    var id: Int { rawValue }
    var title: String { ["Sine", "Saw", "Square", "Triangle"][rawValue] }
}
struct SynthSettings: Codable, Hashable {
    var waveform: SynthWaveform = .saw
    var attack = 0.01
    var decay = 0.2
    var sustain = 0.65
    var release = 0.3
    var cutoff = 4_000.0
    var gain = 0.3
    static func preset(_ name: String) -> Self {
        var s = Self()
        switch name {
        case "Soft pad": s.waveform = .triangle; s.attack = 0.5; s.release = 1.5; s.cutoff = 2_500
        case "Round bass": s.waveform = .square; s.attack = 0.006; s.decay = 0.15; s.sustain = 0.4; s.cutoff = 650
        case "Glass pluck": s.waveform = .sine; s.attack = 0.002; s.decay = 0.7; s.sustain = 0; s.release = 0.15; s.cutoff = 14_000
        default: break
        }
        return s
    }
}
struct KickSettings: Codable, Hashable {
    var tune = 50.0
    var decay = 0.5
    var sweep = 24.0
    var sweepTime = 0.035
    var click = 0.2
    var drive = 0.2
    var gain = 0.45
    static func preset(_ name: String) -> Self {
        switch name {
        case "Deep House": Self(tune: 48, decay: 0.55, sweep: 20, sweepTime: 0.035, click: 0.15, drive: 0.2)
        case "909-inspired": Self(tune: 55, decay: 0.42, sweep: 27, sweepTime: 0.025, click: 0.45, drive: 0.4)
        case "Punch": Self(tune: 62, decay: 0.25, sweep: 32, sweepTime: 0.018, click: 0.7, drive: 0.65)
        case "Sub": Self(tune: 38, decay: 1.1, sweep: 10, sweepTime: 0.065, click: 0, drive: 0.05)
        default: Self()
        }
    }
}
struct OudSettings: Codable, Hashable {
    var pluck = 0.5, warmth = 0.55, decay = 1.2, gain = 0.4
}
struct ViolinSettings: Codable, Hashable {
    var bow = 0.55, tone = 0.5, body = 0.6, vibrato = 0.35
    var attack = 0.09, release = 0.2, gain = 0.4
}
struct ShakerSettings: Codable, Hashable {
    var texture = 0.5, brightness = 0.6, rate = 5.0, decay = 0.16, gain = 0.45
}
struct AudioUnitID: Codable, Hashable, Identifiable {
    var type: UInt32
    var subtype: UInt32
    var manufacturer: UInt32
    var name: String
    var maker: String
    var id: String { "\(type):\(subtype):\(manufacturer)" }
    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
    var isInstrument: Bool { type == kAudioUnitType_MusicDevice }
    // Identity from Surge XT's signed AU bundle, not a display-name match.
    var isSurgeXT: Bool { isInstrument && subtype == 0x53675854 && manufacturer == 0x566D6241 }
    static func installed() -> [AudioUnitID] {
        let query = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        // Component metadata only: do not instantiate every discovered plug-in.
        return AVAudioUnitComponentManager.shared().components(matching: query).map {
            let d = $0.audioComponentDescription
            return AudioUnitID(type: d.componentType, subtype: d.componentSubType,
                               manufacturer: d.componentManufacturer, name: $0.name, maker: $0.manufacturerName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
struct InstrumentConfiguration: Codable, Hashable {
    var mode: InstrumentMode = .builtIn
    var builtIn: KeyboardInstrument = .piano
    var synth = SynthSettings()
    var audioUnit: AudioUnitID?
    var audioUnitState: Data?
    var kick: KickSettings?
    var oud: OudSettings?
    var violin: ViolinSettings?
    var shaker: ShakerSettings?
    var violinSettings: ViolinSettings {
        get { violin ?? ViolinSettings() }
        set { violin = newValue }
    }
    var shakerSettings: ShakerSettings {
        get { shaker ?? ShakerSettings() }
        set { shaker = newValue }
    }
    var oudSettings: OudSettings {
        get { oud ?? OudSettings() }
        set { oud = newValue }
    }
    var kickSettings: KickSettings {
        get { kick ?? KickSettings() }
        set { kick = newValue }
    }
    var name: String {
        switch mode {
        case .builtIn: builtIn.rawValue
        case .synth: "Sketch Synth"
        case .kick: "Kick Lab"
        case .oud: "Oud Lab"
        case .violin: "Violin Lab"
        case .shaker: "Shaker Lab"
        case .audioUnit: audioUnit?.name ?? "Audio Unit"
        }
    }
}

/// Owns the lock-free render state for as long as any node render block uses it.
final class SynthDSPStorage: @unchecked Sendable {
    let handle: SketchSynthRef
    init(sampleRate: Double, settings: SynthSettings) throws {
        guard let pointer = SketchSynthCreate(sampleRate) else { throw StudioError.invalidAudio }
        handle = pointer
        configure(settings)
    }
    func configure(_ s: SynthSettings) {
        SketchSynthConfigure(handle, SketchSynthParameters(waveform: Int32(s.waveform.rawValue),
            attack: Float(s.attack), decay: Float(s.decay), sustain: Float(s.sustain), release: Float(s.release),
            cutoff: Float(s.cutoff), gain: Float(s.gain)))
    }
    deinit { SketchSynthDestroy(handle) }
    func configureOud(_ s: OudSettings) { SketchSynthConfigureOud(handle, Float(s.pluck), Float(s.warmth), Float(s.decay), Float(s.gain)) }
    func configureViolin(_ s: ViolinSettings) {
        SketchSynthConfigureViolin(handle, SketchViolinParameters(bow: Float(s.bow), tone: Float(s.tone),
            body: Float(s.body), vibrato: Float(s.vibrato), attack: Float(s.attack), release: Float(s.release), gain: Float(s.gain)))
    }
    func configureShaker(_ s: ShakerSettings) {
        SketchSynthConfigureShaker(handle, SketchShakerParameters(texture: Float(s.texture), brightness: Float(s.brightness),
            rate: Float(s.rate), decay: Float(s.decay), gain: Float(s.gain)))
    }
    func configureKick(_ s: KickSettings) {
        SketchSynthConfigureKick(handle, SketchKickParameters(tune: Float(s.tune), decay: Float(s.decay),
            sweep: Float(s.sweep), sweepTime: Float(s.sweepTime), click: Float(s.click), drive: Float(s.drive), gain: Float(s.gain)))
    }
}

final class HostedInstrument {
    let node: AVAudioNode
    let unit: AVAudioUnit?
    let synth: SynthDSPStorage?
    private let midi: AUScheduleMIDIEventBlock?
    init(unit: AVAudioUnit) throws {
        guard let midi = unit.auAudioUnit.scheduleMIDIEventBlock else {
            throw MessageError("This Audio Unit does not accept MIDI notes.")
        }
        node = unit; self.unit = unit; self.midi = midi; synth = nil
    }
    init(synth settings: SynthSettings, sampleRate: Double, kick: KickSettings? = nil, oud: OudSettings? = nil,
         violin: ViolinSettings? = nil, shaker: ShakerSettings? = nil) throws {
        let storage = try SynthDSPStorage(sampleRate: sampleRate, settings: settings)
        if let kick { storage.configureKick(kick) }
        if let oud { storage.configureOud(oud) }
        if let violin { storage.configureViolin(violin) }
        if let shaker { storage.configureShaker(shaker) }
        synth = storage; unit = nil; midi = nil
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        node = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return kAudio_ParamError }
            SketchSynthRender(storage.handle, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self), frames)
            return noErr
        }
    }
    func note(_ pitch: UInt8, velocity: UInt8, on: Bool) {
        if let synth { SketchSynthNote(synth.handle, Int32(pitch), Int32(velocity), on ? 1 : 0) }
        else { send([on ? 0x90 : 0x80, pitch, velocity]) }
    }
    func panic() {
        if let synth { SketchSynthPanic(synth.handle) }
        else { send([0xB0, 64, 0]); send([0xB0, 123, 0]); send([0xB0, 120, 0]) }
    }
    private func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { p in midi?(AUEventSampleTimeImmediate, 0, p.count, p.baseAddress!) }
    }
    func snapshot(_ configuration: InstrumentConfiguration) throws -> InstrumentConfiguration {
        var result = configuration
        if configuration.mode == .audioUnit, let unit {
            if let state = unit.auAudioUnit.fullStateForDocument {
                result.audioUnitState = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            } else { result.audioUnitState = nil }
        }
        return result
    }
    static func make(_ configuration: InstrumentConfiguration, sampleRate: Double) async throws -> HostedInstrument {
        switch configuration.mode {
        case .builtIn:
            let sampler = AVAudioUnitSampler()
            try MIDIRenderer.loadInstrument(configuration.builtIn, into: sampler)
            return try HostedInstrument(unit: sampler)
        case .synth:
            return try HostedInstrument(synth: configuration.synth, sampleRate: sampleRate)
        case .kick:
            return try HostedInstrument(synth: SynthSettings(), sampleRate: sampleRate, kick: configuration.kickSettings)
        case .oud:
            return try HostedInstrument(synth: SynthSettings(), sampleRate: sampleRate, oud: configuration.oudSettings)
        case .violin:
            return try HostedInstrument(synth: SynthSettings(), sampleRate: sampleRate, violin: configuration.violinSettings)
        case .shaker:
            return try HostedInstrument(synth: SynthSettings(), sampleRate: sampleRate, shaker: configuration.shakerSettings)
        case .audioUnit:
            guard let id = configuration.audioUnit, id.isInstrument else {
                throw MessageError("Choose an installed Audio Unit instrument first.")
            }
            var description = id.description
            guard AudioComponentFindNext(nil, &description) != nil else {
                throw MessageError("This instrument plug-in is not installed or available for this Mac. Existing recorded clips still play normally.")
            }
            let unit: AVAudioUnit = try await withCheckedThrowingContinuation { continuation in
                AVAudioUnit.instantiate(with: id.description, options: []) { unit, error in
                    if let unit { continuation.resume(returning: unit) }
                    else { continuation.resume(throwing: error ?? MessageError("Could not load \(id.name).")) }
                }
            }
            if let data = configuration.audioUnitState {
                guard let state = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw MessageError("The saved plug-in preset is invalid.")
                }
                unit.auAudioUnit.fullStateForDocument = state
            }
            return try HostedInstrument(unit: unit)
        }
    }
}

@MainActor
final class InstrumentEditorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var recording: RecordingController?
    private var keyMonitor: Any?
    private var heldKeys: [UInt16: Int] = [:]
    private var computerKeys: NSButton?
    var acceptsComputerShortcuts: Bool { computerKeys?.state == .on }

    func close() { stopKeyboard(); window?.close(); window = nil }

    private func releaseKeys() {
        for pitch in heldKeys.values { recording?.noteOff(pitch) }
        heldKeys.removeAll()
    }

    private func stopKeyboard() {
        releaseKeys()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        computerKeys = nil
        recording = nil
    }

    func windowWillClose(_ notification: Notification) { stopKeyboard(); window = nil }
    func windowDidResignKey(_ notification: Notification) { releaseKeys() }
    @objc private func applicationDeactivated(_ notification: Notification) { releaseKeys() }
    @objc private func toggleComputerKeys(_ sender: NSButton) { releaseKeys() }

    static func isEditingText(in window: NSWindow) -> Bool {
        if let text = window.firstResponder as? NSTextView, text.isEditable { return true }
        // JUCE (including Surge) exposes its custom text editors through accessibility,
        // even though its first responder is a single native view for the entire synth.
        let focused = window.firstResponder?.accessibilityFocusedUIElement as? NSAccessibilityProtocol
        guard let role = focused?.accessibilityRole() else { return false }
        return [NSAccessibility.Role.textField, .textArea, .comboBox].contains(role)
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Release the original pitch even if the octave, modifiers or focus changed.
        if event.type == .keyUp, let pitch = heldKeys.removeValue(forKey: event.keyCode) {
            recording?.noteOff(pitch)
            return nil
        }
        guard event.type == .keyDown, let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              computerKeys?.state == .on, let recording, recording.source == .keyboard,
              !recording.isLoadingInstrument, recording.hostedInstrument != nil else { return event }
        if Self.isEditingText(in: window) { releaseKeys(); return event }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        if event.keyCode == 53 { heldKeys.removeAll(); recording.panic(); return nil }
        if let octave = PianoKeyView.octaveShortcut(from: event) {
            if !event.isARepeat { recording.octave = octave }
            return nil
        }
        guard let semitone = PianoKeyView.semitone(from: event) else { return event }
        guard !event.isARepeat, heldKeys[event.keyCode] == nil else { return nil }
        let pitch = (recording.octave + 1) * 12 + semitone
        guard (0..<128).contains(pitch) else { return event }
        heldKeys[event.keyCode] = pitch
        recording.noteOn(pitch)
        return nil
    }
    static func controller(for unit: AVAudioUnit) async -> NSViewController? {
        if let controller = await unit.auAudioUnit.requestViewController() { return controller }
        // AUv2 instruments can publish a Cocoa view factory instead of an AUv3 controller.
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit.audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size >= MemoryLayout<AudioUnitCocoaViewInfo>.size, size < 65_536 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { storage.deallocate() }
        guard AudioUnitGetProperty(unit.audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, storage, &size) == noErr else { return nil }
        let info = storage.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let url = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let names = storage.advanced(by: MemoryLayout<Unmanaged<CFURL>>.stride).assumingMemoryBound(to: Unmanaged<CFString>.self)
        let count = (Int(size) - MemoryLayout<Unmanaged<CFURL>>.stride) / MemoryLayout<Unmanaged<CFString>>.stride
        let classes = (0..<count).map { names[$0].takeRetainedValue() as String }
        guard let bundle = Bundle(url: url), bundle.load() else { return nil }
        for name in classes {
            guard let factoryClass = bundle.classNamed(name) as? NSObject.Type,
                  let factory = factoryClass.init() as? AUCocoaUIBase,
                  let view = factory.uiView(forAudioUnit: unit.audioUnit, with: NSSize(width: 1000, height: 700)) else { continue }
            let controller = NSViewController(); controller.view = view
            return controller
        }
        return nil
    }
    func show(_ controller: NSViewController, title: String, recording: RecordingController) {
        close()
        self.recording = recording
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask.insert([.titled, .closable, .resizable])
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: max(480, controller.view.frame.width, controller.view.fittingSize.width),
                                     height: max(320, controller.view.frame.height, controller.view.fittingSize.height)))
        let toggle = NSButton(checkboxWithTitle: "Computer Keys", target: self, action: #selector(toggleComputerKeys(_:)))
        toggle.state = .on
        toggle.toolTip = "Play the Sketchpad piano while this window is focused. Turn off to use the plug-in's own letter shortcuts."
        let hint = NSTextField(labelWithString: "1–6 octave · Esc release · Text fields stay editable")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [toggle, hint])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        bar.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: 30)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
        computerKeys = toggle
        self.window = window
        window.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated(_:)),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
}
