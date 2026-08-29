#!/usr/bin/env bash
# Revisa qué le falta al Mac para que Lever funcione entera, e instala lo que se puede instalar
# sin pedirle nada al usuario.
#
# La lista está partida en dos a propósito:
#
#   AUTOMÁTICO  Pocos megas, sin licencias que aceptar, sin contraseña, sin decisiones: los
#               extractores (7zz, unar) y adb. Se instalan sin preguntar.
#   A ELECCIÓN  Wine, Rosetta 2 y el SDK de Android. Son gigas, o piden contraseña, o hay que
#               elegir cuál —los casks de Wine chocan entre sí y varios están obsoletos—. Se
#               explican con la orden exacta lista para pegar, y decide el usuario.
#
# Instalar a ciegas lo del segundo grupo sería descargar varios gigas que quizá no quiere y
# elegir por él entre opciones que no son equivalentes.
#
# Uso:  bash scripts/dependencies.sh [--check]
#         --check   solo informa; no instala nada. Devuelve 1 si falta algo del primer grupo.
set -uo pipefail

only_check=false
[[ "${1:-}" == "--check" ]] && only_check=true

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'

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

report()  { printf '  %s%s%s  %-22s %s%s%s\n' "$green" "✓" "$reset" "$1" "$dim" "${2:-}" "$reset"; }
missing() { printf '  %s%s%s  %-22s %s%s%s\n' "$yellow" "·" "$reset" "$1" "$dim" "${2:-}" "$reset"; }

printf '\n%s▸ Revisando lo que hace falta…%s\n\n' "$bold" "$reset"

# ── Grupo automático ────────────────────────────────────────────────────────
formulae=()

if extractor="$(find_tool 7zz || find_tool unar || true)" && [[ -n "$extractor" ]]; then
    report "Extractores" "$extractor"
else
    missing "Extractores" "7zz y unar — para .rar, .zip, .7z"
    formulae+=(sevenzip unar)
fi

if adb="$(find_tool adb || find_in_sdk platform-tools/adb || true)" && [[ -n "$adb" ]]; then
    report "adb" "$adb"
else
    missing "adb" "para instalar .apk en un móvil o emulador"
    formulae+=(android-platform-tools)
fi

# ── Grupo a elección ────────────────────────────────────────────────────────
pending=()

if wine="$(find_wine || true)" && [[ -n "$wine" ]]; then
    report "Wine" "$wine"
else
    missing "Wine" "para ejecutar .exe — varios gigas, hay que elegir cuál"
    pending+=($'Wine (para los .exe). En un Mac con chip Apple los casks de WineHQ están\n  obsoletos; la opción libre que funciona es el Game Porting Toolkit:\n\n    brew tap gcenx/wine\n    HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask gcenx/wine/game-porting-toolkit\n\n  O CrossOver, de pago y más fiable:  brew install --cask crossover')
fi

if [[ "$(uname -m)" == "arm64" ]]; then
    if [[ -f /usr/libexec/rosetta/oahd ]]; then
        report "Rosetta 2" "instalado"
    else
        missing "Rosetta 2" "Wine lo necesita en los Mac con chip Apple"
        pending+=($'Rosetta 2 (solo si vas a usar Wine). Pide tu contrase\xc3\xb1a:\n\n    softwareupdate --install-rosetta --agree-to-license')
    fi
fi

if emulator="$(find_in_sdk emulator/emulator || find_tool emulator || true)" && [[ -n "$emulator" ]]; then
    report "Emulador Android" "$emulator"
else
    missing "Emulador Android" "opcional: solo si no vas a enchufar un móvil"
    pending+=($'Emulador de Android (opcional). Con un m\xc3\xb3vil enchufado no hace falta.\n  Son varios gigas y necesita Java:\n\n    brew install --cask temurin android-commandlinetools\n    sdkmanager --install "emulator" "platform-tools" "system-images;android-34;google_apis;arm64-v8a"\n    avdmanager create avd -n Lever -k "system-images;android-34;google_apis;arm64-v8a"')
fi

# ── Instalación de lo automático ────────────────────────────────────────────
status=0

if (( ${#formulae[@]} > 0 )); then
    if $only_check; then
        status=1
    elif ! brew_bin="$(find_tool brew)"; then
        printf '\n%s▸ Falta Homebrew%s, que es quien instala lo anterior. Instálalo desde https://brew.sh\n' "$yellow" "$reset"
        status=1
    else
        printf '\n%s▸ Instalando: %s%s\n' "$bold" "${formulae[*]}" "$reset"
        printf '%s  Suele tardar un par de minutos.%s\n\n' "$dim" "$reset"
        # `brew install` resuelve solo si un nombre es fórmula o cask, así que una sola orden basta.
        if HOMEBREW_NO_AUTO_UPDATE=1 "$brew_bin" install "${formulae[@]}"; then
            printf '\n%s✓ Instalado.%s\n' "$green" "$reset"
        else
            printf '\n%s✗ Homebrew no pudo con todo. La app funcionará a medias y te dirá qué falta.%s\n' "$yellow" "$reset"
            status=1
        fi
    fi
fi

# ── Lo que queda en manos del usuario ───────────────────────────────────────
if (( ${#pending[@]} > 0 )); then
    printf '\n%s▸ Esto no se instala solo, y es a propósito:%s\n' "$bold" "$reset"
    for item in "${pending[@]}"; do
        printf '\n  %b\n' "$item"
    done
    printf '\n%s  La app arranca igual y te dice qué le falta cuando lo necesite.%s\n' "$dim" "$reset"
fi

printf '\n'
exit $status
