import AVFoundation
import SwiftUI

struct AudioWaveform: View {
    let clip: ClipModel
    let bpm: Double
    @State private var peaks: [Float] = []
    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .task(id: clip.assetPath) {
            let url = clip.assetURL
            peaks = await Task.detached(priority: .utility) { (try? Self.loadPeaks(url)) ?? [] }.value
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty, clip.sourceDurationSeconds > 0, bpm > 0 else { return }
        let count = min(1_200, max(1, Int(size.width / 3)))
        let seconds = clip.durationBeats * 60 / bpm
        for i in 0..<count {
            let fraction = Double(i) / Double(count)
            let elapsed = fraction * seconds - (clip.leadingSilenceSeconds ?? 0)
            guard elapsed >= 0, fraction * seconds < seconds - (clip.trailingSilenceSeconds ?? 0) else { continue }
            var source = (clip.playbackOffsetSeconds ?? 0) + elapsed
            if !clip.loopEnabled && source >= clip.sourceRegionSeconds { continue }
            if clip.loopEnabled { source = source.truncatingRemainder(dividingBy: clip.sourceRegionSeconds) }
            source += clip.sourceOffsetSeconds
            guard source >= 0, source < clip.sourceDurationSeconds else { continue }
            let position = source / clip.sourceDurationSeconds * Double(peaks.count)
            let index = min(peaks.count - 1, max(0, Int(position)))
            let height = max(CGFloat(1), CGFloat(peaks[index]) * size.height)
            let rect = CGRect(x: CGFloat(fraction) * size.width, y: (size.height - height) / 2,
                              width: 2, height: height)
            context.fill(Path(rect), with: .color(.white.opacity(0.65)))
        }
    }

    nonisolated private static func loadPeaks(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else { return [] }
        var values = [Float](repeating: 0, count: 1_024)
        while file.framePosition < file.length {
            let offset = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                let index = min(1_023, Int((offset + Int64(frame)) * 1_024 / file.length))
                for channel in 0..<Int(buffer.format.channelCount) {
                    values[index] = max(values[index], abs(channels[channel][frame]))
                }
            }
        }
        let maximum = max(0.001, values.max() ?? 1)
        return values.map { min(1, $0 / maximum) }
    }
}
