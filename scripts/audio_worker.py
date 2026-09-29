"""Local MusicGen worker. Setup downloads weights; generation is strictly offline."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import time

MODEL = "facebook/musicgen-small"
REVISION = "4c8334b02c6ec4e8664a91979669a501ec497792"
RUNTIME = Path.home() / "Library/Application Support/AI Music Sketchpad/AudioRuntime"
os.environ.setdefault("HF_HOME", str(RUNTIME / "cache"))
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def download():
    from huggingface_hub import snapshot_download
    location = snapshot_download(
        MODEL, revision=REVISION,
        allow_patterns=["*.json", "*.safetensors", "*.model", "README.md"],
    )
    # Marker is written only after the pinned snapshot finishes downloading.
    (RUNTIME / "ready.json").write_text(json.dumps({"model": MODEL, "revision": REVISION, "snapshot": location}))
    print(f"Ready: {location}", flush=True)


def generate(request_path):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    request = json.loads(Path(request_path).read_text())
    progress = Path(request["progress"])

    def report(message, fraction=0):
        scratch = progress.with_suffix(".pending")
        scratch.write_text(json.dumps({"message": message, "fraction": fraction}))
        scratch.replace(progress)

    try:
        seconds = float(request["seconds"])
        if not 1 <= seconds <= 29:
            raise ValueError("Choose a loop between 1 and 29 seconds (reduce bars or increase BPM).")
        report("Loading the local audio model…")
        import numpy as np
        import soundfile as sf
        import torch
        from transformers import MusicgenProcessor, MusicgenForConditionalGeneration, StoppingCriteria, StoppingCriteriaList
        from scipy.signal import resample_poly

        torch.set_num_threads(min(8, os.cpu_count() or 4))
        seed = int(request.get("seed", 42))
        torch.manual_seed(seed)
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        # Explicit class is required: this checkpoint's AutoProcessor metadata
        # resolves to a text-only T5 tokenizer under transformers 4.57.
        processor = MusicgenProcessor.from_pretrained(MODEL, revision=REVISION, local_files_only=True)
        model = MusicgenForConditionalGeneration.from_pretrained(
            MODEL, revision=REVISION, local_files_only=True, attn_implementation="eager"
        ).to(device).eval()
        prompt = request["prompt"]
        rate = int(model.config.audio_encoder.sampling_rate)
        reference_frames = 0
        reference_tokens = 0
        if request.get("referenceAudio"):
            report("Encoding the selected track as the audio prompt…")
            info = sf.info(request["referenceAudio"])
            if not 0.25 <= info.duration <= 12.001:
                raise ValueError("The track reference must be 0.25–12 seconds.")
            if info.duration + seconds > 29.001:
                raise ValueError("Reference plus new audio must be at most 29 seconds. Reduce the new bars or reference range.")
            reference, source_rate = sf.read(request["referenceAudio"], dtype="float32", always_2d=True)
            reference = reference.mean(axis=1)
            if not np.isfinite(reference).all() or np.max(np.abs(reference)) < 1e-5:
                raise ValueError("The selected reference is silent or invalid. Choose a range containing audible notes.")
            divisor = math.gcd(source_rate, rate)
            reference = resample_poly(reference, rate // divisor, source_rate // divisor).astype(np.float32)
            reference /= max(1.0, float(np.max(np.abs(reference))))
            # Align to complete codec frames so removing the reconstructed prompt
            # never returns part of the input as if it were newly generated audio.
            hop = math.prod(model.config.audio_encoder.upsampling_ratios)
            reference_frames = math.ceil(len(reference) / hop) * hop
            reference = np.pad(reference, (0, reference_frames - len(reference)))
            reference_tokens = reference_frames // hop
            # Call the two components explicitly: transformers 4.57's generic
            # processor dispatch can forward `audio` to the text tokenizer.
            inputs = processor.tokenizer([prompt], padding=True, return_tensors="pt")
            inputs.update(processor.feature_extractor(reference, sampling_rate=rate, padding=True, return_tensors="pt"))
            inputs = inputs.to(device)
        else:
            inputs = processor(text=[prompt], padding=True, return_tensors="pt").to(device)
        # 50 codec frames per second, plus the codebook delay and a small tail.
        tokens = min(1490, math.ceil(seconds * 50) + 12)
        started = time.monotonic()

        class Progress(StoppingCriteria):
            last = 0
            def __call__(self, input_ids, scores, **kwargs):
                count = max(0, input_ids.shape[-1] - reference_tokens)
                if count - self.last >= 25:
                    self.last = count
                    percentage = min(98, int(count / tokens * 100))
                    report(f"Generating audio on {device.upper()}: {percentage}%", count / tokens)
                if time.monotonic() - started > 900:
                    raise TimeoutError("Audio generation took more than 15 minutes. Try fewer bars.")
                return False

        report(f"Generating audio on {device.upper()}…", 0.01)
        with torch.inference_mode():
            audio = model.generate(
                **inputs, do_sample=True, guidance_scale=3.0, max_new_tokens=tokens,
                stopping_criteria=StoppingCriteriaList([Progress()]),
            )
        samples = audio[0, 0].float().cpu().numpy()
        length = round(seconds * rate)
        if len(samples) < reference_frames + length:
            raise ValueError("The audio model stopped before the requested loop length. Try again.")
        samples = samples[reference_frames:reference_frames + length].copy()
        if not np.isfinite(samples).all() or np.max(np.abs(samples)) < 1e-5:
            raise ValueError("The model generated silent or invalid audio. Try another prompt.")
        # Preserve duration while making the seam quiet; BPM/key are prompt guidance,
        # not hard constraints of MusicGen. Do not claim beat-perfect tempo adherence.
        fade = min(round(0.008 * rate), length // 4)
        samples[:fade] *= np.linspace(0, 1, fade)
        samples[-fade:] *= np.linspace(1, 0, fade)
        peak = float(np.max(np.abs(samples)))
        if peak > 0.98:
            samples *= 0.98 / peak
        sf.write(request["output"], samples, rate, subtype="FLOAT")
        report("Audio loop ready", 1)
        print(json.dumps({"output": request["output"], "sampleRate": rate, "device": device,
                          "seconds": len(samples) / rate, "seed": seed,
                          "referenceSeconds": reference_frames / rate}), flush=True)
    except Exception as error:
        report(str(error))
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--request")
    args = parser.parse_args()
    if args.download:
        RUNTIME.mkdir(parents=True, exist_ok=True)
        download()
    elif args.request:
        generate(args.request)
    else:
        parser.error("Use --download or --request")
