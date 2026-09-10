#!/usr/bin/env bash
# Mira qué le falta al Mac para que Lever funcione entera, dice cuánto ocupa, comprueba que te
# cabe, pide permiso y lo instala. En español o en inglés.
#
# Uso:  bash scripts/dependencies.sh [opciones]
#
#   --check        Solo informa; no instala nada. Devuelve 1 si falta algo básico.
#   --all          Instala todo lo que falte sin preguntar.
#   --only a,b,c   Instala solo esas piezas (por su nombre corto, el de la primera columna).
#   --lang es|en   Fuerza el idioma. Si no, sale del idioma del sistema.
#   --help         Esto.
#
# Sin opciones y con terminal delante, pregunta. Sin terminal (en un guion, en CI) se comporta
# como --check: nadie puede contestar, y descargar gigas sin permiso no está bien.
set -uo pipefail

lang="es"; case "${LANG:-}" in en*) lang="en" ;; esac
mode="ask"; only=""

while (( $# )); do
    case "$1" in
        --check) mode="check" ;;
        --all)   mode="all" ;;
        --only)  shift; only="${1:-}" ;;
        --lang)  shift; lang="${1:-es}" ;;
        --help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ -t 0 ]] || [[ "$mode" != "ask" ]] || mode="check"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'

# Traducciones. Dos idiomas, una función: `t clave` devuelve el texto del idioma elegido.
t() {
    local key="$1"
    if [[ "$lang" == "en" ]]; then
        case "$key" in
            looking)     echo "Checking what you need…" ;;
            have)        echo "already here" ;;
            nothing)     echo "Everything Lever needs is already installed. Nothing to do." ;;
            needs)       echo "This needs about %s. You have %s free." ;;
            noRoom)      echo "This would need about %s and you only have %s free. Make some room and come back." ;;
            askAll)      echo "Install? [a]ll · [p]ick · [n]othing: " ;;
            askWhich)    echo "Which ones? Numbers separated by spaces: " ;;
            installing)  echo "Installing: %s" ;;
            takesAWhile) echo "This can take a while. Leave it running." ;;
            done)        echo "Done." ;;
            partly)      echo "Homebrew could not finish everything. Lever still opens and tells you what is missing." ;;
            noBrew)      echo "Homebrew is missing, and it is what installs all this. Get it from https://brew.sh" ;;
            skipped)     echo "Nothing installed. Lever opens anyway and tells you what it needs, when it needs it." ;;
            notTTY)      echo "Run it yourself to install: bash scripts/dependencies.sh" ;;
        esac
    else
        case "$key" in
            looking)     echo "Mirando qué hace falta…" ;;
            have)        echo "ya está" ;;
            nothing)     echo "Ya tienes todo lo que Lever necesita. Nada que hacer." ;;
            needs)       echo "Esto ocupa unos %s. Tienes %s libres." ;;
            noRoom)      echo "Harían falta unos %s y solo te quedan %s libres. Haz sitio y vuelve." ;;
            askAll)      echo "¿Instalamos? [t]odo · [e]legir · [n]ada: " ;;
            askWhich)    echo "¿Cuáles? Números separados por espacios: " ;;
            installing)  echo "Instalando: %s" ;;
            takesAWhile) echo "Puede tardar un rato. Déjalo correr." ;;
            done)        echo "Listo." ;;
            partly)      echo "Homebrew no pudo con todo. Lever se abre igual y te dice qué falta." ;;
            noBrew)      echo "Falta Homebrew, que es quien instala todo esto. Cógelo de https://brew.sh" ;;
            skipped)     echo "No se instaló nada. Lever se abre igual y te dice qué necesita, cuando lo necesita." ;;
            notTTY)      echo "Ejecútalo tú para instalar: bash scripts/dependencies.sh" ;;
        esac
    fi
}

# Los mismos directorios que mira la app (RuntimeLocator.searchPathDirectories). Usar `command -v`
# a secas miraría el PATH de la terminal, que no es el que hereda una app abierta desde el Finder:
# el script diría «ya está» de algo que la app no va a encontrar.
app_bin_dirs=(/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /opt/local/bin /usr/bin /bin /usr/sbin /sbin)
android_sdk_roots=("$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools \
                   /usr/local/share/android-commandlinetools "$HOME/Android/sdk")

find_tool() {
    local name="$1" dir
    for dir in "${app_bin_dirs[@]}"; do
        [[ -x "$dir/$name" ]] && { printf '%s' "$dir/$name"; return 0; }
    done
    return 1
}

find_in_sdk() {
    local relative="$1" root
    for root in "${android_sdk_roots[@]}"; do
        [[ -x "$root/$relative" ]] && { printf '%s' "$root/$relative"; return 0; }
    done
    return 1
}

find_wine() {
    local candidate
    for candidate in "$(find_tool wine64 || true)" "$(find_tool wine || true)" \
        "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64" \
        "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64" \
        "/Applications/Whisky.app/Contents/Resources/Libraries/Wine/bin/wine64"; do
        [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

# ── Las piezas ──────────────────────────────────────────────────────────────
#
# Los tamaños son aproximados a propósito: Homebrew no dice cuánto pesa algo hasta que lo está
# bajando, así que se redondea hacia arriba. Mejor que sobre sitio que que se quede a medias.
#
#   nombre corto | MB | básica | para qué (es) | para qué (en) | orden de instalación
piece_keys=(); piece_mb=(); piece_core=(); piece_why_es=(); piece_why_en=(); piece_cmd=()

add_piece() {
    piece_keys+=("$1"); piece_mb+=("$2"); piece_core+=("$3")
    piece_why_es+=("$4"); piece_why_en+=("$5"); piece_cmd+=("$6")
}

printf '\n%s▸ %s%s\n\n' "$bold" "$(t looking)" "$reset"

have() { printf '  %s✓%s  %-14s %-52s %s%s%s\n' "$green" "$reset" "$1" "$2" "$dim" "$(t have)" "$reset"; }
lack() { printf '  %s·%s  %-14s %-52s %s%s%s\n' "$yellow" "$reset" "$1" "$2" "$dim" "$3" "$reset"; }

size_of() { # MB → texto legible, con el separador decimal del idioma
    local point=","; [[ "$lang" == "en" ]] && point="."
    if (( $1 >= 1000 )); then printf '%s%s%s GB' "$(( $1 / 1000 ))" "$point" "$(( ($1 % 1000) / 100 ))"
    else printf '%s MB' "$1"; fi
}

check() { # nombre | mb | básica | por_qué_es | por_qué_en | orden | ruta_encontrada
    local name="$1" mb="$2" core="$3" why_es="$4" why_en="$5" cmd="$6" found="${7:-}"
    local why; [[ "$lang" == "en" ]] && why="$why_en" || why="$why_es"
    if [[ -n "$found" ]]; then
        have "$name" "$why"
    else
        lack "$name" "$why" "~$(size_of "$mb")"
        add_piece "$name" "$mb" "$core" "$why_es" "$why_en" "$cmd"
    fi
}

check extractores 15 sí \
    "7zz y unar, para abrir .rar, .zip y .7z" \
    "7zz and unar, to open .rar, .zip and .7z" \
    "brew install sevenzip unar" \
    "$(find_tool 7zz || find_tool unar || true)"

check adb 35 sí \
    "para instalar un .apk en un móvil o emulador" \
    "to install an .apk on a phone or emulator" \
    "brew install android-platform-tools" \
    "$(find_tool adb || find_in_sdk platform-tools/adb || true)"

check zstd 5 sí \
    "para los paquetes de consola comprimidos" \
    "for compressed console packages" \
    "brew install zstd" \
    "$(find_tool zstd || true)"

check retroarch 250 no \
    "para las consolas retro" \
    "for retro consoles" \
    "brew install --cask retroarch" \
    "$([[ -d /Applications/RetroArch.app ]] && echo /Applications/RetroArch.app || true)"

check wine 1600 no \
    "para ejecutar programas de Windows (.exe)" \
    "to run Windows programs (.exe)" \
    "brew tap gcenx/wine && HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask gcenx/wine/game-porting-toolkit" \
    "$(find_wine || true)"

if [[ "$(uname -m)" == "arm64" ]]; then
    check rosetta 1000 no \
        "Wine lo necesita en los Mac con chip Apple" \
        "Wine needs it on Apple silicon Macs" \
        "softwareupdate --install-rosetta --agree-to-license" \
        "$([[ -f /usr/libexec/rosetta/oahd ]] && echo sí || true)"
fi

check android 4500 no \
    "el emulador, si no vas a enchufar un móvil" \
    "the emulator, if you are not plugging in a phone" \
    "brew install --cask temurin android-commandlinetools" \
    "$(find_in_sdk emulator/emulator || find_tool emulator || true)"

# ── ¿Hay algo que hacer? ────────────────────────────────────────────────────
if (( ${#piece_keys[@]} == 0 )); then
    printf '\n%s✓ %s%s\n\n' "$green" "$(t nothing)" "$reset"
    exit 0
fi

missing_core=0
for i in "${!piece_keys[@]}"; do [[ "${piece_core[$i]}" == "sí" ]] && missing_core=1; done

# Las piezas en juego. --only recorta la lista; el modo decide qué se hace con ella.
candidates=()
for i in "${!piece_keys[@]}"; do
    if [[ -n "$only" ]]; then
        case ",$only," in *",${piece_keys[$i]},"*) candidates+=("$i") ;; esac
    else
        candidates+=("$i")
    fi
done

if (( ${#candidates[@]} == 0 )); then
    printf '\n%s  %s%s\n\n' "$dim" "$(t skipped)" "$reset"
    exit $missing_core
fi

total=0
for i in "${candidates[@]}"; do total=$(( total + piece_mb[i] )); done

chosen=()
[[ "$mode" == "all" ]] && chosen=("${candidates[@]}")

free_mb=$(( $(df -k / | tail -1 | awk '{print $4}') / 1024 ))
printf '\n%s▸ ' "$bold"
# shellcheck disable=SC2059
printf "$(t needs)" "$(size_of "$total")" "$(size_of "$free_mb")"
printf '%s\n' "$reset"

# Un margen de 2 GB: llenar el disco del todo deja el Mac inservible, no solo la instalación.
if (( total + 2000 > free_mb )); then
    printf '\n%s▸ ' "$yellow"
    # shellcheck disable=SC2059
    printf "$(t noRoom)" "$(size_of "$total")" "$(size_of "$free_mb")"
    printf '%s\n\n' "$reset"
    exit 1
fi

if [[ "$mode" == "check" ]]; then
    [[ -t 0 ]] || printf '%s  %s%s\n' "$dim" "$(t notTTY)" "$reset"
    printf '\n'
    exit $missing_core
fi

# ── Preguntar ───────────────────────────────────────────────────────────────
if [[ "$mode" == "ask" ]]; then
    printf '\n  '; read -r -p "$(t askAll)" answer
    case "${answer:-}" in
        t|T|a|A|todo|all|s|S|y|Y|"") chosen=("${candidates[@]}") ;;
        e|E|p|P|elegir|pick)
            printf '\n'
            for n in "${!candidates[@]}"; do
                i="${candidates[$n]}"
                printf '    %s) %-14s ~%s\n' "$(( n + 1 ))" "${piece_keys[$i]}" "$(size_of "${piece_mb[$i]}")"
            done
            printf '\n  '; read -r -p "$(t askWhich)" picks
            for n in ${picks:-}; do
                (( n >= 1 && n <= ${#candidates[@]} )) && chosen+=("${candidates[$(( n - 1 ))]}")
            done ;;
        *) printf '\n%s  %s%s\n\n' "$dim" "$(t skipped)" "$reset"; exit $missing_core ;;
    esac
fi

if (( ${#chosen[@]} == 0 )); then
    printf '\n%s  %s%s\n\n' "$dim" "$(t skipped)" "$reset"
    exit $missing_core
fi

# ── Instalar ────────────────────────────────────────────────────────────────
names=""
for i in "${chosen[@]}"; do names="${names:+$names, }${piece_keys[$i]}"; done
printf '\n%s▸ ' "$bold"
# shellcheck disable=SC2059
printf "$(t installing)" "$names"
printf '%s\n%s  %s%s\n\n' "$reset" "$dim" "$(t takesAWhile)" "$reset"

# Rosetta lo instala el propio sistema; todo lo demás pasa por Homebrew.
needs_brew=0
for i in "${chosen[@]}"; do [[ "${piece_cmd[$i]}" == *brew* ]] && needs_brew=1; done
if (( needs_brew )) && ! find_tool brew > /dev/null; then
    printf '%s▸ %s%s\n\n' "$yellow" "$(t noBrew)" "$reset"
    exit 1
fi

status=0
for i in "${chosen[@]}"; do
    printf '%s  · %s%s\n' "$dim" "${piece_keys[$i]}" "$reset"
    HOMEBREW_NO_AUTO_UPDATE=1 bash -c "${piece_cmd[$i]}" || status=1
done

if (( status == 0 )); then
    printf '\n%s✓ %s%s\n\n' "$green" "$(t done)" "$reset"
else
    printf '\n%s▸ %s%s\n\n' "$yellow" "$(t partly)" "$reset"
fi
exit $status
