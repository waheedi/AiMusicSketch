# AI Music Sketchpad

A native macOS multitrack sketchpad with local text-to-audio generation, microphone recording, and playable instruments. Requires macOS 15 or later; Apple Silicon is recommended for the audio model.

## Use

- **Per-track AI:** right-click a track or clip → AI • Improvise. Choose a reference range and describe the development you want. Only that track's actual audio (including recorded MIDI's instrument sound and its effects/automation) is rendered as input to MusicGen. Mute/solo and fader level are ignored for reference preparation. The model generates a continuation, not repair or faithful rewriting. Only new audio is appended after the same track's last clip; originals remain untouched. Each track remembers its AI settings, and generated clips retain reference provenance.
- **Generate from scratch:** choose New sound from prompt, describe a sound, choose length/seed, then generate at the red cursor. Cancel stops the model worker. Full mix produces one combined audio clip, not separated stems.
- **Playback:** the red cursor follows the audio clock. Click the ruler to seek, including during playback. Playback holds at the end; the rewind button returns to the beginning.
- **Edit:** right-click a clip for Loop ×2/×4, Stop Looping, Trim, or Split at Playhead. Right-click a track header for recording and clip actions. Drag clip edges inward for quick trims. Trimming is nondestructive, and loops repeat the selected source region.
- **Copy/repeat anywhere:** select a clip and use Copy / Paste (⌘C / ⌘V), or right-click Copy Clip. Click a destination track and time before pasting. ⌘D duplicates immediately after the selected clip. The internal clip clipboard preserves trim/loop metadata and references the same immutable audio asset; it is not an audio-file clipboard for other apps.
- **Dragging:** grab anywhere inside a clip to move it horizontally or onto another track; grab an edge only to trim. Snap ¼ beat can be disabled for free positioning, and Zoom enlarges small clips. The preview follows the snapped destination.
- **Automation:** click the connected-points button in a track header, then select Volume, Pan, EQ band, Compression, Reverb, or Delay. Click the lane to add a point and drag points in time/up/down; right-click a point to reset it to zero or delete it. Times are in seconds (50 ms placement grid), with linear interpolation and the final value held afterward. Zero means the base slider setting; offsets are clamped to the parameter's valid range. Add a final zero point to return to baseline. Curves affect playback, WAV export, and AI reference audio, and are saved with the project. Automation is track-level, so moving/copying a clip does not move its curves. Clear an envelope using the track's right-click menu.
- **Record:** select a track and open Recording Controls. Microphone / audio input uses the default input selected in macOS Sound settings. Allow microphone access when macOS asks. Use headphones to avoid recording speaker playback.
- **Play instruments:** choose Keyboard / MIDI, choose an instrument, and click the piano to give it focus. Play `A W S E D F T G Y H U J K`, or connect a MIDI keyboard and press Refresh. The octave control affects computer keys only. Sustain pedal is supported. Record Track captures notes while the other tracks play; Stop & Save Take adds the rendered take and retains its note data.
- **Mix:** up to eight tracks, volume, pan, mute/solo, EQ, compression, reverb, and delay. Import audio, save/open JSON projects, and export the mix as a stereo WAV.

Keyboard and MIDI instruments use Apple's built-in sound bank plus installed Logic/GarageBand EXS instruments. Added sounds: **House Kit** (Pure House), **Deep House Kit**, **TR-909 Kit**, **Oriental Kit** (Indian & Middle Eastern), and **Oud** (Turkish Oud Lute). These are real installed sample instruments, not synthesized substitutes. They are loaded in place; no Apple samples are bundled or redistributed. Keep the relevant Apple sound library installed. Missing instruments report an error instead of silently substituting another sound. House/Oriental kits open computer keys in octave 2; Oud opens in octave 3. MIDI note numbers are unchanged.

House, Deep House, and TR-909 drum groups are folded from their original Logic multi-output routing onto the app's stereo output. House has 17 mapped sounds (MIDI 36–58); Deep House has 23 (every note from MIDI 36–58); TR-909 has 16 (MIDI 36–56). Use computer-key octaves 2 and 3. These are drum maps: unassigned keys are silent, not transposed repetitions on every octave. In octave 2, `A` plays kick, `W` rim, `S` snare, `E` clap, `T` closed hi-hat, and `U` open hi-hat. TR-909's two kick AIFFs and Deep House's ride and first shaker require local WAV compatibility copies when restoring the sampler preset; these are cached under `~/Library/Caches/AI Music Sketchpad/KitSamples-v1`, preserve the original PCM/rate/channels, and do not modify the installed Apple library. The routing fix affects new playing/recording, not audio already rendered into existing clips.

There is no piano-roll editor, plugin hosting, input-device picker, latency calibration, or undo history yet. Keep saved project versions for important edits. Recorded performances are rendered as audio clips; changing project tempo does not time-stretch audio. Automation stays at its absolute time in seconds when tempo changes.

## Local audio generation

The default generator is **Meta MusicGen Small**, not an Ollama text model. Inference runs on this Mac using Metal when available. The first setup downloads approximately 2.4 GB of model weights plus Python dependencies; subsequent generation requires no network access. No prompts or audio are uploaded by this generator.

```bash
./scripts/setup-audio.sh
```

Setup requires [uv](https://docs.astral.sh/uv/getting-started/installation/). It creates an isolated Python environment and model cache under:

`~/Library/Application Support/AI Music Sketchpad/AudioRuntime`

The default audio model is already installed on this Mac. The app bundles the worker script; job progress and diagnostic logs are stored under `AudioRuntime/Jobs`.

Important limitations:

- Generate 1–29 seconds per request. With a track input, choose 0.25–12 seconds of reference and keep reference + new audio at or below 29 seconds. The default reference is the last eight seconds (or the whole shorter clip/track). The form shows the exact selected range; audio outside it is not sent to the model. Bar lengths are converted using project BPM.
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
./scripts/test.sh --track-workflow # complete single-track AI generation action
```

Build requires Swift command-line tools. `./scripts/install-app.sh` builds and copies the app to `/Applications`; quit the app first before rebuilding or installing. The app uses a stable local ad-hoc signing requirement to reduce permission churn during local development.

Tests cover native instruments, audible automation export, isolated AI reference renders, copy/paste/cross-track move logic, offline export timing, resampling, trim/loop/split offsets, note capture, nested cursor observation, and project round-tripping. Visual interaction, microphone permission, physical MIDI hardware, and device latency require a hands-on check on the target Mac.

## Project assets

Imported, recorded, and generated assets are stored under:

`~/Library/Application Support/AI Music Sketchpad/Assets`

Project JSON files reference those assets by absolute path. Keep the assets when saving a project; move them and update paths when transferring a project to another Mac. Original source recordings are retained after trimming.
