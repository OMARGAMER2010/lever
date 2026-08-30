#!/usr/bin/env bash
# Arma un reparto de Windows como el que exporta RPG Maker y lo pasa por el porteador entero.
#
#   bash scripts/probar-nwjs.sh [versión] [mv|mz]
#
# Los dos repartos no se parecen y conviene probar los dos: MZ deja el juego suelto en la raíz y
# MV lo mete entero dentro de `www/`, con el manifiesto apuntando ahí.
#
# El juego de prueba hace exactamente las cuatro cosas de las que depende RPG Maker —leer sus
# datos con XHR desde file://, guardar con fs, arrancar WebGL y pintar— y deja el resultado en
# /tmp/lever-nw.log. Si sale «cuadros=30» y el píxel leído es naranja, el traslado funciona.
#
# La `nw.dll` se fabrica aquí en vez de bajar los 95 MB del reparto de Windows: lo único que Lever
# le lee es el recurso de versión, y eso sí es de verdad.
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-0.48.4}"
reparto="${2:-mz}"
case "$reparto" in
    mv) interior="www/" ;;
    mz) interior="" ;;
    *)  echo "reparto desconocido: $reparto (se espera mv o mz)" >&2; exit 2 ;;
esac
etiqueta="$(printf '%s' "$reparto" | tr '[:lower:]' '[:upper:]')"

taller="${TMPDIR:-/tmp}/lever-nwjs-$(date +%s)"
juego="$taller/reparto"
contenido="$juego/$interior"
mkdir -p "${contenido}js" "${contenido}data" "${contenido}img" "${contenido}css" "${contenido}icon"

echo "▸ Fabricando un reparto de RPG Maker ${etiqueta} con NW.js ${version}…"

python3 - "$juego/nw.dll" "$version" <<'PY'
import struct, sys

# Un PE mínimo pero válido con un recurso VS_VERSION_INFO dentro. Es el mismo molde que arma
# WindowsBinary en las pruebas: lo único que se lee de aquí son los cuatro enteros de la versión.
destino, version = sys.argv[1], sys.argv[2]
mayor, menor, parche = (list(map(int, version.split('.'))) + [0, 0, 0])[:3]

def le16(v): return struct.pack('<H', v)
def le32(v): return struct.pack('<I', v)

bloque = le16(0) + le16(52) + le16(0)
for c in 'VS_VERSION_INFO':
    bloque += le16(ord(c))
bloque += le16(0)
while len(bloque) % 4:
    bloque += b'\0'
bloque += le32(0xFEEF04BD) + le32(0x00010000) + le32(0) + le32(0)
bloque += le32((mayor << 16) | menor) + le32((parche << 16) | 0)
bloque += b'\0' * 28

def directorio(nombre, destino_rel, es_dir):
    d = le32(0) + le32(0) + le16(0) + le16(0) + le16(0) + le16(1)
    d += le32(nombre) + le32(destino_rel | 0x80000000 if es_dir else destino_rel)
    return d

RVA, CRUDO, PASO = 0x1000, 0x400, 24
seccion = directorio(16, PASO, True) + directorio(1, PASO * 2, True) + directorio(0x409, PASO * 3, False)
seccion += le32(RVA + PASO * 3 + 16) + le32(len(bloque)) + le32(0) + le32(0) + bloque

dos = bytearray(b'\0' * 64)
dos[0:2] = b'MZ'
dos[60:64] = le32(0x40)

coff = le16(0x8664) + le16(1) + le32(0) + le32(0) + le32(0) + le16(240) + le16(0x2022)
opcional = bytearray(b'\0' * 240)
opcional[0:2] = le16(0x20B)
opcional[128:136] = le32(RVA) + le32(len(seccion))

nombre = b'.rsrc' + b'\0' * 3
cabecera = nombre + le32(len(seccion)) + le32(RVA) + le32(len(seccion)) + le32(CRUDO) + b'\0' * 16

archivo = bytes(dos) + b'PE\0\0' + coff + bytes(opcional) + cabecera
archivo += b'\0' * (CRUDO - len(archivo)) + seccion
open(destino, 'wb').write(archivo)
PY

for f in node.dll ffmpeg.dll libEGL.dll libGLESv2.dll d3dcompiler_47.dll nw_elf.dll \
         resources.pak icudtl.dat v8_context_snapshot.bin nw_100_percent.pak credits.html; do
    printf 'motor' > "$juego/$f"
done
mkdir -p "$juego/locales" "$juego/swiftshader"
printf 'x' > "$juego/locales/en-US.pak"
printf 'nw.exe renombrado, como hace RPG Maker' > "$juego/Game.exe"
printf 'MZ' > "$juego/greenworks.node"
printf '{"nombre":"mapa uno","eventos":3}' > "${contenido}data/Map001.json"

cat > "$juego/package.json" <<JSON
{
  "name": "prueba-lever-${reparto}",
  "main": "${interior}index.html",
  "js-flags": "--expose-gc",
  "window": { "title": "Prueba Lever ${etiqueta}", "width": 816, "height": 624, "icon": "${interior}icon/icon.png" }
}
JSON

cat > "${contenido}index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Prueba Lever</title>
<style>html,body{margin:0;background:#141a2e;overflow:hidden}canvas{display:block}</style></head>
<body><canvas id="lienzo" width="816" height="624"></canvas>
<script src="js/main.js"></script></body></html>
HTML

cat > "${contenido}js/main.js" <<'JS'
var lineas = [];
function apunta(t) {
  lineas.push('LEVER-PRUEBA ' + t);
  try { require('fs').writeFileSync('/tmp/lever-nw.log', lineas.join('\n') + '\n'); } catch (e) {}
}
function mira(nombre, f) { try { apunta(nombre + '=' + f()); } catch (e) { apunta(nombre + '=FALLA:' + e.message); } }

apunta('arranca');
mira('version', function () { return process.versions.nw + ' chromium=' + process.versions.chromium; });

// RPG Maker carga sus mapas y su base de datos así, desde file://. Si Chromium lo bloquea, el
// juego se queda en la pantalla de carga para siempre.
var peticion = new XMLHttpRequest();
peticion.open('GET', 'data/Map001.json');
peticion.overrideMimeType('application/json');
peticion.onload = function () { apunta('xhr-local=' + peticion.responseText.replace(/\s+/g, '')); sigue(); };
peticion.onerror = function () { apunta('xhr-local=BLOQUEADO'); sigue(); };
peticion.send();

function sigue() {
  mira('guardar', function () {
    var fs = require('fs'), ruta = nw.__dirname + '/save';
    if (!fs.existsSync(ruta)) fs.mkdirSync(ruta);
    fs.writeFileSync(ruta + '/file1.rpgsave', 'partida');
    return fs.readFileSync(ruta + '/file1.rpgsave', 'utf8');
  });
  mira('webgl', function () {
    var gl = document.createElement('canvas').getContext('webgl');
    return gl ? gl.getParameter(gl.VERSION) : 'no';
  });

  // Con requestAnimationFrame no vale: si la ventana queda detrás, el navegador lo estrangula y
  // la prueba se cuelga sin llegar a dibujar.
  var ctx = document.getElementById('lienzo').getContext('2d');
  var cuadro = 0;
  var reloj = setInterval(function () {
    ctx.fillStyle = '#141a2e'; ctx.fillRect(0, 0, 816, 624);
    ctx.fillStyle = '#f0a028'; ctx.fillRect(60, 380, 200, 60);
    if (++cuadro === 30) {
      clearInterval(reloj);
      // Leer el píxel de vuelta demuestra que se pintó, no solo que se llamó a la API.
      var p = ctx.getImageData(100, 400, 1, 1).data;
      apunta('pixel=rgb(' + p[0] + ',' + p[1] + ',' + p[2] + ')');
      apunta('cuadros=' + cuadro);
      setTimeout(function () { try { nw.App.quit(); } catch (e) { window.close(); } }, 100);
    }
  }, 16);
}
JS

python3 - "${contenido}icon/icon.png" <<'PY'
import sys, zlib, struct
w = h = 256
filas = b''
for y in range(h):
    filas += b'\x00'
    for x in range(w):
        d = abs(x - w // 2) + abs(y - h // 2)
        filas += bytes((240, 160, 40) if d < 90 else (20, 26, 46))
def trozo(tag, datos):
    return struct.pack('>I', len(datos)) + tag + datos + struct.pack('>I', zlib.crc32(tag + datos) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + trozo(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
png += trozo(b'IDAT', zlib.compress(filas, 9)) + trozo(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY

echo "▸ Reparto listo en $juego"
exec bash "$raiz/scripts/probar-traslado.sh" "$juego/Game.exe" "${LEVER_CACHE:-}"
