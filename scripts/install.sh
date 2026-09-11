#!/usr/bin/env bash
# El único comando que hace falta. Te lleva paso a paso, te dice qué va a pasar antes de cada
# cosa, y no hace nada que no hayas confirmado. Al final tienes Lever.app en el Escritorio.
#
# Uso:  bash scripts/install.sh [opciones]
#
#   --yes          No preguntar nada, aceptar todo. Para guiones o para quien ya lo sabe.
#   --lang es|en   Fuerza el idioma. Si no, sale del idioma del sistema.
#   --help         Esto.
set -uo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

lang="es"; case "${LANG:-}" in en*) lang="en" ;; esac
assume_yes=false

while (( $# )); do
    case "$1" in
        --yes|-y) assume_yes=true ;;
        --lang) shift; lang="${1:-es}" ;;
        --help|-h) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
# Sin terminal delante nadie puede contestar: o se acepta todo a propósito, o no se sigue.
[[ -t 0 ]] || assume_yes=true

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
TOTAL=5

t() {
    if [[ "$lang" == "en" ]]; then
        case "$1" in
            step)       echo "Step %s of %s · %s" ;;
            welcome)    echo "Welcome" ;;
            whatWeDo)   echo "This is what's about to happen:" ;;
            plan1)      echo "Check that your Mac can build it" ;;
            plan2)      echo "Look at what's missing, and ask before downloading anything" ;;
            plan3)      echo "Build the app from this source" ;;
            plan4)      echo "Leave Lever.app on your Desktop" ;;
            noRush)     echo "Nothing is installed without you saying yes. You can stop at any point." ;;
            go)         echo "Shall we start? [Y/n]: " ;;
            stopped)    echo "Stopped. Nothing was changed." ;;
            checking)   echo "Requirements" ;;
            macOK)      echo "macOS %s" ;;
            macOld)     echo "Lever needs macOS 13 or newer, and this is %s." ;;
            swiftOK)    echo "Swift %s" ;;
            noSwift)    echo "Swift is missing, and it is what builds the app. Install the command line tools with:" ;;
            brewOK)     echo "Homebrew" ;;
            noBrew)     echo "Homebrew (optional here, but it installs almost everything else)" ;;
            deps)       echo "What's missing" ;;
            depsIntro)  echo "Next comes the list of pieces with their size. You choose there." ;;
            depsWarn)   echo "Something was left out. The app opens anyway and tells you what it needs." ;;
            build)      echo "Build" ;;
            buildIntro) echo "Compiling takes a couple of minutes and needs no decisions from you." ;;
            buildGo)    echo "Build now? [Y/n]: " ;;
            buildFail)  echo "The build failed. Nothing was installed; the output above says why." ;;
            install)    echo "Install" ;;
            installTo)  echo "It goes here: %s" ;;
            installGo)  echo "Copy it there? [Y/n]: " ;;
            replacing)  echo "There is already a Lever.app there. It gets replaced." ;;
            ready)      echo "Ready" ;;
            openNow)    echo "Open it now? [Y/n]: " ;;
            yours)      echo "What's still up to you: emulators, console keys and firmware. Lever finds them and launches them, it doesn't hand them out." ;;
            readMore)   echo "How each part works: README.en.md" ;;
        esac
    else
        case "$1" in
            step)       echo "Paso %s de %s · %s" ;;
            welcome)    echo "Bienvenido" ;;
            whatWeDo)   echo "Esto es lo que va a pasar:" ;;
            plan1)      echo "Comprobar que tu Mac puede compilarla" ;;
            plan2)      echo "Mirar qué falta, y preguntar antes de descargar nada" ;;
            plan3)      echo "Compilar la app desde este código" ;;
            plan4)      echo "Dejar Lever.app en tu Escritorio" ;;
            noRush)     echo "No se instala nada sin que digas sí. Puedes parar en cualquier punto." ;;
            go)         echo "¿Empezamos? [S/n]: " ;;
            stopped)    echo "Parado. No se cambió nada." ;;
            checking)   echo "Requisitos" ;;
            macOK)      echo "macOS %s" ;;
            macOld)     echo "Lever necesita macOS 13 o más nuevo, y este es %s." ;;
            swiftOK)    echo "Swift %s" ;;
            noSwift)    echo "Falta Swift, que es quien compila la app. Instala las herramientas de línea de órdenes con:" ;;
            brewOK)     echo "Homebrew" ;;
            noBrew)     echo "Homebrew (aquí es opcional, pero instala casi todo lo demás)" ;;
            deps)       echo "Lo que falta" ;;
            depsIntro)  echo "Ahora viene la lista de piezas con su tamaño. Ahí eliges tú." ;;
            depsWarn)   echo "Algo quedó fuera. La app se abre igual y te dice qué necesita." ;;
            build)      echo "Compilar" ;;
            buildIntro) echo "Compilar tarda un par de minutos y no hace falta que decidas nada." ;;
            buildGo)    echo "¿Compilamos? [S/n]: " ;;
            buildFail)  echo "La compilación falló. No se instaló nada; arriba dice por qué." ;;
            install)    echo "Instalar" ;;
            installTo)  echo "Va aquí: %s" ;;
            installGo)  echo "¿La copiamos ahí? [S/n]: " ;;
            replacing)  echo "Ya hay una Lever.app ahí. Se reemplaza." ;;
            ready)      echo "Listo" ;;
            openNow)    echo "¿La abro ahora? [S/n]: " ;;
            yours)      echo "Lo que sigue siendo tuyo: los emuladores, y las llaves y el firmware de consola. Lever los encuentra y los lanza, no los reparte." ;;
            readMore)   echo "Cómo funciona cada parte: README.md" ;;
        esac
    fi
}

say() { printf '%s\n' "$1"; }
paso() { printf '\n%s' "$bold"; printf "$(t step)" "$1" "$TOTAL" "$(t "$2")"; printf '%s\n\n' "$reset"; }
ok()   { printf '  %s✓%s  %s\n' "$green" "$reset" "$1"; }
nope() { printf '  %s·%s  %s\n' "$yellow" "$reset" "$1"; }
bye()  { printf '\n%s  %s%s\n\n' "$dim" "$(t stopped)" "$reset"; exit 0; }

# Pregunta de sí o no, con sí por defecto. Con --yes no pregunta.
ask() {
    $assume_yes && return 0
    local answer; printf '  '; read -r -p "$(t "$1")" answer
    case "${answer:-s}" in s|S|y|Y|"") return 0 ;; *) return 1 ;; esac
}

# ── Paso 1: qué va a pasar ──────────────────────────────────────────────────
paso 1 welcome
say "  $(t whatWeDo)"
printf '\n'
printf '    1. %s\n' "$(t plan1)"
printf '    2. %s\n' "$(t plan2)"
printf '    3. %s\n' "$(t plan3)"
printf '    4. %s\n' "$(t plan4)"
printf '\n%s  %s%s\n\n' "$dim" "$(t noRush)" "$reset"
ask go || bye

# ── Paso 2: requisitos ──────────────────────────────────────────────────────
paso 2 checking
mac="$(sw_vers -productVersion)"
if (( ${mac%%.*} < 13 )); then
    printf '  %s✗%s  ' "$yellow" "$reset"; printf "$(t macOld)" "$mac"; printf '\n\n'
    exit 1
fi
# shellcheck disable=SC2059
ok "$(printf "$(t macOK)" "$mac")"

if ! command -v swift > /dev/null 2>&1; then
    printf '\n  %s✗%s  %s\n\n      xcode-select --install\n\n' "$yellow" "$reset" "$(t noSwift)"
    exit 1
fi
# shellcheck disable=SC2059
ok "$(printf "$(t swiftOK)" "$(swift --version 2>/dev/null | grep -oE 'version [0-9.]+' | head -1 | cut -d' ' -f2)")"

if command -v brew > /dev/null 2>&1 || [[ -x /opt/homebrew/bin/brew ]]; then ok "$(t brewOK)"; else nope "$(t noBrew)"; fi

# ── Paso 3: dependencias ────────────────────────────────────────────────────
paso 3 deps
say "$dim  $(t depsIntro)$reset"
if $assume_yes; then
    bash scripts/dependencies.sh --all --lang "$lang" || printf '\n%s  %s%s\n' "$dim" "$(t depsWarn)" "$reset"
else
    bash scripts/dependencies.sh --lang "$lang" || printf '\n%s  %s%s\n' "$dim" "$(t depsWarn)" "$reset"
fi

# ── Paso 4: compilar ────────────────────────────────────────────────────────
paso 4 build
say "$dim  $(t buildIntro)$reset"
printf '\n'
ask buildGo || bye
if ! bash scripts/build-app.sh; then
    printf '\n%s  %s%s\n\n' "$yellow" "$(t buildFail)" "$reset"
    exit 1
fi

# ── Paso 5: instalar ────────────────────────────────────────────────────────
paso 5 install
destination="$HOME/Desktop/Lever.app"
# shellcheck disable=SC2059
printf '  '; printf "$(t installTo)" "$destination"; printf '\n'
[[ -d "$destination" ]] && printf '%s  %s%s\n' "$dim" "$(t replacing)" "$reset"
printf '\n'
ask installGo || bye

rm -rf "$destination"
cp -R "$project_root/dist/Lever.app" "$destination"
xattr -cr "$destination" 2>/dev/null || true
# Refresca la caché de iconos del Finder para que se vea el nuevo de inmediato.
touch "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$destination" > /dev/null 2>&1 || true

printf '\n%s▸ %s%s\n\n' "$bold" "$(t ready)" "$reset"
ok "$destination"
printf '\n%s  %s%s\n' "$dim" "$(t yours)" "$reset"
printf '%s  %s%s\n\n' "$dim" "$(t readMore)" "$reset"

if ask openNow; then open "$destination"; fi
printf '\n'
