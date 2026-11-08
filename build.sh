#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
project_dir="${0:A:h}"
if (( $# != 1 )); then
  print -u2 "Usage: $0 /absolute/path/to/App.app"
  exit 2
fi
app_path="$1"
if [[ "$app_path" != /*.app || -e "$app_path" ]]; then
  print -u2 "Choose an absolute .app path that does not exist"
  exit 2
fi
scratch="$(mktemp -d /private/tmp/helpful-build.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/${app_path:t}"
contents="$bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$scratch/Icon.iconset"
cp "$project_dir/Info.plist" "$contents/Info.plist"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -Osize -whole-module-optimization \
  "$project_dir"/Sources/*.swift -o "$contents/MacOS/HelpfulUtilities"
strip -x "$contents/MacOS/HelpfulUtilities"
for size in 16 32 128; do
  double=$((size * 2))
  sips -z "$size" "$size" "$project_dir/Icon.png" --out "$scratch/Icon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$project_dir/Icon.png" --out "$scratch/Icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$scratch/Icon.iconset" -o "$contents/Resources/Icon.icns"
codesign --force --sign - --identifier local.helpful.utilities "$bundle"
codesign --verify --strict "$bundle"
ditto --norsrc "$bundle" "$app_path"
