import AVFoundation
import Foundation

/// Copies the instrument-only mixer tap into a bounded writer queue. Backing
/// tracks use a different engine and can never enter this recording.
final class InstrumentAudioCapture: @unchecked Sendable {
    let url: URL
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let anchor: UInt64
    private let queue = DispatchQueue(label: "Sketchpad.instrument-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var pending = 0
    private var failure: Error?
    private var written: Int64 = 0

    init(url: URL, format: AVAudioFormat, anchor: UInt64) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw StudioError.invalidAudio }
        self.url = url; self.format = format; self.anchor = anchor
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: url, settings: settings)
    }
    func append(_ input: AVAudioPCMBuffer, time: AVAudioTime) {
        guard time.isHostTimeValid else { setFailure(MessageError("The instrument did not provide recording timestamps.")); return }
        let seconds = time.hostTime >= anchor ? AVAudioTime.seconds(forHostTime: time.hostTime - anchor)
            : -AVAudioTime.seconds(forHostTime: anchor - time.hostTime)
        let position = Int64((seconds * format.sampleRate).rounded())
        guard position + Int64(input.frameLength) > 0 else { return }
        lock.lock()
        guard accepting, failure == nil else { lock.unlock(); return }
        guard pending < 32 else {
            failure = MessageError("Instrument recording could not keep up with disk writing. The incomplete take was not added.")
            lock.unlock(); return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength),
              let source = input.floatChannelData, let target = copy.floatChannelData else {
            failure = StudioError.invalidAudio; lock.unlock(); return
        }
        copy.frameLength = input.frameLength
        for channel in 0..<Int(format.channelCount) {
            target[channel].update(from: source[channel], count: Int(input.frameLength))
        }
        pending += 1
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do { try write(copy, at: position) } catch { setFailure(error) }
        }
        lock.unlock()
    }
    private func write(_ buffer: AVAudioPCMBuffer, at position: Int64) throws {
        var skip = max(0, written - position)
        guard skip < Int64(buffer.frameLength) else { return }
        let gap = max(0, position - written)
        guard gap < Int64(format.sampleRate * 2) else { throw MessageError("Instrument audio timestamps jumped during recording.") }
        if gap > 0 {
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap))!
            silence.frameLength = AVAudioFrameCount(gap)
            for channel in 0..<Int(format.channelCount) {
                silence.floatChannelData![channel].update(repeating: 0, count: Int(gap))
            }
            try file.write(from: silence); written += gap
        }
        skip = max(0, written - position)
        let count = Int(buffer.frameLength) - Int(skip)
        guard count > 0 else { return }
        if skip > 0 {
            for channel in 0..<Int(format.channelCount) {
                let data = buffer.floatChannelData![channel]
                memmove(data, data.advanced(by: Int(skip)), count * MemoryLayout<Float>.size)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer); written += Int64(count)
    }
    func finish() throws {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync {}
        lock.lock(); let error = failure; lock.unlock()
        if let error { throw error }
        guard written > 0 else { throw MessageError("No instrument audio arrived while recording.") }
    }
    private func setFailure(_ error: Error) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
}
