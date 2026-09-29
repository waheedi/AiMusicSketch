import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

enum MIDIRenderer {
    static func render(notes: [MIDINote], part: MusicalPart, bpm: Double, bars: Int,
                       sampleRate: Double, to url: URL) throws -> Double {
        try render(notes: notes, instrument: .forPart(part), bpm: bpm,
                   durationBeats: Double(bars * 4), sampleRate: sampleRate, to: url)
    }

    static func loadInstrument(_ instrument: KeyboardInstrument, into sampler: AVAudioUnitSampler) throws {
        if let path = instrument.libraryPath {
            guard FileManager.default.fileExists(atPath: path) else {
                throw MessageError("\(instrument.rawValue) needs its installed Logic/GarageBand sound library. Missing instrument: \(path)")
            }
            try sampler.loadInstrument(at: URL(fileURLWithPath: path))
            if instrument.isElectronicDrumKit {
                try routeDrumKitToStereo(instrument, sampler: sampler)
            }
            return
        }
        let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        try sampler.loadSoundBankInstrument(at: bank, program: instrument.program,
            bankMSB: UInt8(instrument == .drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
            bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    }

    private static func routeDrumKitToStereo(_ kit: KeyboardInstrument, sampler: AVAudioUnitSampler) throws {
        guard var state = sampler.auAudioUnit.fullState,
              var instrument = state["Instrument"] as? [String: Any],
              var layers = instrument["Layers"] as? [[String: Any]], !layers.isEmpty else {
            throw MessageError("Could not read the \(kit.rawValue) drum mapping.")
        }
        // Logic's EXS kits route drum groups to separate outputs. AVAudioUnitSampler
        // exposes one stereo bus, so preserve every zone but fold its layer onto bus 0.
        for index in layers.indices { layers[index]["output"] = 0 }
        instrument["Layers"] = layers
        state["Instrument"] = instrument

        let compatibilitySamples: [String]
        switch kit {
        case .tr909:
            compatibilitySamples = ["Kick 1 - TR-909 Unprocessed.aif", "Kick 2 - TR-909 Unprocessed.aif"]
        case .deepHouse:
            compatibilitySamples = ["Ride_DeepBassHouse.aif", "Shaker_1_DeepBassHouse.aif"]
        default:
            compatibilitySamples = []
        }
        if !compatibilitySamples.isEmpty {
            guard var references = state["file-references"] as? [String: String] else {
                throw MessageError("Could not read the \(kit.rawValue) sample references.")
            }
            // These AIFFs play through the EXS importer, but become silent when
            // restored as native AU preset references on macOS 15. Preserve their PCM
            // exactly in local float WAVs (same rate/channels, no gain or resampling).
            for (key, path) in references where compatibilitySamples.contains(URL(fileURLWithPath: path).lastPathComponent) {
                references[key] = try samplerCompatibleWAV(URL(fileURLWithPath: path)).path
            }
            state["file-references"] = references
        }
        sampler.auAudioUnit.fullState = state
    }

    private static func samplerCompatibleWAV(_ sourceURL: URL) throws -> URL {
        let fingerprint = SHA256.hash(data: try Data(contentsOf: sourceURL))
            .map { String(format: "%02x", $0) }.joined()
        let manager = FileManager.default
        let directory = try manager.url(for: .cachesDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            .appendingPathComponent("AI Music Sketchpad/KitSamples-v1", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(fingerprint).wav")
        if manager.fileExists(atPath: destination.path) { return destination }
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? manager.removeItem(at: temporary) }
        let source = try AVAudioFile(forReading: sourceURL)
        var settings = source.processingFormat.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384) else {
                throw StudioError.invalidAudio
            }
            while source.framePosition < source.length {
                try source.read(into: buffer)
                guard buffer.frameLength > 0 else { throw StudioError.invalidAudio }
                try output.write(from: buffer)
            }
        }
        // Publish only a closed, complete WAV. Another app instance may have cached it.
        do { try manager.moveItem(at: temporary, to: destination) }
        catch { if !manager.fileExists(atPath: destination.path) { throw error } }
        return destination
    }

    static func render(notes: [MIDINote], instrument: KeyboardInstrument, bpm: Double,
                       durationBeats: Double, sampleRate: Double, to url: URL) throws -> Double {
        guard bpm.isFinite, bpm > 0, durationBeats.isFinite, durationBeats > 0,
              durationBeats * 60 / bpm < 3_600 else { throw StudioError.invalidAudio }
        let duration = durationBeats * 60 / bpm
        let totalFrames = Int64((duration * sampleRate).rounded())
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: format)
        try loadInstrument(instrument, into: sampler)
        engine.mainMixerNode.outputVolume = 0.65
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        defer { engine.stop(); engine.disableManualRenderingMode() }

        struct Event {
            let frame: Int64
            let pitch: UInt8
            let velocity: UInt8
            let on: Bool
        }
        var events: [Event] = []
        for note in notes {
            guard (0..<128).contains(note.pitch), note.startBeat.isFinite,
                  note.durationBeats.isFinite, note.velocity.isFinite, note.startBeat >= 0,
                  note.startBeat < durationBeats, note.durationBeats > 0 else { continue }
            let start = Int64((note.startBeat * 60 / bpm * sampleRate).rounded())
            let end = min(totalFrames, Int64(((note.startBeat + note.durationBeats) * 60 / bpm * sampleRate).rounded()))
            guard end > start else { continue }
            let velocity = UInt8(max(1, min(127, Int(note.velocity * 127))))
            events.append(Event(frame: start, pitch: UInt8(note.pitch), velocity: velocity, on: true))
            events.append(Event(frame: end, pitch: UInt8(note.pitch), velocity: 0, on: false))
        }
        events.sort { $0.frame == $1.frame ? (!$0.on && $1.on) : $0.frame < $1.frame }
        guard !events.isEmpty else { throw MessageError("No playable notes were generated.") }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        var eventIndex = 0
        var stalls = 0
        while engine.manualRenderingSampleTime < totalFrames {
            let position = engine.manualRenderingSampleTime
            while eventIndex < events.count, events[eventIndex].frame <= position {
                let event = events[eventIndex]
                if event.on { sampler.startNote(event.pitch, withVelocity: event.velocity, onChannel: 0) }
                else { sampler.stopNote(event.pitch, onChannel: 0) }
                eventIndex += 1
            }
            let nextEvent = eventIndex < events.count ? events[eventIndex].frame : totalFrames
            let count = AVAudioFrameCount(min(4_096, totalFrames - position, max(1, nextEvent - position)))
            switch try engine.renderOffline(count, to: buffer) {
            case .success:
                stalls = 0
                // Short boundary fades avoid clicks when the resulting WAV repeats.
                if let channels = buffer.floatChannelData {
                    let fade = sampleRate * 0.003
                    for frame in 0..<Int(buffer.frameLength) {
                        let sample = Double(position + Int64(frame))
                        let gain = Float(min(1, sample / fade, (Double(totalFrames - 1) - sample) / fade))
                        for channel in 0..<2 { channels[channel][frame] *= max(0, gain) }
                    }
                }
                try file.write(from: buffer)
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                stalls += 1
                if stalls > 100 { throw MessageError("The instrument could not render audio.") }
            default: throw StudioError.invalidAudio
            }
        }
        return duration
    }
}
