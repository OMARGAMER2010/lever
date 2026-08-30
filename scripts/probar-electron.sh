#!/usr/bin/env bash
# Arma un juego de Electron para Windows con la herramienta oficial y lo pasa por el porteador.
#
#   bash scripts/probar-electron.sh [versión de Electron]
#
# El reparto lo genera `@electron/packager`, no este guion: así lo que se traslada es lo que un
# desarrollador repartiría de verdad, con su `app.asar` y su `.exe` renombrado. El juego hace lo
# mismo que el de NW.js —abre una ventana, pinta naranja y lee el píxel de vuelta— y deja el rastro
# en /tmp/lever-electron.log.
#
# Hace falta node y npx. Es la herramienta del propio motor: fabricar el reparto a mano sería
# comprobar mi idea del formato en vez del formato.
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-44.0.0}"

if ! command -v npx >/dev/null; then
    echo "✗ hace falta node/npx para generar el reparto de prueba" >&2
    exit 1
fi

taller="${TMPDIR:-/tmp}/lever-electron-$(date +%s)"
app="$taller/app"
mkdir -p "$app/node_modules/better-sqlite3"

cat > "$app/package.json" <<'JSON'
{
  "name": "prueba-lever-electron",
  "productName": "Faro Rojo",
  "version": "1.0.0",
  "main": "main.js",
  "dependencies": { "better-sqlite3": "12.2.0" }
}
JSON

# Un módulo nativo declarado: no se usa, pero su package.json viaja dentro del asar y su .node
# suelto en app.asar.unpacked, que es exactamente donde Lever tiene que encontrarlo.
cat > "$app/node_modules/better-sqlite3/package.json" <<'JSON'
{ "name": "better-sqlite3", "version": "12.2.0" }
JSON

cat > "$app/main.js" <<'JS'
const { app, BrowserWindow, ipcMain } = require('electron');
const fs = require('fs');

// El registro lo escribe el proceso principal: es el único que siempre tiene Node, pase lo que
// pase con la configuración de la ventana.
const lineas = [];
function apunta(t) {
  lineas.push('LEVER-PRUEBA ' + t);
  try { fs.writeFileSync('/tmp/lever-electron.log', lineas.join('\n') + '\n'); } catch (e) {}
}

apunta('arranca electron=' + process.versions.electron + ' chromium=' + process.versions.chrome);
apunta('node=' + process.versions.node + ' abi=' + process.versions.modules + ' arch=' + process.arch);

ipcMain.on('lever', (_e, texto) => {
  apunta(texto);
  if (texto.startsWith('cuadros=')) setTimeout(() => app.quit(), 200);
});

app.whenReady().then(() => {
  const ventana = new BrowserWindow({
    width: 640, height: 480, show: true,
    webPreferences: { nodeIntegration: true, contextIsolation: false }
  });
  ventana.loadFile('index.html');
});
app.on('window-all-closed', () => app.quit());
JS

cat > "$app/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Prueba Lever Electron</title>
<style>html,body{margin:0;background:#141a2e;overflow:hidden}canvas{display:block}</style></head>
<body><canvas id="lienzo" width="640" height="480"></canvas>
<script src="render.js"></script></body></html>
HTML

cat > "$app/render.js" <<'JS'
const { ipcRenderer } = require('electron');
const fs = require('fs');
function di(t) { ipcRenderer.send('lever', t); }

try {
  di('fs-local=' + (fs.existsSync(__dirname + '/package.json') ? 'ok' : 'no'));
} catch (e) { di('fs-local=FALLA:' + e.message); }
try {
  const gl = document.createElement('canvas').getContext('webgl');
  di('webgl=' + (gl ? gl.getParameter(gl.VERSION) : 'no'));
} catch (e) { di('webgl=FALLA:' + e.message); }

// Con requestAnimationFrame no vale: si la ventana queda detrás, Chromium lo estrangula y la
// prueba se cuelga sin llegar a dibujar. Es la misma trampa que con NW.js.
const ctx = document.getElementById('lienzo').getContext('2d');
let cuadro = 0;
const reloj = setInterval(() => {
  ctx.fillStyle = '#141a2e'; ctx.fillRect(0, 0, 640, 480);
  ctx.fillStyle = '#f0a028'; ctx.fillRect(60, 200, 200, 60);
  if (++cuadro === 30) {
    clearInterval(reloj);
    const p = ctx.getImageData(100, 220, 1, 1).data;
    di('pixel=rgb(' + p[0] + ',' + p[1] + ',' + p[2] + ')');
    di('cuadros=' + cuadro);
  }
}, 16);
JS

echo "▸ Empaquetando para Windows con @electron/packager…"
( cd "$taller" && npx --yes @electron/packager app "Faro Rojo" \
    --platform=win32 --arch=x64 --electron-version="$version" --out=salida --overwrite \
    --no-prune >/dev/null )
# `--no-prune` porque el módulo nativo de la prueba está declarado pero no instalado de verdad; sin
# eso packager lo poda y el asar se queda sin su package.json, que es de donde sale su versión.

reparto="$taller/salida/Faro Rojo-win32-x64"
# El .node suelto: el empaquetador saca los binarios del asar porque dlopen no sabe leer de dentro.
mkdir -p "$reparto/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release"
printf 'MZ binario de windows' \
    > "$reparto/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

echo "▸ Reparto listo en $reparto"
exec bash "$raiz/scripts/probar-traslado.sh" "$reparto/Faro Rojo.exe" "${LEVER_CACHE:-}"
