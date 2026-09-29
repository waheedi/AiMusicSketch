#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
runtime="$HOME/Library/Application Support/AI Music Sketchpad/AudioRuntime"
uv_bin="${commands[uv]:-$HOME/.local/bin/uv}"
if [[ ! -x "$uv_bin" ]]; then
    echo "Install uv first: https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi
if [[ ! -x "$runtime/.venv/bin/python" ]]; then
    "$uv_bin" venv --python 3.12 "$runtime/.venv"
fi
"$uv_bin" pip install --python "$runtime/.venv/bin/python" \
    'torch==2.9.1' 'transformers==4.57.6' 'soundfile==0.13.1' 'sentencepiece==0.2.1' 'numpy<3' scipy
"$runtime/.venv/bin/python" "$project_dir/scripts/audio_worker.py" --download
