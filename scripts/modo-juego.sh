#!/usr/bin/env bash
# Deja el Mac lo más despejado posible y lanza un juego de la consola híbrida.
#
# Por qué existe: en un Mac de 8 GB el emulador no es el cuello de botella. Con el navegador y un
# par de apps abiertas el sistema ya está pasando memoria a disco **antes** de abrir el juego, y a
# partir de ahí cada tirón es el SSD, no la GPU. Este guion mide eso, enseña quién se la está
# comiendo, deja cerrar lo que sobre, y arranca el juego en pantalla completa para que macOS active
# su Modo Juego.
#
# No cierra nada por su cuenta: pregunta. Cerrarle el navegador a alguien sin avisar es exactamente
# la clase de sorpresa que este proyecto no da.
set -euo pipefail

JUEGO="${1:-}"
RYUJINX="/Applications/Ryujinx.app"
# Lo que casi siempre sobra mientras se juega. El orden es el de "cuánto suele pesar".
PESADAS=("Google Chrome" "Safari" "Firefox" "Spotify" "Slack" "Discord")

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
gris()  { printf '\033[2m%s\033[0m\n' "$*"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }

# ── Qué hay ahora ────────────────────────────────────────────────────────────
memoria() {
    local libre usado
    libre=$(memory_pressure 2>/dev/null | awk -F: '/free percentage/{gsub(/[ %]/,"",$2); print $2}')
    usado=$(sysctl -n vm.swapusage | awk '{gsub(/M/,"",$6); print $6}')
    printf '  memoria libre: %s%%   ·   swap en uso: %s MB\n' "${libre:-?}" "${usado:-?}"
}

azul "▸ Estado antes"
memoria

# Los procesos de un navegador son muchos y pequeños; sumarlos por app es lo que dice la verdad.
azul "▸ Lo que más memoria ocupa"
ps -Ao rss=,comm= | awk '
    { nombre=$2; for (i=3; i<=NF; i++) nombre = nombre " " $i
      # Todo lo que viva dentro de un .app cuenta para ese .app.
      if (match(nombre, /\/[^\/]+\.app\//)) { sub(/\/Contents\/.*/, "", nombre) }
      sub(/.*\//, "", nombre); sub(/\.app$/, "", nombre)
      suma[nombre] += $1 }
    END { for (n in suma) if (suma[n] > 100000) printf "  %6.0f MB  %s\n", suma[n]/1024, n }
' | sort -rn | head -8

# ── Cerrar lo que sobre ──────────────────────────────────────────────────────
abiertas=()
for app in "${PESADAS[@]}"; do
    if pgrep -qx "$app" 2>/dev/null || osascript -e "application \"$app\" is running" 2>/dev/null | grep -q true; then
        abiertas+=("$app")
    fi
done

if [[ ${#abiertas[@]} -gt 0 ]]; then
    echo
    azul "▸ Abiertas y prescindibles mientras juegas:"
    printf '     %s\n' "${abiertas[@]}"
    read -r -p "   ¿Las cierro? [s/N] " respuesta
    if [[ "${respuesta:-n}" =~ ^[sSyY]$ ]]; then
        for app in "${abiertas[@]}"; do
            # `quit` y no `kill`: da a la app la ocasión de guardar lo suyo.
            osascript -e "tell application \"$app\" to quit" 2>/dev/null || true
            gris "     cerrada: $app"
        done
        sleep 3
        azul "▸ Estado después"
        memoria
    else
        gris "     no se cierra nada"
    fi
else
    gris "  (nada pesado abierto)"
fi

# ── Lanzar ───────────────────────────────────────────────────────────────────
if [[ -z "$JUEGO" ]]; then
    echo
    gris "Sin archivo: solo se ha despejado el Mac."
    gris "Uso: $(basename "$0") /ruta/al/juego.xci"
    exit 0
fi

[[ -r "$JUEGO" ]] || { echo "✗ No se puede leer: $JUEGO" >&2; exit 1; }
[[ -d "$RYUJINX" ]] || { echo "✗ No está $RYUJINX" >&2; exit 1; }

# App Nap estrangula lo que macOS cree ocioso. Un emulador con la ventana detrás lo parece.
defaults write org.ryujinx.Ryujinx NSAppSleepDisabled -bool YES 2>/dev/null || true

echo
azul "▸ Lanzando $(basename "$JUEGO")"
open -a "$RYUJINX" --args "$JUEGO"

# Pantalla completa: es lo que enciende el Modo Juego de macOS, que da prioridad de CPU y GPU al
# juego y **dobla la frecuencia del Bluetooth** —o sea, menos retardo en el mando—. No se puede
# activar a mano desde fuera: se activa cuando una app de categoría juego entra en pantalla completa.
gris "  esperando a que abra la ventana…"
for _ in $(seq 1 40); do
    sleep 1
    if osascript -e 'tell application "System Events" to exists (window 1 of process "Ryujinx")' 2>/dev/null | grep -q true; then
        sleep 4   # que termine de cargar antes de cambiar de modo
        osascript -e 'tell application "System Events" to keystroke "f" using {control down, command down}' 2>/dev/null || true
        verde "✓ En pantalla completa. El Modo Juego debería estar activo (mira el icono del mando en la barra de menús)."
        exit 0
    fi
done
gris "  la ventana tardó más de la cuenta; ponla en pantalla completa a mano (Ctrl+Cmd+F)"
