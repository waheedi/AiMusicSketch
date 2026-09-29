#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/AI Music Sketchpad.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/AIMusicSketchpad" "$app_dir/Contents/MacOS/AIMusicSketchpad"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/scripts/audio_worker.py" "$app_dir/Contents/Resources/audio_worker.py"

codesign --force --sign - \
    --identifier local.bargo.AIMusicSketchpad \
    --requirements '=designated => identifier "local.bargo.AIMusicSketchpad"' \
    "$app_dir"

codesign --verify --strict "$app_dir"

echo "$app_dir"
