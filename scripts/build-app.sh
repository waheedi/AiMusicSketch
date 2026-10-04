#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/AI Music Sketchpad.app"

cd "$project_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
if [[ "${1:-}" == --universal ]]; then
    [[ $# == 1 ]] || { echo 'Usage: build-app.sh [--universal]' >&2; exit 1; }
    deployment_target="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
    binaries=()
    for architecture in arm64 x86_64; do
        build_arguments=(-c release --triple "$architecture-apple-macosx$deployment_target" --scratch-path ".build/universal-$architecture")
        swift build "${build_arguments[@]}"
        bin_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
        binaries+=("$bin_dir/AIMusicSketchpad")
    done
    xcrun lipo -create "${binaries[@]}" -output "$app_dir/Contents/MacOS/AIMusicSketchpad"
else
    swift build -c release "$@"
    bin_dir="$(swift build -c release "$@" --show-bin-path)"
    cp "$bin_dir/AIMusicSketchpad" "$app_dir/Contents/MacOS/AIMusicSketchpad"
fi
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/scripts/audio_worker.py" "$app_dir/Contents/Resources/audio_worker.py"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"

codesign --force --sign - \
    --identifier local.bargo.AIMusicSketchpad \
    --requirements '=designated => identifier "local.bargo.AIMusicSketchpad"' \
    "$app_dir"

codesign --verify --strict "$app_dir"

echo "$app_dir"
