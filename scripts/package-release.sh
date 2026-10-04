#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/AI Music Sketchpad.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo 'Invalid release version' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")" == "$version" ]]
codesign --verify --strict "$app_dir"
xcrun lipo "$app_dir/Contents/MacOS/AIMusicSketchpad" -verify_arch arm64 x86_64

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/aimusic-package.XXXXXX")"
package_dir="$stage_dir/AI Music Sketchpad-$version"
output_dir="$project_dir/build/release"
archive="AI-Music-Sketchpad-$version-macOS-universal.zip"
mkdir -p "$package_dir/scripts" "$output_dir"
ditto "$app_dir" "$package_dir/AI Music Sketchpad.app"
cp "$project_dir/LICENSE" "$project_dir/README.md" "$package_dir/"
cp "$project_dir/docs/INSTALL.md" "$package_dir/INSTALL.md"
cp "$project_dir/scripts/setup-audio.sh" "$project_dir/scripts/audio_worker.py" "$package_dir/scripts/"
ditto -c -k --sequesterRsrc --keepParent "$package_dir" "$output_dir/$archive"
cd "$output_dir"
shasum -a 256 "$archive" > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt

# Verify the actual distribution archive, not only the original build folder.
ditto -x -k "$archive" "$stage_dir/unpacked"
unpacked="$stage_dir/unpacked/AI Music Sketchpad-$version/AI Music Sketchpad.app"
codesign --verify --strict "$unpacked"
xcrun lipo "$unpacked/Contents/MacOS/AIMusicSketchpad" -verify_arch arm64 x86_64
echo "$output_dir/$archive"
