import SwiftUI
import AudioToolbox

struct InstrumentControls: View {
    @ObservedObject var studio: StudioModel
    @State private var showParameters = false
    @State private var parameterRevision = 0
    private var recording: RecordingController { studio.recording }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Instrument", selection: Binding(get: { recording.configuration.mode }, set: {
                    recording.configuration.mode = $0
                    if $0 == .audioUnit { recording.refreshAudioUnits() }
                    if $0 == .audioUnit && recording.configuration.audioUnit == nil { recording.unloadKeyboard() }
                    studio.instrumentChanged(reload: $0 != .audioUnit || recording.configuration.audioUnit != nil)
                })) {
                    ForEach(InstrumentMode.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 260).disabled(studio.editingLocked)
                Button("Surge XT", systemImage: "pianokeys") {
                    recording.refreshAudioUnits()
                    guard let surge = recording.installedAudioUnits.first(where: \.isSurgeXT) else {
                        studio.alertMessage = "Surge XT is not installed. Install its Audio Unit and factory Resources from surge-synthesizer.github.io, then restart Sketchpad."
                        return
                    }
                    if recording.configuration.mode != .audioUnit || recording.configuration.audioUnit?.id != surge.id {
                        recording.configuration.mode = .audioUnit
                        recording.configuration.audioUnit = surge
                        recording.configuration.audioUnitState = nil
                        studio.instrumentChanged()
                    } else {
                        Task { do { try await recording.showPluginEditor() } catch { studio.alertMessage = error.localizedDescription } }
                    }
                }.disabled(studio.editingLocked || recording.isLoadingInstrument)
                    .help("Load Surge XT; when already loaded, open its sound designer and preset browser")
                if recording.configuration.mode == .builtIn {
                    Picker("Sound", selection: Binding(get: { recording.instrument }, set: {
                        recording.instrument = $0
                        recording.octave = $0.isOriginalKit ? 1 : $0.isPercussion ? 2 : $0 == .oud ? 3 : 4
                        studio.instrumentChanged()
                    })) {
                        ForEach(KeyboardInstrument.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 250).disabled(studio.editingLocked)
                }
                if recording.isLoadingInstrument { ProgressView().controlSize(.small) }
                Text(recording.instrumentMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            switch recording.configuration.mode {
            case .builtIn: EmptyView()
            case .synth: synthControls
            case .kick: kickControls
            case .oud: oudControls
            case .violin, .shaker: creatorControls
            case .audioUnit: pluginControls
            }
        }
    }
    private var creatorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recording.configuration.mode == .violin {
                Text("Synthesized bowed strings • hold to sustain • velocity shapes the bow • all octaves playable")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    creatorSlider("Bow", \.violinSettings.bow, 0...1)
                    creatorSlider("Tone", \.violinSettings.tone, 0...1)
                    creatorSlider("Body", \.violinSettings.body, 0...1)
                    creatorSlider("Vibrato", \.violinSettings.vibrato, 0...1)
                    creatorSlider("Attack s", \.violinSettings.attack, 0.015...0.8)
                    creatorSlider("Release s", \.violinSettings.release, 0.03...1.5)
                    creatorSlider("Output", \.violinSettings.gain, 0...0.6)
                }
            } else {
                Text("Synthesized shaker • tap for one shake, hold to repeat • higher keys brighten the shell • release leaves the tail")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    creatorSlider("Texture", \.shakerSettings.texture, 0...1)
                    creatorSlider("Brightness", \.shakerSettings.brightness, 0...1)
                    creatorSlider("Shakes / s", \.shakerSettings.rate, 2...16)
                    creatorSlider("Decay s", \.shakerSettings.decay, 0.04...0.4)
                    creatorSlider("Output", \.shakerSettings.gain, 0...0.6)
                }
            }
        }.disabled(recording.isLoadingInstrument)
    }
    private func creatorSlider(_ title: String, _ key: WritableKeyPath<InstrumentConfiguration, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(recording.configuration[keyPath: key], specifier: "%.2f")").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { recording.configuration[keyPath: key] }, set: {
                recording.configuration[keyPath: key] = $0; studio.instrumentChanged(reload: false)
            }), in: range, onEditingChanged: { editing in
                if editing { studio.beginEdit("\(recording.configuration.name) Settings") } else { studio.endEdit() }
            })
        }
    }
    private var oudControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synthesized oud-style plucks • chromatic keys • release damps the strings • sampled Oud stays in Sound Library")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                oudSlider("Pluck", \.pluck, 0...1)
                oudSlider("Warmth", \.warmth, 0...1)
                oudSlider("Decay s", \.decay, 0.15...3)
                oudSlider("Output", \.gain, 0...0.6)
            }
        }.disabled(recording.isLoadingInstrument)
    }
    private func oudSlider(_ title: String, _ key: WritableKeyPath<OudSettings, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(recording.configuration.oudSettings[keyPath: key], specifier: "%.2f")").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { recording.configuration.oudSettings[keyPath: key] }, set: {
                recording.configuration.oudSettings[keyPath: key] = $0; studio.instrumentChanged(reload: false)
            }), in: range, onEditingChanged: { editing in
                if editing { studio.beginEdit("Oud Settings") } else { studio.endEdit() }
            })
        }
    }
    private var kickControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu("Kick presets") {
                    ForEach(["Deep House", "909-inspired", "Punch", "Sub"], id: \.self) { name in
                        Button(name) {
                            recording.configuration.kickSettings = .preset(name)
                            studio.instrumentChanged(reload: false)
                        }
                    }
                }.frame(width: 160)
                Text("Every key triggers the tuned kick • one-shot decay • leave its tail before stopping a take")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 16) {
                kickSlider("Tune Hz", \.tune, 30...100)
                kickSlider("Decay s", \.decay, 0.08...2)
                kickSlider("Sweep st", \.sweep, 0...36)
                kickSlider("Sweep s", \.sweepTime, 0.005...0.15)
                kickSlider("Click", \.click, 0...1)
                kickSlider("Drive", \.drive, 0...1)
                kickSlider("Output", \.gain, 0...0.6)
            }
        }.disabled(recording.isLoadingInstrument)
    }
    private func kickSlider(_ title: String, _ key: WritableKeyPath<KickSettings, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(recording.configuration.kickSettings[keyPath: key], specifier: "%.2f")").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { recording.configuration.kickSettings[keyPath: key] }, set: {
                recording.configuration.kickSettings[keyPath: key] = $0
                studio.instrumentChanged(reload: false)
            }), in: range, onEditingChanged: { editing in
                if editing { studio.beginEdit("Kick Settings") } else { studio.endEdit() }
            })
        }
    }
    private var synthControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Wave", selection: Binding(get: { recording.configuration.synth.waveform }, set: {
                    recording.configuration.synth.waveform = $0; studio.instrumentChanged(reload: false)
                })) {
                    ForEach(SynthWaveform.allCases) { Text($0.title).tag($0) }
                }.frame(width: 200)
                Menu("Starter presets") {
                    ForEach(["Bright lead", "Soft pad", "Round bass", "Glass pluck"], id: \.self) { name in
                        Button(name) {
                            recording.configuration.synth = .preset(name); studio.instrumentChanged(reload: false)
                        }
                    }
                }.frame(width: 140)
                Text("32 voices • all octaves • sound and knob changes are captured in the take")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 18) {
                synthSlider("Attack", \.attack, 0.002...3, suffix: "s")
                synthSlider("Decay", \.decay, 0.01...3, suffix: "s")
                synthSlider("Sustain", \.sustain, 0...1)
                synthSlider("Release", \.release, 0.01...5, suffix: "s")
                synthSlider("Filter", \.cutoff, log10(40)...log10(18_000), suffix: "Hz", logarithmic: true)
                synthSlider("Output", \.gain, 0...0.6)
            }
        }.disabled(recording.isLoadingInstrument)
    }
    private func synthSlider(_ title: String, _ key: WritableKeyPath<SynthSettings, Double>, _ range: ClosedRange<Double>, suffix: String = "", logarithmic: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let value = recording.configuration.synth[keyPath: key]
            Text("\(title) \(value, specifier: logarithmic ? "%.0f" : "%.2f")\(suffix)").font(.caption).monospacedDigit()
            Slider(value: Binding(get: { logarithmic ? log10(max(40, recording.configuration.synth[keyPath: key])) : recording.configuration.synth[keyPath: key] }, set: {
                recording.configuration.synth[keyPath: key] = logarithmic ? pow(10, $0) : $0
                studio.instrumentChanged(reload: false)
            }), in: range, onEditingChanged: { editing in
                if editing { studio.beginEdit("Synth Settings") } else { studio.endEdit() }
            })
        }
    }
    private var pluginControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Installed AU", selection: Binding(get: { recording.configuration.audioUnit?.id ?? "" }, set: { id in
                    recording.configuration.audioUnit = recording.installedAudioUnits.first { $0.id == id }
                    recording.configuration.audioUnitState = nil
                    studio.instrumentChanged()
                })) {
                    Text("Choose instrument…").tag("")
                    if let saved = recording.configuration.audioUnit, !recording.installedAudioUnits.contains(where: { $0.id == saved.id }) {
                        Text("\(saved.name) (unavailable)").tag(saved.id)
                    }
                    ForEach(recording.installedAudioUnits) { unit in Text("\(unit.name) — \(unit.maker)").tag(unit.id) }
                }.frame(maxWidth: 480).disabled(studio.editingLocked)
                Button("Rescan") { recording.refreshAudioUnits() }.disabled(studio.editingLocked)
                Button("Reload") { studio.prepareKeyboard() }.disabled(studio.editingLocked || recording.configuration.audioUnit == nil)
                Button(recording.configuration.audioUnit?.isSurgeXT == true ? "Open Synth & Presets" : "Open plug-in") {
                    Task { do { try await recording.showPluginEditor() } catch { studio.alertMessage = error.localizedDescription } }
                }.disabled(studio.editingLocked || recording.hostedInstrument?.unit == nil)
                if recording.configuration.audioUnit?.isSurgeXT != true,
                   let unit = recording.hostedInstrument?.unit?.auAudioUnit, let presets = unit.factoryPresets, !presets.isEmpty {
                    Menu("Factory presets") {
                        ForEach(presets, id: \.number) { preset in
                            Button(preset.name) { recording.panic(); unit.currentPreset = preset; parameterRevision += 1 }
                        }
                    }.frame(width: 150).disabled(studio.editingLocked)
                }
                Spacer()
            }
            Text(recording.configuration.audioUnit?.isSurgeXT == true
                 ? "Surge XT: open Synth & Presets to browse sounds and edit oscillators, filters and effects. Save Project remembers your sound. AU takes record audio; note editing is not yet supported."
                 : "AU instruments only (not VST or effects). Load only plug-ins you trust. Some samplers need a sound bank in their own editor.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Plug-in parameters", isExpanded: $showParameters) {
                let _ = parameterRevision
                let parameters = recording.hostedInstrument?.unit?.auAudioUnit.parameterTree?.allParameters.filter {
                    $0.flags.contains(.flag_IsWritable) && $0.minValue.isFinite && $0.maxValue.isFinite && $0.maxValue > $0.minValue
                } ?? []
                if parameters.isEmpty { Text("No editable parameters exposed. Use the plug-in window or factory presets.").font(.caption) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 10) {
                        ForEach(parameters, id: \.address) { p in
                            VStack(alignment: .leading) {
                                Text("\(p.displayName): \(p.string(fromValue: nil))").font(.caption).lineLimit(1)
                                Slider(value: Binding(get: { min(p.maxValue, max(p.minValue, p.value)) }, set: { p.value = $0 }), in: p.minValue...p.maxValue)
                            }
                        }
                    }
                }.frame(maxHeight: parameters.isEmpty ? 0 : 130)
            }.onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
                if showParameters { parameterRevision &+= 1 }
            }
        }.onAppear { recording.refreshAudioUnits() }
    }
}
