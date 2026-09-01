#!/usr/bin/env bash
# Compila para macOS la parte nativa de GoZen, el complemento de vídeo de Godot.
#
# Por qué hace falta: Godot no reproduce H.264 de fábrica, así que los juegos con vídeo en .mp4
# cargan GoZen, que es FFmpeg envuelto en una GDExtension. El archivo .gdextension casi siempre
# declara macOS, pero la exportación de Windows solo mete el .dll. El código es libre (LGPL) y
# los binarios compilados son de pago, así que la vía honesta es compilarlo aquí.
#
# Uso:  build-gozen.sh <carpeta de salida> [arm64|x86_64]
# Deja en la carpeta de salida los .dylib con los dos nombres que Godot puede pedir, según se
# lance con una plantilla de exportación (template_release) o con el editor (template_debug).
set -euo pipefail

output_dir="${1:?Falta la carpeta de salida}"
arch="${2:-arm64}"

repo="https://codeberg.org/gozen/gde_gozen.git"
work="$(mktemp -d "${TMPDIR:-/tmp}/lever-gozen-XXXXXX")"
trap 'rm -rf "$work"' EXIT

step() { printf '▸ %s\n' "$1"; }
fail() { printf '✗ %s\n' "$1" >&2; exit 1; }

# ── Comprobaciones previas ────────────────────────────────────────────────────
# Se hacen todas antes de empezar: una compilación de FFmpeg son veinte minutos y no tiene
# ninguna gracia descubrir a mitad que falta cmake.

mkdir -p "$output_dir"

free_gb=$(df -g "$output_dir" | awk 'NR==2 {print $4}')
if [[ "${free_gb:-0}" -lt 8 ]]; then
    fail "Hacen falta unos 8 GB libres y solo hay ${free_gb} GB. Libera espacio y vuelve a intentarlo."
fi

if ! xcode-select -p > /dev/null 2>&1; then
    fail "Faltan las herramientas de línea de comandos de Xcode. Instálalas con: xcode-select --install"
fi

brew_bin=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$candidate" ]] && brew_bin="$candidate" && break
done

missing=()
for tool in scons cmake; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done
# FFmpeg necesita nasm para el ensamblador de Intel; en Apple Silicon usa NEON y no le hace falta.
if [[ "$arch" == "x86_64" ]] && ! command -v nasm > /dev/null 2>&1; then
    missing+=("nasm")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    [[ -n "$brew_bin" ]] || fail "Faltan ${missing[*]} y no hay Homebrew para instalarlos. Instálalo desde brew.sh."
    step "Instalando con Homebrew: ${missing[*]}"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$brew_bin" install "${missing[@]}"
fi

# ── Código fuente ─────────────────────────────────────────────────────────────
# Clones superficiales y solo los dos submódulos que se usan. Los otros tres (emsdk para web,
# libaom y libvpx para AV1 y VP9) son gigas que no hacen falta para reproducir H.264.

step "Descargando el código de GoZen"
git clone --depth 1 "$repo" "$work/gde_gozen" 2>&1 | sed 's/^/  /'
cd "$work/gde_gozen"

step "Descargando FFmpeg y godot-cpp"
git submodule update --init --depth 1 ffmpeg godot_cpp 2>&1 | sed 's/^/  /'

# Sin libaom ni libvpx compilados, el enlazado fallaría al buscarlos.
step "Ajustando la configuración de compilación"
python3 - <<'PY'
from pathlib import Path
path = Path("SConstruct")
text = path.read_text()
needle = '    env.Append(LIBS=["vpx", "aom"])\n    env.Append(LIBS=["z", "iconv", "m", "pthread"])'
if needle in text:
    path.write_text(text.replace(needle, '    env.Append(LIBS=["z", "iconv", "m", "pthread"])'))
    print("  SConstruct: fuera vpx y aom")
else:
    print("  SConstruct: ya estaba sin vpx ni aom")
PY

# ── FFmpeg ────────────────────────────────────────────────────────────────────
# El build.py oficial pasa --disable-asm en macOS, que apaga NEON entero y deja la
# descodificación de H.264 varias veces más lenta. Aquí se deja activo.

step "Compilando FFmpeg (es el paso largo, unos 15 minutos)"
cd ffmpeg
./configure \
    --prefix=./bin --disable-shared --enable-static --enable-pic \
    --arch="$arch" --pkg-config-flags=--static \
    --extra-ldflags=-mmacosx-version-min=11.0 \
    --extra-cflags="-fPIC -mmacosx-version-min=11.0" \
    --enable-securetransport --enable-swscale \
    --enable-demuxer=ogg --enable-demuxer=matroska,webm \
    --enable-decoder=vp8 --enable-decoder=vp9 --enable-parser=vp8 --enable-parser=vp9 \
    --enable-decoder=av1 --enable-parser=av1 \
    --enable-protocol=https --enable-protocol=tls \
    --enable-demuxer=gif --enable-decoder=gif \
    --enable-demuxer=apng --enable-decoder=apng \
    --enable-demuxer=image2 --enable-demuxer=image2pipe \
    --disable-bzlib --disable-lzma --disable-vaapi --disable-vdpau \
    --disable-cuda --disable-cuvid --disable-nvenc \
    --disable-muxers --disable-encoders --disable-postproc --disable-avdevice \
    --disable-avfilter --disable-sndio --disable-doc --disable-programs \
    --disable-ffprobe --disable-htmlpages --disable-manpages --disable-podpages \
    --disable-txtpages --disable-ffplay --disable-ffmpeg \
    --disable-hwaccels --disable-libdrm --disable-vulkan > /dev/null

grep -q '^CONFIG_H264_DECODER=yes' ffbuild/config.mak || fail "FFmpeg quedó sin descodificador de H.264."

make -j"$(sysctl -n hw.ncpu)" > /dev/null
make install > /dev/null
cd ..

# ── La GDExtension ────────────────────────────────────────────────────────────

step "Compilando la extensión para Godot"
scons -j"$(sysctl -n hw.ncpu)" platform=macos arch="$arch" target=template_release 2>&1 | tail -5

built="test_room/addons/gde_gozen/bin/libgozen.macos.template_release.$arch.dylib"
[[ -f "$built" ]] || fail "La compilación terminó sin generar la librería."

# El mismo binario con los dos nombres: la plantilla de exportación pide `template_release` y el
# editor de Godot pide `template_debug`. Son perfiles del motor, no de la librería.
cp "$built" "$output_dir/libgozen.macos.template_release.$arch.dylib"
cp "$built" "$output_dir/libgozen.macos.template_debug.$arch.dylib"

step "Listo: libgozen.macos.template_release.$arch.dylib"
