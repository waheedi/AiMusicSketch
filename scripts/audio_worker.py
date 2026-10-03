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
# MusicGen's 30-second context includes its audio prompt. Leave codec headroom.
WINDOW_SECONDS = 29
CONTEXT_SECONDS = 8
MAX_OUTPUT_SECONDS = 300
os.environ.setdefault("HF_HOME", str(RUNTIME / "cache"))
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def section_plan(total_frames, rate, hop, reference_frames=0):
    """Frame-exact schedule; every model call fits within its context window."""
    if rate <= 0 or hop <= 0 or not rate <= total_frames <= MAX_OUTPUT_SECONDS * rate:
        raise ValueError("Choose 1–300 seconds of new audio.")
    if not 0 <= reference_frames <= math.ceil(12 * rate / hop) * hop:
        raise ValueError("The track reference must be at most 12 seconds.")
    plan, completed = [], 0
    while completed < total_frames:
        overlap = min(round(0.02 * rate), completed) if completed else 0
        context = reference_frames if not completed else min(round(CONTEXT_SECONDS * rate), reference_frames + completed - overlap)
        aligned_context = math.ceil(context / hop) * hop
        capacity = math.floor((WINDOW_SECONDS * rate - aligned_context) / hop) * hop
        added = min(total_frames - completed, capacity - overlap)
        if added <= 0:
            raise ValueError("The reference leaves no room for new audio in this section.")
        plan.append({"context": context, "aligned_context": aligned_context,
                     "overlap": overlap, "new_frames": added + overlap, "added_frames": added})
        completed += added
    return plan


def continue_sections(total_frames, rate, hop, reference, generate_chunk, report):
    """Generate new audio, not repeated copies; reuse the preceding tail as input.

    At a join the next prompt ends 20 ms before the existing output ends. The
    model regenerates that overlap, which is crossfaded without shortening time.
    """
    import numpy as np
    prefix = np.asarray(reference, dtype=np.float32) if reference is not None else np.empty(0, dtype=np.float32)
    plan = section_plan(total_frames, rate, hop, len(prefix))
    output = np.empty(0, dtype=np.float32)
    for index, section in enumerate(plan):
        if index == 0:
            context = prefix.copy()
        else:
            history = np.concatenate((prefix, output))
            end = len(history) - section["overlap"]
            context = history[end - section["context"]:end].copy()
        if len(context) < section["aligned_context"]:
            context = np.pad(context, (0, section["aligned_context"] - len(context)))
        if len(context):
            context /= max(1.0, float(np.max(np.abs(context))))
        report(index + 1, len(plan), len(output), 0)
        new = np.asarray(generate_chunk(context, section["new_frames"], index + 1, len(plan), len(output)), dtype=np.float32)
        if new.ndim != 1 or len(new) != section["new_frames"]:
            raise ValueError("The audio model stopped before the requested section ended.")
        if not np.isfinite(new).all() or np.max(np.abs(new)) < 1e-5:
            raise ValueError("The model generated silent or invalid audio. Try another prompt.")
        overlap = section["overlap"]
        if overlap:
            weight = np.linspace(0, 1, overlap, dtype=np.float32)
            output[-overlap:] = output[-overlap:] * (1 - weight) + new[:overlap] * weight
        output = np.concatenate((output, new[overlap:]))
    if len(output) != total_frames:
        raise ValueError("Continuation duration mismatch.")
    return output, len(plan)


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
        if not math.isfinite(seconds) or not 1 <= seconds <= MAX_OUTPUT_SECONDS:
            raise ValueError("Choose 1–300 seconds of new audio.")
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
        hop = math.prod(model.config.audio_encoder.upsampling_ratios)
        reference = None
        if request.get("referenceAudio"):
            report("Encoding the selected track as the audio prompt…")
            info = sf.info(request["referenceAudio"])
            if not 0.25 <= info.duration <= 12.001:
                raise ValueError("The track reference must be 0.25–12 seconds.")
            reference, source_rate = sf.read(request["referenceAudio"], dtype="float32", always_2d=True)
            reference = reference.mean(axis=1)
            if not np.isfinite(reference).all() or np.max(np.abs(reference)) < 1e-5:
                raise ValueError("The selected reference is silent or invalid. Choose a range containing audible notes.")
            divisor = math.gcd(source_rate, rate)
            reference = resample_poly(reference, rate // divisor, source_rate // divisor).astype(np.float32)
            reference /= max(1.0, float(np.max(np.abs(reference))))
            # Align to complete codec frames so removing the reconstructed prompt
            # never returns part of the input as if it were newly generated audio.
            reference_frames = math.ceil(len(reference) / hop) * hop
            reference = np.pad(reference, (0, reference_frames - len(reference)))

        length = round(seconds * rate)

        def section_progress(index, count, completed, fraction):
            overall = min(0.99, (completed + fraction) / length)
            report(f"Generating section {index}/{count} on {device.upper()}: {int(overall * 100)}%", overall)

        def generate_chunk(context, frames, index, count, completed):
            # Call the two components explicitly: transformers 4.57's generic
            # processor dispatch can forward `audio` to the text tokenizer.
            inputs = processor.tokenizer([prompt], padding=True, return_tensors="pt")
            if len(context):
                inputs.update(processor.feature_extractor(context, sampling_rate=rate, padding=True, return_tensors="pt"))
            inputs = inputs.to(device)
            tokens = math.ceil(frames / hop) + 12
            reference_tokens = len(context) // hop
            started = time.monotonic()

            class Progress(StoppingCriteria):
                last = 0
                def __call__(self, input_ids, scores, **kwargs):
                    generated = max(0, input_ids.shape[-1] - reference_tokens)
                    if generated - self.last >= 25:
                        self.last = generated
                        section_progress(index, count, completed, min(frames, generated / tokens * frames))
                    if time.monotonic() - started > 900:
                        raise TimeoutError("One continuation section took more than 15 minutes. Try a shorter request.")
                    return False

            with torch.inference_mode():
                audio = model.generate(
                    **inputs, do_sample=True, guidance_scale=3.0, max_new_tokens=tokens,
                    stopping_criteria=StoppingCriteriaList([Progress()]),
                )
            decoded = audio[0, 0].float().cpu().numpy()
            # Drop the reconstructed prompt, never return it as new music.
            if len(decoded) < len(context) + frames:
                raise ValueError("The audio model stopped before the requested section ended. Try again.")
            return decoded[len(context):len(context) + frames].copy()

        samples, sections = continue_sections(length, rate, hop, reference, generate_chunk, section_progress)
        # Preserve duration while making the seam quiet; BPM/key are prompt guidance,
        # not hard constraints of MusicGen. Do not claim beat-perfect tempo adherence.
        fade = min(round(0.008 * rate), length // 4)
        samples[:fade] *= np.linspace(0, 1, fade)
        samples[-fade:] *= np.linspace(1, 0, fade)
        peak = float(np.max(np.abs(samples)))
        if peak > 0.98:
            samples *= 0.98 / peak
        output = Path(request["output"])
        temporary = progress.parent / "completed-audio.wav"
        try:
            sf.write(temporary, samples, rate, subtype="FLOAT")
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
        report("Audio take ready", 1)
        print(json.dumps({"output": request["output"], "sampleRate": rate, "device": device,
                          "seconds": len(samples) / rate, "seed": seed,
                          "sections": sections, "referenceSeconds": 0 if reference is None else len(reference) / rate}), flush=True)
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
