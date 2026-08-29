#!/usr/bin/env bash
# Monta un Android dentro del Mac: SDK, imagen de sistema y un emulador listo para usar.
#
# Va aparte de `dependencies.sh` porque no es del mismo tipo de cosa: son unos 5 GB y `sdkmanager`
# pide aceptar licencias por la entrada estándar. Lever lo lanza como guion —no como orden suelta—
# justamente por eso: sus procesos van con la entrada cerrada para que nada se cuelgue esperando,
# y aquí las licencias se aceptan desde dentro.
#
# Es idempotente: cada paso comprueba antes si ya está hecho.
set -uo pipefail

# `sdkmanager` puede pedir confirmaciones por la entrada estándar, y hay que dárselas sin que se
# quede esperando. Lo que NO se puede hacer es `yes | sdkmanager`: cuando sdkmanager termina bien,
# `yes` muere por SIGPIPE con código 141 y `pipefail` convierte ese 141 en el resultado de toda la
# tubería, así que un éxito se lee como fallo. Con sustitución de procesos, el estado de salida es
# el de sdkmanager y nada más.
feed_yes() { "$@" < <(yes 2>/dev/null); }

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$bold" "$1" "$reset"; }
ok()   { printf '%s✓ %s%s\n' "$green" "$1" "$reset"; }
die()  { printf '\n%s✗ %s%s\n' "$yellow" "$1" "$reset"; exit 1; }

# La imagen de sistema. `arm64-v8a` es nativa en un Mac con chip Apple: una imagen `x86_64` se
# emularía instrucción a instrucción y sería inservible para jugar.
API=34
IMAGE="system-images;android-${API};google_apis;arm64-v8a"
AVD_NAME="Lever"
# Un móvil normal: pantalla vertical, que es como arranca casi todo.
DEVICE="pixel_6"

sdk_root="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"

# ── Sitio en disco ──────────────────────────────────────────────────────────
free_gb=$(df -g / | awk 'NR==2 {print $4}')
step "Comprobando el disco"
if (( free_gb < 8 )); then
    die "Hacen falta unos 8 GB libres y hay ${free_gb} GB. El SDK ocupa 6 y el emulador crece con el uso. Libera sitio y vuelve a intentarlo."
fi
ok "${free_gb} GB libres"

# ── Java ────────────────────────────────────────────────────────────────────
step "Comprobando Java"
if ! /usr/libexec/java_home > /dev/null 2>&1; then
    printf '  Falta Java, que es lo que ejecuta sdkmanager. Instalando…\n'
    brew install --cask temurin || die "No se pudo instalar Java. Pruébalo a mano: brew install --cask temurin"
fi
export JAVA_HOME="$(/usr/libexec/java_home)"
ok "Java en $JAVA_HOME"

# ── Herramientas de línea de órdenes ────────────────────────────────────────
step "Comprobando las herramientas del SDK"
sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"

if [[ ! -x "$sdkmanager" ]]; then
    printf '  Instalando android-commandlinetools…\n'
    brew install --cask android-commandlinetools || die "No se pudieron instalar las herramientas del SDK."
fi
[[ -x "$sdkmanager" ]] || sdkmanager="$(command -v sdkmanager || true)"
[[ -x "$avdmanager" ]] || avdmanager="$(command -v avdmanager || true)"
[[ -x "$sdkmanager" && -x "$avdmanager" ]] || die "No aparecen sdkmanager/avdmanager tras instalarlos."
ok "$sdkmanager"

export ANDROID_SDK_ROOT="$sdk_root"
export ANDROID_HOME="$sdk_root"

# ── Licencias ───────────────────────────────────────────────────────────────
# Sin esto, sdkmanager se para a preguntar y, lanzado desde la app, se quedaría esperando para
# siempre. Son las licencias del SDK de Google: aceptarlas es requisito para descargarlo.
step "Aceptando las licencias del SDK de Google"
feed_yes "$sdkmanager" --licenses > /dev/null 2>&1 || true
ok "hecho"

# ── Descarga ────────────────────────────────────────────────────────────────
step "Descargando el emulador y Android ${API} (arm64). Son unos 4 GB: tarda."
feed_yes "$sdkmanager" --install "emulator" "platform-tools" "$IMAGE"
status=$?
if (( status != 0 )); then
    die "sdkmanager terminó con el código ${status}. Mira las líneas de arriba: lo ya descargado se conserva, así que se puede volver a lanzar."
fi
ok "descargado"

emulator="$sdk_root/emulator/emulator"
[[ -x "$emulator" ]] || die "El emulador no aparece en $emulator"

# ── El emulador ─────────────────────────────────────────────────────────────
# Con llaves a propósito: `$AVD_NAME»` pegado a un carácter no ASCII hace que bash, según el
# locale, se trague esos bytes como parte del nombre de la variable y falle con «unbound».
step "Creando el emulador «${AVD_NAME}»"
if "$emulator" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    ok "ya existía"
else
    # `avdmanager` escupe «Error: Could not load devices from …/devices.xml» y aun así termina
    # con código 0 y crea el aparato con sus definiciones internas. Fiarse de su código de salida
    # daría por bueno un fallo real, así que se comprueba el resultado: que el emulador aparezca
    # en la lista y tenga su configuración.
    echo "no" | "$avdmanager" create avd -n "$AVD_NAME" -k "$IMAGE" -d "$DEVICE" --force 2>&1 \
        | grep -v "devices.xml" || true

    if ! "$emulator" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
        die "avdmanager no dejó ningún emulador llamado «${AVD_NAME}». Mira las líneas de arriba."
    fi
    ok "creado"
fi

# ── Ajustes para este Mac ───────────────────────────────────────────────────
# Con 8 GB de RAM no se le pueden dar 4 al emulador sin ahogar al resto del sistema, y el disco
# está justo. Estos valores son los que hacen que sea usable aquí, no los que trae por defecto.
config="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [[ ! -f "$config" ]]; then
    die "El emulador «${AVD_NAME}» aparece en la lista pero no tiene configuración en $config."
fi
if true; then
    step "Ajustando el emulador a este Mac"
    set_key() {
        if grep -q "^$1=" "$config"; then
            sed -i '' "s|^$1=.*|$1=$2|" "$config"
        else
            printf '%s=%s\n' "$1" "$2" >> "$config"
        fi
    }
    set_key hw.ramSize 2048
    set_key vm.heapSize 256
    set_key disk.dataPartition.size 4G
    set_key hw.gpu.enabled yes
    set_key hw.gpu.mode auto
    set_key hw.keyboard yes
    # Arranca en vertical, que es la postura natural de un móvil. Lever la cambia luego según lo
    # que pida el .apk.
    set_key hw.initialOrientation portrait
    ok "2 GB de RAM, 4 GB de disco, gráficos por hardware"
fi

printf '\n%s✓ Listo. El emulador «%s» ya se puede arrancar desde Lever.%s\n' "$green" "$AVD_NAME" "$reset"
printf '%s  La primera vez tarda un par de minutos en arrancar.%s\n\n' "$dim" "$reset"
