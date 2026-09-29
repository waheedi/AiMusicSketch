#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output="${TMPDIR:-/tmp}/AIMusicSketchpadSmokeTest"

cd "$project_dir"
swiftc -parse-as-library \
    Sources/AIMusicSketchpad/Models.swift \
    Sources/AIMusicSketchpad/Automation.swift \
    Sources/AIMusicSketchpad/MIDIRenderer.swift \
    Sources/AIMusicSketchpad/LLMComposer.swift \
    Sources/AIMusicSketchpad/AudioEngineController.swift \
    Sources/AIMusicSketchpad/AssetManager.swift \
    Sources/AIMusicSketchpad/ClipEditing.swift \
    Sources/AIMusicSketchpad/RecordingController.swift \
    Sources/AIMusicSketchpad/TextAudioGenerator.swift \
    Sources/AIMusicSketchpad/TrackAudioReference.swift \
    Sources/AIMusicSketchpad/StudioModel.swift \
    scripts/SmokeTest.swift \
    -o "$output"
"$output" "$@"
