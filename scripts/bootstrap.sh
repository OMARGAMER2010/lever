#!/usr/bin/env bash
# Arranque desde cero, con un solo comando:
#
#   curl -fsSL https://raw.githubusercontent.com/OMARGAMER2010/lever/main/scripts/bootstrap.sh | bash
#
# Trae el código y arranca la instalación guiada, que te va preguntando.
#
# Si prefieres leer lo que vas a ejecutar antes de ejecutarlo —que es lo sensato—, clona el
# repositorio a mano y lanza scripts/install.sh. Hace exactamente lo mismo.
set -uo pipefail

repo="${LEVER_REPO:-https://github.com/OMARGAMER2010/lever.git}"
dir="${LEVER_DIR:-$HOME/Lever}"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
lang="es"; case "${LANG:-}" in en*) lang="en" ;; esac

t() {
    if [[ "$lang" == "en" ]]; then
        case "$1" in
            title)   echo "Lever · setup" ;;
            plan)    echo "First the code comes down, then a guided install that asks you at each step." ;;
            where)   echo "Where should the code go?" ;;
            confirm) echo "Use %s? [Y/n]: " ;;
            other)   echo "Path: " ;;
            noTTY)   echo "No terminal to ask questions in. Clone it by hand and run scripts/install.sh" ;;
            noGit)   echo "The Xcode command line tools are missing, and they bring git. Install them with:" ;;
            cloning) echo "Downloading the code…" ;;
            updating) echo "Already there. Bringing it up to date…" ;;
            failed)  echo "Could not download the code. Check your connection and try again." ;;
            got)     echo "Code is in %s" ;;
        esac
    else
        case "$1" in
            title)   echo "Lever · instalación" ;;
            plan)    echo "Primero baja el código, y después una instalación guiada que te va preguntando." ;;
            where)   echo "¿Dónde quieres el código?" ;;
            confirm) echo "¿Lo pongo en %s? [S/n]: " ;;
            other)   echo "Ruta: " ;;
            noTTY)   echo "No hay terminal donde preguntarte. Clona a mano y lanza scripts/install.sh" ;;
            noGit)   echo "Faltan las herramientas de línea de órdenes de Xcode, que traen git. Instálalas con:" ;;
            cloning) echo "Bajando el código…" ;;
            updating) echo "Ya estaba. Lo pongo al día…" ;;
            failed)  echo "No se pudo bajar el código. Mira tu conexión y vuelve a intentarlo." ;;
            got)     echo "El código está en %s" ;;
        esac
    fi
}

# Con `curl | bash` la entrada estándar es el propio guion, así que las preguntas hay que
# leerlas del terminal: con `read` a secas se comería el código que queda por ejecutar.
# No basta con que /dev/tty exista: en un proceso sin terminal de control está ahí y no se
# puede abrir. Se comprueba abriéndolo en una subcapa, que es la única forma honesta.
if ! (exec < /dev/tty) 2>/dev/null; then
    printf '\n%s▸ %s%s\n\n' "$yellow" "$(t noTTY)" "$reset"
    exit 1
fi

printf '\n%s▸ %s%s\n\n' "$bold" "$(t title)" "$reset"
printf '%s  %s%s\n\n' "$dim" "$(t plan)" "$reset"

printf '  %s\n' "$(t where)"
printf '  '
# shellcheck disable=SC2059
read -r -p "$(printf "$(t confirm)" "$dir")" answer < /dev/tty
case "${answer:-s}" in
    s|S|y|Y|"") : ;;
    *) printf '  '; read -r -p "$(t other)" chosen < /dev/tty; dir="${chosen:-$dir}" ;;
esac
dir="${dir/#\~/$HOME}"

# /usr/bin/git está en todos los Mac aunque no haya herramientas de desarrollo: es un atajo que,
# sin ellas, solo abre el instalador y falla. Así que no vale preguntar si existe; hay que probarlo.
if ! git --version > /dev/null 2>&1; then
    printf '\n  %s✗%s  %s\n\n      xcode-select --install\n\n' "$yellow" "$reset" "$(t noGit)"
    exit 1
fi

if [[ -d "$dir/.git" ]]; then
    printf '\n%s▸ %s%s\n' "$bold" "$(t updating)" "$reset"
    git -C "$dir" pull --ff-only --quiet || true
else
    printf '\n%s▸ %s%s\n' "$bold" "$(t cloning)" "$reset"
    if ! git clone --quiet "$repo" "$dir"; then
        printf '\n%s▸ %s%s\n\n' "$yellow" "$(t failed)" "$reset"
        exit 1
    fi
fi
# shellcheck disable=SC2059
printf '%s  ✓ ' "$green"; printf "$(t got)" "$dir"; printf '%s\n' "$reset"

# La instalación guiada lee sus preguntas del terminal, por el mismo motivo.
exec bash "$dir/scripts/install.sh" --lang "$lang" < /dev/tty
