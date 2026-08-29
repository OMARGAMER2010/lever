#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

swift build -c release --product ExeRar
bin_dir="$(swift build -c release --show-bin-path)"
app_path="$project_root/dist/EXE-RAR.app"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/ExeRar" "$app_path/Contents/MacOS/ExeRar"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
chmod +x "$app_path/Contents/MacOS/ExeRar"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$app_path" >/dev/null 2>&1 || true
fi

printf 'Built %s\n' "$app_path"
