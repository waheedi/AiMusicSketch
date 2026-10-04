#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output="${TMPDIR:-/tmp}/AIMusicSketchpadSmokeTest"

cd "$project_dir"
clang++ -std=c++17 -O2 -I Sources/SketchSynthDSP/include -c Sources/SketchSynthDSP/SketchSynthDSP.cpp -o "$output-dsp.o"
swiftc -parse-as-library \
    -I Sources/SketchSynthDSP/include "$output-dsp.o" -lc++ \
    Sources/AIMusicSketchpad/InstrumentAddOns.swift \
    Sources/AIMusicSketchpad/InstrumentAudioCapture.swift \
    Sources/AIMusicSketchpad/InstrumentControls.swift \
    Sources/AIMusicSketchpad/TimelineFollow.swift \
    Sources/AIMusicSketchpad/StudioShortcuts.swift \
    Sources/AIMusicSketchpad/Models.swift \
    Sources/AIMusicSketchpad/GenerationOutputRange.swift \
    Sources/AIMusicSketchpad/Automation.swift \
    Sources/AIMusicSketchpad/MIDIRenderer.swift \
    Sources/AIMusicSketchpad/SignatureKit.swift \
    Sources/AIMusicSketchpad/SignatureSoundBank.swift \
    Sources/AIMusicSketchpad/AuroraKit.swift \
    Sources/AIMusicSketchpad/ProjectHistory.swift \
    Sources/AIMusicSketchpad/LLMComposer.swift \
    Sources/AIMusicSketchpad/AudioEngineController.swift \
    Sources/AIMusicSketchpad/AssetManager.swift \
    Sources/AIMusicSketchpad/ClipEditing.swift \
    Sources/AIMusicSketchpad/ClipNoteLayout.swift \
    Sources/AIMusicSketchpad/ClipNoteView.swift \
    Sources/AIMusicSketchpad/RecordingController.swift \
    Sources/AIMusicSketchpad/RecordingViews.swift \
    Sources/AIMusicSketchpad/TextAudioGenerator.swift \
    Sources/AIMusicSketchpad/TrackAudioReference.swift \
    Sources/AIMusicSketchpad/StudioModel.swift \
    scripts/SmokeTest.swift \
    scripts/InstrumentTests.swift \
    -o "$output"
"$output" "$@"
