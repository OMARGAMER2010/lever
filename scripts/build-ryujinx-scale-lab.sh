#!/bin/bash
set -euo pipefail

# Este script es del laboratorio: Lever no lo ejecuta ni descarga un emulador.
if [[ $# -ne 2 ]]; then
    echo 'Uso: scripts/build-ryujinx-scale-lab.sh CHECKOUT_RYUJINX DIRECTORIO_SALIDA' >&2
    exit 2
fi
lever_root="$(cd "$(dirname "$0")/.." && pwd)"
ryujinx_source="$(cd "$1" && pwd)"
mkdir -p "$2"
lab_output="$(cd "$2" && pwd)"
expected_revision=e2143d43bcb6762340d8a01f20e7b5fdf104f02f
if [[ "$(git -C "$ryujinx_source" rev-parse HEAD)" != "$expected_revision" ]]; then
    echo 'El parche solo se ha preparado para el commit oficial 1.3.3 documentado.' >&2
    exit 1
fi
lab_patch="$lever_root/patches/ryujinx-1.3.3-scale.patch"
if ! git -C "$ryujinx_source" apply --reverse --check "$lab_patch" 2>/dev/null; then
    git -C "$ryujinx_source" apply --check "$lab_patch"
    git -C "$ryujinx_source" apply "$lab_patch"
fi
cd "$ryujinx_source"
dotnet run --project "$lever_root/patches/scale-check/ScaleCheck.csproj" \
    --artifacts-path "$lab_output/scale-check" \
    -p:RyujinxSource="$ryujinx_source"
dotnet restore src/Ryujinx/Ryujinx.csproj -r osx-arm64 \
    -p:RuntimeIdentifiers=osx-arm64 --disable-parallel -v minimal
dotnet publish src/Ryujinx/Ryujinx.csproj -c Release -r osx-arm64 \
    --self-contained true --no-restore -m:2 -p:RuntimeIdentifiers=osx-arm64 \
    -p:Version=1.3.3 -p:SourceRevisionId=lever-scale1 -p:DebugType=embedded \
    -p:ExtraDefineConstants=DISABLE_UPDATER -p:LangVersion=13.0 \
    -o "$lab_output/publish"
cd distribution/macos
./create_app_bundle.sh "$lab_output/publish" "$lab_output/app" "$PWD/entitlements.xml"
lab_app="$lab_output/app/Ryujinx.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleLongVersionString 1.3.3-lever-scale1' "$lab_app/Contents/Info.plist"
# Identifica la corrección de geometría; no promete rendimiento para todos los juegos.
/usr/libexec/PlistBuddy -c 'Add :LeverTextureScaleGeometryVersion integer 1' "$lab_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$PWD/entitlements.xml" "$lab_app"
codesign --verify --deep --strict "$lab_app"
echo "$lab_app"
