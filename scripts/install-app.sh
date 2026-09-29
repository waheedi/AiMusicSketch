#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_app="$project_dir/build/AI Music Sketchpad.app"
destination_app="/Applications/AI Music Sketchpad.app"

"$project_dir/scripts/build-app.sh"
ditto "$source_app" "$destination_app"
codesign --verify --strict "$destination_app"
open "$destination_app"
