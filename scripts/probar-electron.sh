#!/usr/bin/env bash
# Arma un juego de Electron para Windows con la herramienta oficial y lo pasa por el porteador.
#
#   bash scripts/probar-electron.sh [versión de Electron]
#
# El reparto lo genera `@electron/packager`, no este guion: así lo que se traslada es lo que un
# desarrollador repartiría de verdad, con su `app.asar` y su `.exe` renombrado.
#
# Y lleva un módulo nativo **de verdad** —better-sqlite3, instalado con npm y con su binario de
# Windows puesto encima—, porque es lo único que comprueba el resolvedor de partes nativas de punta
# a punta: el juego lo carga y lo usa al arrancar, así que si el `.node` siguiera siendo el de
# Windows, o fuera de otro ABI, la prueba lo dice.
#
# La versión de Electron por omisión es la 42.10.1 a propósito: su ABI es el 146, el más nuevo para
# el que better-sqlite3 12.11.1 publica binarios de macOS y de Windows a la vez.
#
# Hacen falta node y npx.
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-42.10.1}"
modulo=better-sqlite3
moduloVersion=12.11.1
abiWindows=146

if ! command -v npx >/dev/null; then
    echo "✗ hacen falta node y npx para generar el reparto de prueba" >&2
    exit 1
fi

taller="${TMPDIR:-/tmp}/lever-electron-$(date +%s)"
app="$taller/app"
mkdir -p "$app"

cat > "$app/package.json" <<JSON
{
  "name": "prueba-lever-electron",
  "productName": "Faro Rojo",
  "version": "1.0.0",
  "main": "main.js",
  "dependencies": { "$modulo": "$moduloVersion" }
}
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

// La prueba de fuego del resolvedor: cargar un módulo nativo de verdad y usarlo. Un .node de otra
// plataforma o de otro ABI no carga, y revienta aquí mismo con un error que se puede leer.
try {
  const Database = require('better-sqlite3');
  const db = new Database(':memory:');
  db.exec('create table t (n integer)');
  db.prepare('insert into t values (?)').run(7);
  apunta('modulo-nativo=' + db.prepare('select n from t').get().n);
  db.close();
} catch (e) {
  apunta('modulo-nativo=FALLA:' + e.message);
}

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

echo "▸ Instalando el módulo nativo ($modulo $moduloVersion)…"
( cd "$app" && npm install --silent --no-audit --no-fund >/dev/null 2>&1 )
if [ ! -d "$app/node_modules/$modulo" ]; then
    echo "✗ no se pudo instalar $modulo" >&2
    exit 1
fi

# npm baja el binario de esta máquina. Se sustituye por el de Windows, que es lo que traería un
# reparto de verdad y lo que el porteador tiene que reconocer y cambiar.
echo "▸ Poniéndole el binario de Windows…"
curl -sL --fail --max-time 300 -o "$taller/win.tar.gz" \
  "https://github.com/WiseLibs/$modulo/releases/download/v$moduloVersion/$modulo-v$moduloVersion-electron-v$abiWindows-win32-x64.tar.gz"
rm -rf "$app/node_modules/$modulo/build"
tar xzf "$taller/win.tar.gz" -C "$app/node_modules/$modulo"
file "$app/node_modules/$modulo/build/Release/"*.node | sed 's|.*/||;s/:/ →/'

echo "▸ Empaquetando para Windows con @electron/packager…"
# `--asar.unpack` saca los .node fuera del archivo, que es lo que hace cualquier empaquetador:
# dlopen no sabe abrir una librería metida dentro de otro archivo. `--no-prune` deja el árbol de
# node_modules tal cual lo dejó npm, para que la prueba sea reproducible.
( cd "$taller" && npx --yes @electron/packager app "Faro Rojo" \
    --platform=win32 --arch=x64 --electron-version="$version" --out=salida --overwrite \
    --no-prune --asar.unpack="**/*.node" >/dev/null )

reparto="$taller/salida/Faro Rojo-win32-x64"
echo "▸ Reparto listo en $reparto"
find "$reparto/resources/app.asar.unpacked" -name '*.node' 2>/dev/null | sed "s|$reparto/|   nativo suelto: |"

exec bash "$raiz/scripts/probar-traslado.sh" "$reparto/Faro Rojo.exe" "${LEVER_CACHE:-}"
