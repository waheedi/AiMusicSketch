import Foundation

/// Minimal SoundFont 2.04 writer for this app's original mono synth samples.
/// Layout/generators: Creative/E-mu SoundFont 2.04 technical specification.
/// https://musescore.org/sites/musescore.org/files/2023-01/sfspec24.pdf
enum SignatureSoundBank {
    static func make(aurora: Bool = false) -> Data {
        let title = aurora ? "Aurora Kit" : "Signature Kit"
        var high = Data(), low = Data(), headers = Data()
        var sampleOffset: UInt32 = 0
        for index in 0..<28 {
            let original = aurora ? AuroraKit.synthesize(index) : SignatureKit.synthesize(index)
            let looping = [24, 25, 27].contains(index)
            // Eight matching samples before/after the loop protect interpolators.
            let samples = looping ? Array(original.suffix(8)) + original + Array(original.prefix(8)) : original
            let end = sampleOffset + UInt32(samples.count)
            headers += name("\(title) \(index)")
            let loopStart = sampleOffset + (looping ? 8 : 0)
            let loopEnd = end - (looping ? 8 : 0)
            for value in [sampleOffset, end, loopStart, loopEnd, UInt32(SignatureKit.sampleRate)] { headers += u32(value) }
            headers += Data([UInt8(index < 24 ? 60 : 48 + (index - 24) * 12), 0])
            headers += u16(0) + u16(1) // unlinked mono sample
            for sample in samples {
                let pcm = Int32(max(-8_388_608, min(8_388_607, (Double(sample) * 8_388_608).rounded())))
                let bits = UInt32(bitPattern: pcm)
                high += u16(UInt16((bits >> 8) & 0xFFFF))
                low.append(UInt8(bits & 0xFF))
            }
            // SoundFont interpolation guard samples, outside the playable region.
            high.append(Data(repeating: 0, count: 46 * 2))
            low.append(Data(repeating: 0, count: 46))
            sampleOffset = end + 46
        }
        headers += name("EOS") + Data(repeating: 0, count: 26)

        var bags = Data(), generators = Data()
        for note in 0..<128 {
            bags += u16(UInt16(generators.count / 4)) + u16(0)
            let source = SignatureKit.sourceIndex(for: note)
            generators += gen(43, note | (note << 8)) // keyRange must come first
            generators += gen(58, source < 24 ? note : 48 + (source - 24) * 12)
            generators += gen(56, source < 24 ? 0 : 100) // fixed drum pitch / chromatic tonal pitch
            generators += gen(54, [24, 25, 27].contains(source) ? 1 : 0)
            generators += gen(34, -12_000) // ~1 ms attack
            generators += gen(38, -7_200) // ~16 ms release
            generators += gen(53, source) // sampleID must come last
        }
        bags += u16(UInt16(generators.count / 4)) + u16(0)
        generators += gen(0, 0)
        let preset = join([name(title), u16(0), u16(0), u16(0), Data(repeating: 0, count: 12),
                           name("EOP"), u16(0), u16(0), u16(1), Data(repeating: 0, count: 12)])
        let presetBags = u16(0) + u16(0) + u16(1) + u16(0)
        let instruments = name(title) + u16(0) + name("EOI") + u16(128)
        let pdta = chunk("LIST", join([Data("pdta".utf8),
            chunk("phdr", preset), chunk("pbag", presetBags),
            chunk("pmod", Data(repeating: 0, count: 10)), chunk("pgen", gen(41, 0) + gen(0, 0)),
            chunk("inst", instruments), chunk("ibag", bags),
            chunk("imod", Data(repeating: 0, count: 10)), chunk("igen", generators), chunk("shdr", headers)]))
        let info = chunk("LIST", Data("INFO".utf8) + chunk("ifil", u16(2) + u16(4))
            + chunk("isng", Data("EMU8000\0".utf8)) + chunk("INAM", Data("Sketchpad \(title)\0".utf8)))
        let samples = chunk("LIST", Data("sdta".utf8) + chunk("smpl", high) + chunk("sm24", low))
        return chunk("RIFF", Data("sfbk".utf8) + info + samples + pdta)
    }

    private static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func join(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func gen(_ operation: UInt16, _ value: Int) -> Data {
        u16(operation) + u16(UInt16(truncatingIfNeeded: value))
    }
    private static func name(_ text: String) -> Data {
        var data = Data(text.utf8.prefix(19))
        data.append(Data(repeating: 0, count: 20 - data.count))
        return data
    }
    private static func chunk(_ tag: String, _ data: Data) -> Data {
        var result = Data(tag.utf8) + u32(UInt32(data.count)) + data
        if data.count % 2 != 0 { result.append(0) }
        return result
    }
}
