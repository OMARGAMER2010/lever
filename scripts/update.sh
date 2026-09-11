#!/usr/bin/env bash
# Actualiza Lever: trae el código nuevo, lo compila y reemplaza la app del Escritorio.
#
# Lo lanza Lever desde su banner de versión nueva, en una ventana de Terminal a propósito: traer
# el código y compilarlo tarda un par de minutos, y una app que se queda muda ese rato parece
# colgada. Además hay que cerrar Lever para poder reemplazarla, así que el progreso no cabe dentro.
#
# Se compila ANTES de tocar la app instalada: si la compilación falla, te quedas con la que tenías.
set -uo pipefail

repo="${LEVER_REPO:-https://github.com/OMARGAMER2010/lever.git}"
app="$HOME/Desktop/Lever.app"
previa="$HOME/Library/Application Support/Lever/backups/Lever-previa.app"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
lang="es"; case "${LANG:-}" in en*) lang="en" ;; esac

t() {
    if [[ "$lang" == "en" ]]; then
        case "$1" in
            title)    echo "Updating Lever" ;;
            source)   echo "Source: %s" ;;
            cloning)  echo "Getting the code…" ;;
            pulling)  echo "Bringing the code up to date…" ;;
            noCode)   echo "Could not get the code. Your current Lever is untouched." ;;
            quitting) echo "Closing Lever so it can be replaced…" ;;
            building) echo "Building. This is the part that takes a couple of minutes." ;;
            buildBad) echo "The build failed. Your current Lever is untouched — nothing was replaced." ;;
            swapping) echo "Replacing the app…" ;;
            kept)     echo "The previous one is kept at %s" ;;
            done)     echo "Done. Opening Lever." ;;
            enter)    echo "Press return to close this window." ;;
        esac
    else
        case "$1" in
            title)    echo "Actualizando Lever" ;;
            source)   echo "Código: %s" ;;
            cloning)  echo "Trayendo el código…" ;;
            pulling)  echo "Poniendo el código al día…" ;;
            noCode)   echo "No se pudo traer el código. Tu Lever de ahora se queda como está." ;;
            quitting) echo "Cerrando Lever para poder reemplazarla…" ;;
            building) echo "Compilando. Esta es la parte que tarda un par de minutos." ;;
            buildBad) echo "La compilación falló. Tu Lever de ahora se queda como está: no se reemplazó nada." ;;
            swapping) echo "Reemplazando la app…" ;;
            kept)     echo "La anterior queda guardada en %s" ;;
            done)     echo "Listo. Abriendo Lever." ;;
            enter)    echo "Pulsa retorno para cerrar esta ventana." ;;
        esac
    fi
}
di()   { printf '\n%s▸ %s%s\n' "$bold" "$1" "$reset"; }
mal()  { printf '\n%s▸ %s%s\n\n' "$yellow" "$1" "$reset"; printf '%s' "$dim"; read -r -p "$(t enter)" _ || true; printf '%s\n' "$reset"; exit 1; }

printf '\n%s▸ %s%s\n' "$bold" "$(t title)" "$reset"

# ── ¿Dónde está el código? ──────────────────────────────────────────────────
# Primero donde se compiló esta app, que build-app.sh anota dentro del bundle. Si ya no existe
# —carpeta movida o borrada—, se usa o se clona ~/Lever.
dir="${LEVER_DIR:-}"
if [[ -z "$dir" && -f "$app/Contents/Info.plist" ]]; then
    dir="$(/usr/libexec/PlistBuddy -c "Print :LeverSourcePath" "$app/Contents/Info.plist" 2>/dev/null || true)"
fi
[[ -d "$dir/.git" ]] || dir="$HOME/Lever"

if [[ -d "$dir/.git" ]]; then
    # shellcheck disable=SC2059
    printf '%s  '  "$dim"; printf "$(t source)" "$dir"; printf '%s\n' "$reset"
    di "$(t pulling)"
    git -C "$dir" pull --ff-only || mal "$(t noCode)"
else
    di "$(t cloning)"
    git clone --quiet "$repo" "$dir" || mal "$(t noCode)"
fi

# ── Compilar primero, reemplazar después ────────────────────────────────────
di "$(t building)"
bash "$dir/scripts/build-app.sh" || mal "$(t buildBad)"
[[ -d "$dir/dist/Lever.app" ]] || mal "$(t buildBad)"

di "$(t quitting)"
osascript -e 'tell application "Lever" to quit' > /dev/null 2>&1 || true
for _ in 1 2 3 4 5 6; do pgrep -qf "Desktop/Lever.app/Contents/MacOS/Lever" || break; sleep 1; done

di "$(t swapping)"
mkdir -p "$(dirname "$previa")"
if [[ -d "$app" ]]; then
    rm -rf "$previa"
    ditto "$app" "$previa"
    # shellcheck disable=SC2059
    printf '%s  ' "$dim"; printf "$(t kept)" "$previa"; printf '%s\n' "$reset"
fi
rm -rf "$app"
ditto "$dir/dist/Lever.app" "$app"
xattr -cr "$app" 2>/dev/null || true
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$app" > /dev/null 2>&1 || true

printf '\n%s✓ %s%s\n\n' "$green" "$(t done)" "$reset"
open "$app"
