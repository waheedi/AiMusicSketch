import AVFoundation
import AudioToolbox
import SketchSynthDSP

struct SurgePlaybackSettings: Codable, Hashable {
    var enabled = false
    var cutoff = 0.0, resonance = 0.0, attack = 0.0, release = 0.0, width = 0.0
    func value(_ parameter: AutomationParameter) -> Double {
        switch parameter {
        case .surgeCutoff: cutoff
        case .surgeResonance: resonance
        case .surgeAttack: attack
        case .surgeRelease: release
        case .surgeWidth: width
        default: 0
        }
    }
    mutating func set(_ parameter: AutomationParameter, value: Double) {
        let value = value.isFinite ? max(-1, min(1, value)) : 0
        switch parameter {
        case .surgeCutoff: cutoff = value
        case .surgeResonance: resonance = value
        case .surgeAttack: attack = value
        case .surgeRelease: release = value
        case .surgeWidth: width = value
        default: break
        }
    }
}

extension ClipModel {
    var supportsLiveSurge: Bool {
        instrumentAddOn?.mode == .audioUnit && instrumentAddOn?.audioUnit?.isSurgeXT == true
            && instrumentAddOn?.audioUnitState != nil && midiNotes?.isEmpty == false
    }
}

/// One AU per distinct recorded patch on a track, not per loop or copied clip.
/// Notes are scheduled on the audio render thread; sliders/curves use the existing mix clock.
final class LiveSurgeInstrument {
    struct Control {
        let kind: AutomationParameter
        let parameter: AUParameter
        let original: Float
        var last: Float
    }
    let unit: AVAudioUnitMIDIInstrument
    private let sequence: SketchSequenceRef
    private var controls: [Control] = []

    init(configuration: InstrumentConfiguration, clips: [ClipModel], bpm: Double, endBeat: Double) throws {
        guard let id = configuration.audioUnit, id.isSurgeXT, let data = configuration.audioUnitState,
              let state = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw MessageError("This clip has no saved Surge patch. Turn off Live Surge to use its original audio.")
        }
        var description = id.description
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MessageError("Surge XT is unavailable. Turn off Live Surge to play the original recorded audio.")
        }
        var installed = AudioComponentDescription()
        AudioComponentGetDescription(component, &installed)
        guard !AudioComponentFlags(rawValue: installed.componentFlags).contains(.requiresAsyncInstantiation) else {
            throw MessageError("This Surge version requires a different host. Turn off Live Surge to use recorded audio.")
        }
        unit = AVAudioUnitMIDIInstrument(audioComponentDescription: description)
        unit.auAudioUnit.fullStateForDocument = state
        guard let sequence = SketchSequenceCreate(unit.audioUnit, bpm) else { throw StudioError.invalidAudio }
        self.sequence = sequence
        for clip in clips {
            let origin = clip.startBeat * 60 / bpm
            let end = min(clip.endBeat, endBeat) * 60 / bpm
            for segment in scheduledSegments(for: clip, bpm: bpm, fromBeat: clip.startBeat, toBeat: endBeat) {
                SketchSequenceAddRegion(sequence, segment.timelineStartSeconds, segment.timelineStartSeconds + segment.durationSeconds)
            }
            for note in ClipNoteLayout.notes(for: clip, bpm: bpm) {
                let start = origin + note.startSeconds
                let finish = min(end, start + note.durationSeconds)
                if finish > start {
                    SketchSequenceAddNote(sequence, start, finish, UInt8(note.pitch), UInt8(max(1, min(127, (note.velocity * 127).rounded()))))
                }
            }
        }
        SketchSequencePrepare(sequence)
        // Resolve semantic names, not list positions; never silently automate the wrong knob.
        let parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
        let names: [(AutomationParameter, String)] = [(.surgeCutoff, "Filter 1 Cutoff"),
            (.surgeResonance, "Filter 1 Resonance"), (.surgeAttack, "Amp EG Attack"),
            (.surgeRelease, "Amp EG Release"), (.surgeWidth, "Width")]
        for (kind, suffix) in names {
            for scene in ["A", "B"] {
                guard let p = parameters.first(where: { $0.displayName == "\(scene) \(suffix)" }),
                      p.flags.contains(.flag_IsWritable), p.minValue == 0, p.maxValue == 1 else {
                    throw MessageError("This Surge version does not expose \(scene) \(suffix). Turn off Live Surge to use recorded audio.")
                }
                controls.append(Control(kind: kind, parameter: p, original: p.value, last: p.value))
            }
        }
    }
    deinit { SketchSequenceDestroy(sequence) }

    func apply(_ settings: SurgePlaybackSettings) {
        for index in controls.indices {
            let control = controls[index]
            let offset = Float(settings.value(control.kind))
            // Offset in the AU's normalized range. Zero leaves each scene's patch value intact.
            let value = max(0, min(1, control.original + offset))
            if value != control.last {
                control.parameter.value = value
                controls[index].last = value
            }
        }
    }
    func play(at time: AVAudioTime, fromSeconds: Double, sampleRate: Double) {
        SketchSequenceStart(sequence, time.isHostTimeValid ? time.hostTime : 0, fromSeconds, sampleRate)
    }
    func stop() { SketchSequenceStop(sequence) }
}
