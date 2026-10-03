# AI Music Sketchpad

A native macOS multitrack sketchpad with local text-to-audio generation, microphone recording, and playable instruments. Requires macOS 15 or later; Apple Silicon is recommended for the audio model.

## Use

- **Per-track AI:** right-click a track or clip → AI • Improvise. Choose a reference range and describe the development you want. Only that track's actual audio (including recorded MIDI's instrument sound and its effects/automation) is rendered as input to MusicGen. Mute/solo and fader level are ignored for reference preparation. The model generates a continuation, not repair or faithful rewriting. Only new audio is appended after the same track's last clip; originals remain untouched. Each track remembers its AI settings, and generated clips retain reference provenance.
- **Generate past the track end:** “AI input” is the existing audio the model hears; the separate “AI output → Generate through beat” is the absolute end of the new music. Set it beyond the current track or timeline. For example, a track ending at beat 16 with output end 48 gets new music from 16 to 48. On success the timeline grows to fit (rounded up to a bar); existing clips are untouched, and existing empty timeline space is not shortened. The end controls new generation, not silence or repeated copies. “Use bars” restores the bars-based duration. For text-only generation, output starts at the playhead. One undo removes the new take and restores the previous timeline length. The timeline is not extended while just editing the field, or on failed/cancelled generation.
- **Generate from scratch:** choose New sound from prompt, describe a sound, choose length/seed, then generate at the red cursor. Cancel stops the model worker. Full mix produces one combined audio clip, not separated stems.
- **Playback / Follow:** the red cursor follows the audio clock. The arrow-to-line **Follow Playhead** toggle beside Snap/Zoom scrolls the timeline when the cursor reaches 80% of the visible width, retaining context behind it. It adapts to window width and zoom, follows backward seeks, and works during recording. Turn it off to browse freely without automatic scrolling. Turning it on reveals the cursor immediately. The choice is remembered across launches. Click the ruler to seek, including during playback. Playback holds at the end; the rewind button returns to the beginning.
- **Note display:** keyboard/MIDI clips show note bars (pitch vertically, actual key-held duration horizontally); audio-only clips show waveforms. Leading/trailing silence, overlapping notes, source trims, splits, loop phase and repetitions are preserved. Source tempo is saved for new takes, so later tempo edits do not stretch the note display relative to audio. Older takes without source-tempo metadata use the saved project tempo; if their tempo was already changed in an older app, the original recording tempo cannot be recovered reliably. Bars show played MIDI pitches, not every harmonic or internal note in a synthesized chord sound.
- **Edit/resize:** drag either clip edge with a live preview. Inward drags trim; outward drags reveal source audio up to its original bounds. Enable looping (right-click → Loop ×2) to extend repetitions beyond the source. Left-edge loop extension preserves phase. Resizing is nondestructive and does not time-stretch. Right-click also offers Trim and Split at Playhead.
- **Undo/redo:** ⌘Z / ⇧⌘Z, Edit menu, or toolbar arrows. Up to 100 project edits are kept in memory: clip edits, track edits, recorded/generated/imported additions, mix settings, and automation. One slider or automation-point drag is one undo step. New edits clear redo; New/Open clears history. Text fields use their native text undo. Undo does not delete asset files. History itself is not saved in project JSON.
- **Copy/repeat anywhere:** select a clip and use Copy / Paste (⌘C / ⌘V), or right-click Copy Clip. Click a destination track and time before pasting. ⌘D duplicates immediately after the selected clip. The internal clip clipboard preserves trim/loop metadata and references the same immutable audio asset; it is not an audio-file clipboard for other apps.
- **Dragging:** grab inside a clip to move it horizontally or onto another track; use the edge grips to resize. Snap ¼ beat can be disabled for free positioning, and Zoom enlarges small clips. The preview follows the snapped destination.
- **Automation:** click the connected-points button in a track header, then select Volume, Pan, EQ band, Compression, Reverb, or Delay. Click the lane to add a point and drag points in time/up/down; right-click a point to reset it to zero or delete it. Times are in seconds (50 ms placement grid), with linear interpolation and the final value held afterward. Zero means the base slider setting; offsets are clamped to the parameter's valid range. Add a final zero point to return to baseline. Curves affect playback, WAV export, and AI reference audio, and are saved with the project. Automation is track-level, so moving/copying a clip does not move its curves. Clear an envelope using the track's right-click menu.
- **Record:** select a track and open Recording Controls. Microphone / audio input uses the default input selected in macOS Sound settings. Allow microphone access when macOS asks. Use headphones to avoid recording speaker playback.
- **Play instruments:** choose Keyboard / MIDI, choose an instrument, and click the piano to give it focus. Play `A W S E D F T G Y H U J K L Ö Ä #`, or connect a MIDI keyboard and press Refresh. The added L, Ö, Ä and # play the four chromatic semitones after K (C♯, D, D♯, E of the next octave). German characters and their physical Mac key positions are supported. Press **1–6** (including the numeric keypad) to select an octave while the piano has focus. Held notes keep their original pitch until released; new notes use the new octave. Number shortcuts do not intercept text editing or ⌘/Control/Option shortcuts. The octave control affects computer keys only. Sustain pedal is supported. Record Track captures notes while the other tracks play; Stop & Save Take adds the rendered take and retains its note data.
- **Mix:** up to eight tracks, volume, pan, mute/solo, EQ, compression, drive, bit-crush, reverb, and delay. Reverb offers Small Room, Plate, Medium Hall, and Cathedral. Delay has time and feedback controls. Import audio, save/open JSON projects, and export the mix as a stereo WAV.
- **Filter:** per-track Off, resonant Low-pass/High-pass, or Band-pass, with logarithmic 20 Hz–20 kHz cutoff and resonance. “Automate filter cutoff” opens its timeline curve. Zero preserves the base cutoff; ±1 shifts it ±5 octaves, clamped to range. The filter must be enabled to hear its curve. Drive, bit-crush, resonance, delay time, and feedback also have automation lanes. Signal order: EQ → compression → drive → bit-crush → filter → reverb → delay. These are track effects for playback/export/AI references; the live instrument monitor remains dry. Older projects load with the new effects off and their original reverb/delay defaults.

Keyboard and MIDI instruments use Apple's built-in sound bank plus installed Logic/GarageBand EXS instruments. Added sounds: **House Kit** (Pure House), **Deep House Kit**, **TR-909 Kit**, **Oriental Kit** (Indian & Middle Eastern), and **Oud** (Turkish Oud Lute). These are real installed sample instruments, not synthesized substitutes. They are loaded in place; no Apple samples are bundled or redistributed. Keep the relevant Apple sound library installed. Missing instruments report an error instead of silently substituting another sound. House/Oriental kits open computer keys in octave 2; Oud opens in octave 3. MIDI note numbers are unchanged.

House, Deep House, and TR-909 drum groups are folded from their original Logic multi-output routing onto the app's stereo output. House has 17 mapped sounds (MIDI 36–58); Deep House has 23 (every note from MIDI 36–58); TR-909 has 16 (MIDI 36–56). Use computer-key octaves 2 and 3. These are drum maps: unassigned keys are silent, not transposed repetitions on every octave. In octave 2, `A` plays kick, `W` rim, `S` snare, `E` clap, `T` closed hi-hat, and `U` open hi-hat. TR-909's two kick AIFFs and Deep House's ride and first shaker require local WAV compatibility copies when restoring the sampler preset; these are cached under `~/Library/Caches/AI Music Sketchpad/KitSamples-v1`, preserve the original PCM/rate/channels, and do not modify the installed Apple library. The routing fix affects new playing/recording, not audio already rendered into existing clips.

There is no VST/effect plug-in hosting, input-device picker, or latency calibration yet. Keep saved project versions for important edits. Recorded performances are audio clips; changing project tempo does not time-stretch audio. Automation stays at its absolute time in seconds when tempo changes.

## Edit Notes (0.9.0, new recordings only)

New **Sound Library, Sketch Synth, Kick Lab, Oud Lab, Violin Lab and Shaker Lab keyboard/MIDI takes** support basic note editing. Double-click a clip, or right-click → **Edit Notes…**. Click a note and press Delete (or Delete Note); double-click empty space to add a note, using the selected length and quarter-beat snap. Scroll vertically for other pitches and horizontally through the source pattern. Apply rebuilds the audio; Cancel leaves it unchanged. Deleting all notes produces silence without changing the clip length. Undo restores the previous notes and audio file.

The editor changes the selected clip's source pattern, including its loop repetitions, while retaining trims, placement and duration. Other copies and the original audio file stay untouched. It renders from the take's starting instrument settings, so live knob movements are not preserved after Apply. Old recordings are deliberately not made editable. Imported audio, microphone takes, generated audio and third-party AU takes remain audio-only for editing. This first editor adds/deletes notes; it does not yet drag notes, change existing lengths/velocities, or audition within the editor.

## Instruments and add-ons (0.7.0)

Open **Recording Controls → Keyboard / MIDI → Instrument**. Each track remembers its instrument settings.

- **Sound library** keeps all existing instruments, including Signature and Aurora.
- **Sketch Synth** is our adjustable starter synthesizer: sine, saw, square and triangle, 32 voices, attack/decay/sustain/release, low-pass cutoff and output gain. Every MIDI pitch 0–127 is supported. Start with Bright lead, Soft pad, Round bass or Glass pluck, then edit the controls. It uses original local DSP; no samples, model or download. It is an internal modular instrument, not a standalone AU plug-in for other apps.
- **Audio Unit plug-in** lists registered Mac AU instruments (AUv2/AUv3 music devices), not effects, VSTs or MIDI-effect units. Select an instrument to load it; **Rescan** refreshes the list after installing one using its vendor's installer. **Open plug-in** opens its own editor when supplied. Factory presets and exposed writable parameters are also available. Apple AUSampler requires a sound bank loaded in its editor; choosing it alone does not supply a new sample library. Only load trusted plug-ins: native third-party code can hang or crash a host. This release uses the main audio output and MIDI channel 1, without multi-output routing or host-tempo synchronization.

Sketch Synth and AU takes capture the instrument's actual stereo audio while retaining played MIDI notes. Preset changes and knob movements during a take are baked into its audio; they are not editable parameter-automation lanes. Backing tracks are excluded. Existing recordings, mix exports and AI references continue to work even when the original plug-in is unavailable. Timeline playback uses rendered audio, not a live MIDI instrument. The take ends when you press Stop; leave time for release/reverb tails before stopping.

Save the project after editing a plug-in. Its document state is saved with the track and the initial recording preset with the clip. External sample libraries remain external and must still be installed to play that instrument live. An unavailable plug-in reports an error instead of replacing the sound. Built-in and synth setting edits support project undo; edits inside third-party plug-in windows/parameter controls use that plug-in's own facilities, not Sketchpad's undo stack. Generic parameter sliders are linear and do not provide host automation.

The AU path is tested with Apple's installed DLS instrument, including MIDI rendering and state restoration. Third-party plug-in compatibility, custom editors and physical MIDI hardware still require individual hands-on checks.

## Surge XT (0.10.2)

Install the **Surge XT Audio Unit** and **Resources** using the signed macOS installer from [the official Surge XT site](https://surge-synthesizer.github.io/), then restart Sketchpad. The factory library belongs in `/Library/Application Support/Surge XT`; keep it installed. Surge is an external, free/open-source plug-in, not bundled into Sketchpad or replaced by one of its internal synths.

Open **Recording Controls → Keyboard / MIDI** and click **Surge XT** beside the Instrument picker. This selects its installed AU. Click **Open Synth & Presets** (or the Surge XT shortcut again) for the complete editor and categorized patch browser. Use Surge's own patch browser even if the host's Factory Presets menu is empty. Oscillator types, layers, filters, modulation and effects are edited there. Play Sketchpad's piano/computer keys, Surge's virtual keyboard, or a connected MIDI keyboard. Save custom reusable patches in Surge; **Save Project** and track changes retain the current plug-in state per track.

**Computer Keys** is on by default in hosted plug-in windows. While Surge's editor has focus, use the same **A W S E D F T G Y H U J K L Ö Ä #** keys, **1–6** for octaves, and **Esc** to release notes. These notes also record into the selected track. Preset-search/name text fields keep normal typing; Command/Control/Option shortcuts pass through. Turn Computer Keys off for the plug-in's own letter shortcuts. Leaving or closing the editor releases its held computer keys. This is local to Sketchpad's plug-in window, not a system-wide keyboard hook, and requires no new permissions.

Record Track captures the actual stereo instrument output, including knob movements, with played MIDI-note metadata. Existing AU takes remain audio-only for editing: editable notes for third-party instruments are not added in this version. Audio playback/export works without the plug-in, but live playing and preset recall require Surge and its data to remain installed. No project is automatically switched to Surge. AUv2 Cocoa editors are now supported alongside AUv3 view controllers.

## Violin Lab and Shaker Lab (0.10.0)

Choose **Recording Controls → Keyboard / MIDI → Instrument → Violin Lab / Shaker Lab**. These are two new local sound generators, not preset packs or downloaded samples. Both support all MIDI pitches and all six computer-keyboard octaves, velocity, 32 voices, per-track settings, undo/redo, audio recording and editable notes in new takes. Their settings are optional in project files, so older projects still load unchanged.

- **Violin Lab:** synthesized bowed strings with harmonic body resonances and bow friction. Hold a key to sustain; release follows the Release control. Shape Bow pressure/rasp, Tone brightness, Body resonance, Vibrato depth, Attack, Release and Output. Middle/high octaves have the violin-inspired character; the full keyboard deliberately extends beyond an acoustic violin's range. This is an original bowed-string synthesizer, not a sampled solo violin or an exact acoustic simulation.
- **Shaker Lab:** randomized bead impacts excite a resonant shell, with a friction/noise layer. Tap for one shake; hold for repeated strokes at 2–16 shakes/second (free-running, not tempo-synced). Texture changes bead density/ring, Brightness changes the shell/filter, Decay sets each stroke's tail, and Output sets level. Higher keys raise the shell resonance. Key release stops repeats and leaves the current stroke's tail; Esc/Panic stops immediately.

Knob changes are captured in audio recordings. Edit Notes rebuilds from the starting instrument settings, as with the other internal instruments. No model/download is required. These add-ons run inside Sketchpad; they are not separately installable Audio Units for other apps. Existing instruments and the AI generation pipeline are unchanged.

## Oud Lab (0.9.1)

Choose **Recording Controls → Keyboard / MIDI → Instrument → Oud Lab** for an original synthesized oud-style plucked instrument. Pluck controls the excitation/tone, Warmth softens the harmonics, Decay sets the ring time, and Output sets the level. Chromatic notes use decaying harmonics, a slightly detuned paired course and a short plectrum-noise transient. Key release damps the sound. All MIDI notes are playable; the middle octaves are closest to an oud's character. This is a compact oud-inspired synthesizer, not a realistic sample library or an exact acoustic simulation. The existing sampled **Oud** remains unchanged in Sound Library.

Settings save per track and support undo/redo. New recordings capture audio and notes and work with Edit Notes using the starting preset, just like Sketch Synth. This is an internal instrument add-on, not a standalone AU for other apps; no downloads or model are needed.

## Kick Lab (0.8.0)

Choose **Recording Controls → Keyboard / MIDI → Instrument → Kick Lab**. This is our built-in kick-design add-on, not a separately installed AU. It synthesizes a pitch-swept sine body, short noise click and saturation locally, with no samples or downloads.

Tune (30–100 Hz), Decay, Sweep (semitones), Sweep time, Click, Drive and Output are adjustable. Start with **Deep House**, **909-inspired**, **Punch** or **Sub**. These are original synthesized presets, not recordings or exact emulations of commercial hardware. All keys/MIDI pitches trigger the same tuned kick; keyboard pitch does not transpose it. MIDI velocity controls loudness. Each hit runs its own one-shot decay even after key release; Esc/Panic stops it immediately. Leave its tail before pressing Stop.

Kick settings save per track and support undo/redo, just like Sketch Synth. Recording captures the actual sound and knob changes with note metadata. Existing projects without kick settings load unchanged.

## Signature Kit

Choose **Signature Kit** in the Sound picker. This is original, deterministic local synthesis: no Logic library, downloaded samples, or AI model is required. Every key in all six computer-keyboard octaves responds, with names shown on the keys.

| Octave shortcut | Sound group |
| --- | --- |
| 1 | 12 drum hits: kicks, snare, clap, hats, toms, rim, shaker, crash |
| 2 | 12 percussion/FX hits: congas, bongo, woodblock, claves, cowbell, tambourine, cabasa, metal, shaker, zap, riser |
| 3 | Chromatic sub/harmonic bass |
| 4 | Minor chords, transposed chromatically by root |
| 5 | Decaying harmonic plucks |
| 6 | Sustained harmonic leads |

Bass, chords, and leads sustain while held; percussion and plucks decay naturally. Minor chords have a fixed minor-triad shape, independent of the project key. The rightmost `K` key is the next octave's C, so it can enter the next sound group. Physical MIDI notes are unchanged: MIDI 24–95 covers the six groups, lower notes repeat the drum map, and higher notes extend the lead range. All MIDI notes 0–127 are mapped. The original House/Deep House/TR-909 mappings are unchanged.

The first selection synthesizes 28 mono 48 kHz source sounds and packs them into a 24-bit SoundFont at `~/Library/Caches/AI Music Sketchpad/SignatureKit-v4/Signature.sf2`. Later selections reuse the bank, and it can be regenerated if the cache is cleared. The same standard instrument-bank loader is used for live playing and recorded WAV rendering. Saved takes retain the Signature Kit identity and MIDI notes.

## Aurora Kit

The additional **Aurora Kit** leaves Signature Kit unchanged. It adds 28 original synthesized sources in six banks, with every MIDI note 0–127 mapped:

| Octave | Sounds |
| --- | --- |
| 1 | Neon drums: round/FM kicks, snap snare, air clap, hats, FM toms, laser rim, shaker, splash |
| 2 | Prism percussion: copper/crystal/steel bells, hollow block, marimba, kalimba, chime, glass hit, water drop, pulse tick, zap, swell |
| 3 | Pulse bass |
| 4 | Detuned major-seventh pads (fixed major-7 shape, independent of project key) |
| 5 | Decaying FM glass keys |
| 6 | Bright sustained orbit leads |

Like Signature, bass/pads/leads sustain until release and all other groups decay. Number keys 1–6 select computer-keyboard banks; physical MIDI pitches are not remapped. The local 24-bit bank is generated at first selection in `~/Library/Caches/AI Music Sketchpad/AuroraKit-v1/Aurora.sf2`. No downloads or model are required.

## Local audio generation

The default generator is **Meta MusicGen Small**, not an Ollama text model. Inference runs on this Mac using Metal when available. The first setup downloads approximately 2.4 GB of model weights plus Python dependencies; subsequent generation requires no network access. No prompts or audio are uploaded by this generator.

```bash
./scripts/setup-audio.sh
```

Setup requires [uv](https://docs.astral.sh/uv/getting-started/installation/). It creates an isolated Python environment and model cache under:

`~/Library/Application Support/AI Music Sketchpad/AudioRuntime`

The default audio model is already installed on this Mac. The app bundles the worker script; job progress and diagnostic logs are stored under `AudioRuntime/Jobs`.

Important limitations:

- Generate **1–300 seconds of new audio** per request. The custom end beat or bars is converted using project BPM. With a track input, choose 0.25–12 seconds of reference; the default is the last eight seconds (or the whole shorter clip/track). These reference limits do not cap the total new take.
- [MusicGen's context includes its audio prompt](https://huggingface.co/docs/transformers/v4.50.0/en/model_doc/musicgen). The worker keeps each model call within a 29-second context budget, then uses the last eight seconds of generated audio to continue. Each subsequent section regenerates a 20 ms overlap for a short crossfade. The full take keeps its requested duration and never includes reconstructed reference audio. The model loads once per job; progress reports section counts. A stalled section times out after 15 minutes. The finished take is published only after all sections succeed; Cancel stops the worker without appending a partial take.
- Longer requests need more time and can drift in style, harmony or rhythm across sections; continuation is not a guarantee of song-level structure or seamless musical transitions. Only the selected track's reference and the worker's own generated tail enter the model, never other tracks.
- BPM, key, and instrument instructions guide the model but do not guarantee a beat-perfect seamless loop, exact tuning, or isolated stems. Trim a useful region and repeat it as needed. Short edge fades reduce clicks, but do not beat-align the output.
- MusicGen Small outputs **32 kHz mono**. Conversion to the project's 48 kHz stereo format does not add fidelity or stereo information.
- The model weights use **CC BY-NC 4.0 (noncommercial)**. Check the [official model card and license](https://huggingface.co/facebook/musicgen-small) before commercial use; this app does not grant additional music rights.

The optional Text → Instrument notes (Ollama) mode instead asks a local text model for a short note pattern, repeats it to the requested length, and renders it with native instruments. Built-in instrument patterns are a separate, explicit choice. Errors are shown; neither model mode silently substitutes built-in patterns. Ollama connections are restricted to loopback addresses, and cloud-designated models are rejected.

## Build and test

```bash
./scripts/build-app.sh
open "build/AI Music Sketchpad.app"
./scripts/test.sh
./scripts/test.sh --audio-model   # also runs the installed model and cancellation test
./scripts/test.sh --local-kits    # every House/Deep House/TR-909 drum, distinctness, exact converted PCM; other kits load/render
./scripts/test.sh --signature-kit # all 128 notes, distinct sources, sustained loops/release, cache integrity
./scripts/test.sh --aurora-kit    # every note, distinct sources, sustained loops/release and kit metadata
./scripts/test.sh --track-workflow # complete single-track AI generation action
./scripts/test.sh --long-track-workflow # real local model: multi-section output past the timeline, exact duration and undo/redo
# Fast worker scheduling/crossfade tests (uses the installed audio runtime, no model inference):
"$HOME/Library/Application Support/AI Music Sketchpad/AudioRuntime/.venv/bin/python" -B scripts/test_audio_sections.py
```

Build requires Swift command-line tools. `./scripts/install-app.sh` builds and copies the app to `/Applications`; quit the app first before rebuilding or installing. The app uses a stable local ad-hoc signing requirement to reduce permission churn during local development.

Tests cover native instruments, audible automation export, isolated AI reference renders, copy/paste/cross-track move logic, offline export timing, resampling, trim/loop/split offsets, note capture, nested cursor observation, and project round-tripping. Visual interaction, microphone permission, physical MIDI hardware, and device latency require a hands-on check on the target Mac.

## Project assets

Imported, recorded, and generated assets are stored under:

`~/Library/Application Support/AI Music Sketchpad/Assets`

Project JSON files reference those assets by absolute path. Keep the assets when saving a project; move them and update paths when transferring a project to another Mac. Original source recordings are retained after trimming.
