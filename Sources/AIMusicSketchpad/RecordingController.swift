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
}

@MainActor
final class RecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var source: RecordingSource = .microphone
    @Published var instrument: KeyboardInstrument = .piano
    @Published var octave = 4
    @Published private(set) var isRecording = false
    @Published private(set) var activePitches = Set<Int>()
    @Published private(set) var midiStatus = "Connect a MIDI keyboard, then press Refresh."
    @Published private(set) var inputLevel: Float = 0
    var onFailure: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var engine: AVAudioEngine?
    private var sampler: AVAudioUnitSampler?
    private var activeInstrument: KeyboardInstrument?
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
            try prepareKeyboard()
        }
    }

    func begin(anchor: UInt64, bpm: Double) throws {
        panic()
        self.anchor = anchor
        self.bpm = bpm
        recordingSource = source
        recordingInstrument = instrument
        capture = NoteCapture()
        if source == .microphone {
            guard let recorder else { throw MessageError("Microphone was not prepared.") }
            let now = mach_absolute_time()
            let delay = anchor > now ? AVAudioTime.seconds(forHostTime: anchor - now) : 0
            guard recorder.record(atTime: recorder.deviceCurrentTime + delay) else {
                throw MessageError("The audio input did not start recording.")
            }
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
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        if recordingSource == .keyboard, notes.isEmpty {
            throw MessageError("No notes were played. Click the keyboard to focus it, or connect a MIDI keyboard, then record again.")
        }
        return RecordedTake(url: recordingSource == .microphone ? url : nil, notes: notes,
                            durationBeats: durationBeats, instrument: recordingInstrument)
    }

    func cancelPreparation() {
        recorder?.stop()
        recorder = nil
    }

    func prepareKeyboard() throws {
        if engine == nil {
            let engine = AVAudioEngine()
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0.65
            self.engine = engine
            self.sampler = sampler
        }
        if activeInstrument != instrument, let sampler {
            panic()
            try MIDIRenderer.loadInstrument(instrument, into: sampler)
            activeInstrument = instrument
        }
        if let engine, !engine.isRunning { try engine.start() }
        refreshMIDI()
    }

    func noteOn(_ pitch: Int, velocity: UInt8 = 100, hostTime: UInt64 = 0) {
        guard source == .keyboard, (0..<128).contains(pitch), sampler != nil else { return }
        let pitch = UInt8(pitch)
        sustained.remove(pitch)
        sampler?.startNote(pitch, withVelocity: velocity, onChannel: 0)
        activePitches.insert(Int(pitch))
        if isRecording && recordingSource == .keyboard {
            capture.on(pitch, velocity: velocity, beat: relativeBeat(hostTime))
        }
    }

    func noteOff(_ pitch: Int, hostTime: UInt64 = 0) {
        guard (0..<128).contains(pitch) else { return }
        if sustaining { sustained.insert(UInt8(pitch)); return }
        sampler?.stopNote(UInt8(pitch), onChannel: 0)
        activePitches.remove(pitch)
        if isRecording && recordingSource == .keyboard { capture.off(UInt8(pitch), beat: relativeBeat(hostTime)) }
    }

    func panic() {
        sustaining = false
        sustained.removeAll()
        for pitch in activePitches { noteOff(pitch) }
        activePitches.removeAll()
        sampler?.sendController(123, withValue: 0, onChannel: 0)
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
