# Install AI Music Sketchpad

## Mac app

Requires **macOS 15 or later**. The universal app contains Apple Silicon and Intel builds. Apple Silicon is recommended; the optional MusicGen setup is intended for Apple Silicon. Intel builds are cross-compiled, not hardware-tested.

1. Download the universal ZIP and `SHA256SUMS.txt` from the same [GitHub release](https://github.com/waheedi/AiMusicSketch/releases).
2. Optionally verify the download in Terminal from the download folder: `shasum -a 256 -c SHA256SUMS.txt`.
3. Extract the ZIP and drag **AI Music Sketchpad.app** into **Applications**. Keep the extracted `scripts` folder if you want local AI generation.
4. Open the app. Allow microphone access only if you want to record an audio input.

This community build is **ad-hoc signed, not Developer ID signed or Apple-notarized**. macOS can block the first launch. If you trust this release, follow Apple's [Open Anyway instructions](https://support.apple.com/en-us/102445) in System Settings → Privacy & Security after attempting to open it. Do not disable Gatekeeper system-wide.

## Optional sounds and AI

- The native mixer, recording tools and original synthesized instruments do not need an AI model.
- For **Surge XT**, install its **Audio Unit** and **Resources** from [Surge's official site](https://surge-synthesizer.github.io/), then reopen Sketchpad. Surge and its presets are not included in this download.
- Some library sounds require your own installed Logic/GarageBand content. No Apple sound libraries are redistributed.
- For **MusicGen prompt-to-audio**, first install [uv](https://docs.astral.sh/uv/getting-started/installation/). Then run `zsh scripts/setup-audio.sh` from the extracted release folder. Setup downloads Python dependencies and about 2.4 GB of model weights. The model runtime is separate from the app and lives under `~/Library/Application Support/AI Music Sketchpad/AudioRuntime`. Subsequent generation runs locally.
- MusicGen Small's weights have a **CC BY-NC 4.0 noncommercial license**, separate from this app's Apache-2.0 license. See the [model card](https://huggingface.co/facebook/musicgen-small) before commercial use. No model weights are bundled.
- Ollama note generation is optional and needs a separately installed local Ollama service and model.

## Known limitations

Audio Unit takes retain rendered audio and note metadata, but third-party AU notes are not currently editable. Plug-ins execute inside the host process. Projects reference audio assets and external plug-ins; moving the project JSON alone is not a self-contained project transfer.
