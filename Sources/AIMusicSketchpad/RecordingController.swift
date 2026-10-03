import AppKit
import AVFoundation
import CoreMIDI
import Foundation

struct NoteCapture {
    private(set) var notes: [MIDINote] = []
    private var held: [UInt8: (beat: Double, velocity: UInt8)] = [:]
    mutating func on(_ pitch: UInt8, velocity: UInt8, beat: Double) {
        off(pitch, beat: beat)
        held[pitch] = (max(0, beat), velocity)
    }
    mutating func off(_ pitch: UInt8, beat: Double) {
        guard let start = held.removeValue(forKey: pitch) else { return }
        notes.append(MIDINote(pitch: Int(pitch), velocity: Double(start.velocity) / 127,
                             startBeat: start.beat, durationBeats: max(0.01, beat - start.beat)))
    }
    mutating func finish(at beat: Double) -> [MIDINote] {
        for pitch in Array(held.keys) { off(pitch, beat: beat) }
        return notes.sorted { $0.startBeat < $1.startBeat }
    }
}

struct RecordedTake {
    let url: URL?
    let notes: [MIDINote]
    let durationBeats: Double
    let instrument: KeyboardInstrument
    var addOn: InstrumentConfiguration? = nil
}

@MainActor
final class RecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var source: RecordingSource = .microphone
    @Published var configuration = InstrumentConfiguration()
    var instrument: KeyboardInstrument {
        get { configuration.builtIn }
        set { configuration.builtIn = newValue }
    }
    @Published private(set) var isLoadingInstrument = false
    @Published private(set) var installedAudioUnits: [AudioUnitID] = []
    @Published var instrumentMessage = ""
    @Published var octave = 4
    @Published private(set) var isRecording = false
    @Published private(set) var activePitches = Set<Int>()
    @Published private(set) var midiStatus = "Connect a MIDI keyboard, then press Refresh."
    @Published private(set) var inputLevel: Float = 0
    var onFailure: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var engine: AVAudioEngine?
    private(set) var hostedInstrument: HostedInstrument?
    private var loadedConfiguration: InstrumentConfiguration?
    private var loadRevision = 0
    private var instrumentCapture: InstrumentAudioCapture?
    private var recordingAddOn: InstrumentConfiguration?
    private let editorWindow = InstrumentEditorWindow()
    private var midiClient = MIDIClientRef()
    private var midiPort = MIDIPortRef()
    private var connectedSources = Set<MIDIEndpointRef>()
    private var capture = NoteCapture()
    private var anchor: UInt64 = 0
    private var bpm = 120.0
    private var recordingSource: RecordingSource = .microphone
    private var recordingInstrument: KeyboardInstrument = .piano
    private var meterTask: Task<Void, Never>?
    private var sustaining = false
    private var sustained = Set<UInt8>()

    func prepare(sampleRate: Double) async throws {
        if source == .microphone {
            let permitted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: permitted = true
            case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .audio)
            default: permitted = false
            }
            guard permitted else {
                throw MessageError("Allow microphone access for AI Music Sketchpad in System Settings → Privacy & Security → Microphone.")
            }
            let url = AssetManager.shared.newAssetURL(prefix: "Microphone-take")
                .deletingPathExtension().appendingPathExtension("caf")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true
            ])
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else { throw MessageError("The current audio input could not be opened.") }
            self.recorder = recorder
        } else {
            try await prepareKeyboard()
        }
    }

    func begin(anchor: UInt64, bpm: Double) throws {
        panic()
        self.anchor = anchor
        self.bpm = bpm
        recordingSource = source
        recordingInstrument = instrument
        recordingAddOn = source != .keyboard || configuration.mode == .builtIn ? nil : try snapshotConfiguration()
        capture = NoteCapture()
        if source == .microphone {
            guard let recorder else { throw MessageError("Microphone was not prepared.") }
            let now = mach_absolute_time()
            let delay = anchor > now ? AVAudioTime.seconds(forHostTime: anchor - now) : 0
            guard recorder.record(atTime: recorder.deviceCurrentTime + delay) else {
                throw MessageError("The audio input did not start recording.")
            }
        } else if configuration.mode != .builtIn {
            guard let engine else { throw MessageError("Instrument was not prepared.") }
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            let url = AssetManager.shared.newAssetURL(prefix: "Instrument-take").deletingPathExtension().appendingPathExtension("caf")
            let sink = try InstrumentAudioCapture(url: url, format: format, anchor: anchor)
            instrumentCapture = sink
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, time in sink.append(buffer, time: time) }
        }
        isRecording = true
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self, self.isRecording else { return }
                self.recorder?.updateMeters()
                if let recorder = self.recorder { self.inputLevel = pow(10, recorder.averagePower(forChannel: 0) / 20) }
            }
        }
    }

    func finish() throws -> RecordedTake {
        let durationBeats = max(0.01, relativeBeat())
        let notes = capture.finish(at: durationBeats)
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
        inputLevel = 0
        panic()
        var url = recorder?.url
        recorder?.stop()
        recorder = nil
        if let sink = instrumentCapture {
            engine?.mainMixerNode.removeTap(onBus: 0)
            instrumentCapture = nil
            try sink.finish()
            url = sink.url
        }
        if recordingSource == .keyboard, notes.isEmpty {
            throw MessageError("No notes were played. Click the keyboard to focus it, or connect a MIDI keyboard, then record again.")
        }
        return RecordedTake(url: url, notes: notes, durationBeats: durationBeats,
                            instrument: recordingInstrument, addOn: recordingAddOn)
    }

    func cancelPreparation() {
        recorder?.stop()
        recorder = nil
        if instrumentCapture != nil { engine?.mainMixerNode.removeTap(onBus: 0); instrumentCapture = nil }
    }

    func prepareKeyboard() async throws {
        guard !isRecording else { return }
        let requested = configuration
        if let loaded = loadedConfiguration, loaded == requested, let engine {
            if !engine.isRunning { try engine.start() }
            return
        }
        loadRevision += 1
        let revision = loadRevision
        isLoadingInstrument = true
        defer { if revision == loadRevision { isLoadingInstrument = false } }
        panic(); editorWindow.close()
        engine?.stop(); engine = nil; hostedInstrument = nil; loadedConfiguration = nil
        instrumentMessage = "Loading \(requested.name)…"
        let hosted: HostedInstrument
        if requested.mode == .builtIn { hosted = try HostedInstrument(unit: AVAudioUnitSampler()) }
        else { hosted = try await HostedInstrument.make(requested, sampleRate: 48_000) }
        guard revision == loadRevision else { throw CancellationError() }
        let next = AVAudioEngine()
        next.attach(hosted.node)
        let format = hosted.synth == nil ? nil : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        next.connect(hosted.node, to: next.mainMixerNode, format: format)
        // EXS sample instruments require the sampler to belong to an engine.
        if requested.mode == .builtIn, let sampler = hosted.node as? AVAudioUnitSampler {
            try MIDIRenderer.loadInstrument(requested.builtIn, into: sampler)
        }
        next.mainMixerNode.outputVolume = 0.65
        try next.start()
        engine = next; hostedInstrument = hosted; loadedConfiguration = requested
        instrumentMessage = "\(requested.name) ready"
        refreshMIDI()
    }

    func refreshAudioUnits() { installedAudioUnits = AudioUnitID.installed() }
    func unloadKeyboard() {
        guard !isRecording else { return }
        loadRevision += 1; isLoadingInstrument = false
        panic(); editorWindow.close(); engine?.stop()
        engine = nil; hostedInstrument = nil; loadedConfiguration = nil
        instrumentMessage = "Choose an installed instrument."
    }
    func applySynthSettings() {
        if configuration.mode == .kick { hostedInstrument?.synth?.configureKick(configuration.kickSettings) }
        else if configuration.mode == .oud { hostedInstrument?.synth?.configureOud(configuration.oudSettings) }
        else if configuration.mode == .violin { hostedInstrument?.synth?.configureViolin(configuration.violinSettings) }
        else if configuration.mode == .shaker { hostedInstrument?.synth?.configureShaker(configuration.shakerSettings) }
        else { hostedInstrument?.synth?.configure(configuration.synth) }
        if loadedConfiguration?.mode == configuration.mode { loadedConfiguration = configuration }
    }
    func snapshotConfiguration() throws -> InstrumentConfiguration {
        guard let hostedInstrument, loadedConfiguration?.mode == configuration.mode,
              loadedConfiguration?.audioUnit == configuration.audioUnit else { return configuration }
        return try hostedInstrument.snapshot(configuration)
    }
    func showPluginEditor() async throws {
        guard !isRecording, let unit = hostedInstrument?.unit, configuration.mode == .audioUnit else { return }
        let controller = await InstrumentEditorWindow.controller(for: unit)
        guard hostedInstrument?.unit === unit else { return }
        if let controller { editorWindow.show(controller, title: configuration.name) }
        else { throw MessageError("This plug-in does not provide a custom window. Use its parameters and factory presets below.") }
    }
    func closePluginEditor() { editorWindow.close() }

    func noteOn(_ pitch: Int, velocity: UInt8 = 100, hostTime: UInt64 = 0) {
        guard source == .keyboard, !isLoadingInstrument, (0..<128).contains(pitch), hostedInstrument != nil else { return }
        let pitch = UInt8(pitch)
        sustained.remove(pitch)
        hostedInstrument?.note(pitch, velocity: velocity, on: true)
        activePitches.insert(Int(pitch))
        if isRecording && recordingSource == .keyboard {
            capture.on(pitch, velocity: velocity, beat: relativeBeat(hostTime))
        }
    }

    func noteOff(_ pitch: Int, hostTime: UInt64 = 0) {
        guard (0..<128).contains(pitch) else { return }
        if sustaining { sustained.insert(UInt8(pitch)); return }
        hostedInstrument?.note(UInt8(pitch), velocity: 0, on: false)
        activePitches.remove(pitch)
        if isRecording && recordingSource == .keyboard { capture.off(UInt8(pitch), beat: relativeBeat(hostTime)) }
    }

    func panic() {
        sustaining = false
        sustained.removeAll()
        for pitch in activePitches { noteOff(pitch) }
        activePitches.removeAll()
        hostedInstrument?.panic()
    }

    private func relativeBeat(_ hostTime: UInt64 = 0) -> Double {
        TransportClock.beat(now: hostTime == 0 ? mach_absolute_time() : hostTime,
                            anchor: anchor, start: 0, bpm: bpm)
    }

    func refreshMIDI() {
        if midiClient == 0 {
            let result = MIDIClientCreateWithBlock("AI Music Sketchpad" as CFString, &midiClient) { [weak self] _ in
                Task { @MainActor in self?.refreshMIDI() }
            }
            guard result == noErr else { midiStatus = "MIDI unavailable (\(result))"; return }
            let status = MIDIInputPortCreateWithProtocol(midiClient, "Keyboard input" as CFString,
                                                         ._1_0, &midiPort) { [weak self] list, _ in
                var messages: [(UInt32, UInt64)] = []
                do {
                    let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet)!
                    let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
                    var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
                    for _ in 0..<list.pointee.numPackets {
                        do {
                            let p = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
                            var i = 0
                            while i < Int(packet.pointee.wordCount) {
                                let word = p[i]
                                let type = Int(word >> 28)
                                if type == 2 { messages.append((word, packet.pointee.timeStamp)) }
                                let widths = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
                                i += widths[type]
                            }
                        }
                        packet = UnsafePointer(MIDIEventPacketNext(packet))
                    }
                }
                let received = messages
                Task { @MainActor in
                    for (word, timestamp) in received { self?.receive(word: word, timestamp: timestamp) }
                }
            }
            guard status == noErr else {
                MIDIClientDispose(midiClient)
                midiClient = 0
                midiStatus = "MIDI port unavailable (\(status))"
                return
            }
        }
        let sources = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
        for source in connectedSources.subtracting(sources) { MIDIPortDisconnectSource(midiPort, source) }
        for source in sources.subtracting(connectedSources) { MIDIPortConnectSource(midiPort, source, nil) }
        connectedSources = sources
        var names: [String] = []
        for source in sources {
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) == noErr,
               let value = name?.takeRetainedValue() { names.append(value as String) }
        }
        midiStatus = names.isEmpty ? "No MIDI devices • computer keys are ready" : names.joined(separator: ", ")
    }

    private func receive(word: UInt32, timestamp: UInt64) {
        guard source == .keyboard else { return }
        let status = UInt8((word >> 16) & 0xF0)
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        switch status {
        case 0x90 where data2 > 0: noteOn(data1, velocity: data2, hostTime: timestamp)
        case 0x80, 0x90: noteOff(data1, hostTime: timestamp)
        case 0xB0 where data1 == 64:
            sustaining = data2 >= 64
            if !sustaining {
                let release = sustained
                sustained.removeAll()
                for pitch in release { noteOff(Int(pitch), hostTime: timestamp) }
            }
        case 0xB0 where data1 == 120 || data1 == 123: panic()
        default: break
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "Audio recording failed."
        Task { @MainActor [weak self] in self?.onFailure?(message) }
    }

    deinit {
        if midiPort != 0 { MIDIPortDispose(midiPort) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }
}
