#!/usr/bin/env bash
# Compila Lever y arma el bundle .app en dist/.
#
# OJO: `swift build --show-bin-path` NO compila, solo imprime la ruta. Usarlo como único paso
# hacía que el .app se quedara con un binario viejo de .build/ y la ventana saliera vacía.
# Por eso aquí se compila primero, se pide la ruta después, y al final se comprueba que el
# binario copiado sea más nuevo que el código fuente.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

app_path="$project_root/dist/Lever.app"

echo "▸ Compilando (release)…"
swift build -c release --product Lever

bin_dir="$(swift build -c release --product Lever --show-bin-path)"
binary="$bin_dir/Lever"

if [[ ! -x "$binary" ]]; then
    echo "✗ No se generó el binario en $binary" >&2
    exit 1
fi

# Ningún archivo fuente puede ser más nuevo que el binario recién compilado.
newest_source="$(find Sources -name '*.swift' -newer "$binary" -print -quit || true)"
if [[ -n "$newest_source" ]]; then
    echo "✗ El binario es más viejo que $newest_source. La compilación no se aplicó." >&2
    exit 1
fi

echo "▸ Generando el icono…"
swift scripts/make-icon.swift Resources/AppIcon.iconset > /dev/null
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

echo "▸ Armando el bundle…"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary" "$app_path/Contents/MacOS/Lever"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
# El guion que monta el emulador viaja dentro: la app se abre desde el Escritorio, donde no hay
# código fuente cerca, y tiene que poder lanzarlo.
cp "$project_root/scripts/android-emulator.sh" "$app_path/Contents/Resources/android-emulator.sh"
# El guion que compila los complementos nativos de Godot viaja por el mismo motivo.
cp "$project_root/scripts/build-gozen.sh" "$app_path/Contents/Resources/build-gozen.sh"
printf 'APPL????' > "$app_path/Contents/PkgInfo"
chmod +x "$app_path/Contents/MacOS/Lever"

# Sin este atributo, Gatekeeper trata la app como descargada y pide permiso al abrirla.
xattr -cr "$app_path" 2>/dev/null || true

if command -v codesign > /dev/null 2>&1; then
    echo "▸ Firmando (ad-hoc, solo uso local)…"
    codesign --force --deep --sign - "$app_path" > /dev/null 2>&1 || true
fi

echo "✓ Listo: $app_path"
