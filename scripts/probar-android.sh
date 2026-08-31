#!/usr/bin/env bash
# Fabrica una app de Android de verdad, la empaqueta en los cuatro formatos y la instala con el
# instalador de Lever en un aparato de verdad.
#
#   bash scripts/probar-android.sh [apk|sinfirmar|xapk|apks|aab|todos]
#
# Por qué se fabrica en vez de descargar algo: los cuatro formatos hay que verlos por dentro, y
# los que circulan por ahí son de juegos ajenos de cientos de megas. Aquí se compila una app
# mínima con las herramientas del propio Android —`aapt2`, `d8`, `apksigner`, `bundletool`— y los
# envoltorios salen de ellas, no de una imitación: lo que Lever lee es lo mismo que produce Google.
#
# La app dibuja una pantalla azul con «LEVER-OK» y lo escribe en el registro del sistema, que es
# lo que se comprueba al final: no que la instalación devolviera cero, sino que la app arrancó.
set -uo pipefail

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; reset=$'\033[0m'
paso()  { printf '\n%s▸ %s%s\n' "$bold" "$1" "$reset"; }
ok()    { printf '%s  ✓ %s%s\n' "$green" "$1" "$reset"; }
mal()   { printf '%s  ✗ %s%s\n' "$red" "$1" "$reset"; fallos=$((fallos + 1)); }
nota()  { printf '%s    %s%s\n' "$dim" "$1" "$reset"; }
morir() { printf '\n%s✗ %s%s\n' "$yellow" "$1" "$reset"; exit 1; }

fallos=0
que="${1:-todos}"
raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
taller="${TMPDIR:-/tmp}/lever-android-$(date +%s)"
cache="$taller/cache"
mkdir -p "$taller" "$cache"

PAQUETE="com.lever.prueba"

# ── Lo que hace falta ───────────────────────────────────────────────────────
paso "Comprobando las herramientas"

sdk="${ANDROID_SDK_ROOT:-}"
for candidato in "$sdk" "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools \
                 /usr/local/share/android-commandlinetools; do
    [[ -n "$candidato" && -d "$candidato/platform-tools" ]] && { sdk="$candidato"; break; }
done
[[ -d "${sdk:-}/platform-tools" ]] || morir "No encuentro el SDK de Android. Móntalo con: bash scripts/android-emulator.sh"
export ANDROID_SDK_ROOT="$sdk" ANDROID_HOME="$sdk"

# Las build-tools traen `aapt2`, `d8`, `zipalign` y `apksigner`; la plataforma trae `android.jar`,
# contra el que se compila. Ninguna de las dos viene con el emulador, así que se piden aparte.
buildtools="$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
plataforma="$(ls -d "$sdk"/platforms/android-* 2>/dev/null | sort -V | tail -1 || true)"
if [[ ! -x "${buildtools:-}/aapt2" || ! -f "${plataforma:-}/android.jar" ]]; then
    sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
    [[ -x "$sdkmanager" ]] || morir "Faltan las build-tools y no hay sdkmanager para instalarlas."
    nota "Faltan las build-tools o la plataforma. Instalándolas (unos 150 MB)…"
    "$sdkmanager" --install "build-tools;35.0.0" "platforms;android-34" < <(yes 2>/dev/null) > /dev/null 2>&1
    buildtools="$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
    plataforma="$(ls -d "$sdk"/platforms/android-* 2>/dev/null | sort -V | tail -1 || true)"
    [[ -x "${buildtools:-}/aapt2" ]] || morir "No se pudieron instalar las build-tools."
fi
ok "build-tools: $(basename "$buildtools")   plataforma: $(basename "$plataforma")"

adb="$(command -v adb || echo "$sdk/platform-tools/adb")"
[[ -x "$adb" ]] || morir "No encuentro adb."
command -v javac > /dev/null || morir "Hace falta un JDK para compilar la app de prueba (brew install --cask temurin)."

serial="$("$adb" devices | awk '$2 == "device" { print $1; exit }')"
[[ -n "$serial" ]] || morir "No hay ningún aparato listo. Arranca el emulador: $sdk/emulator/emulator -avd Lever"
ok "aparato: $serial"

# ── La app de prueba ────────────────────────────────────────────────────────
paso "Compilando una app de Android de verdad"
fuente="$taller/app"
mkdir -p "$fuente/src/com/lever/prueba" "$fuente/res/values" "$fuente/res/values-es" "$fuente/clases"

cat > "$fuente/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$PAQUETE" android:versionCode="7" android:versionName="1.2.3">
    <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="34" />
    <application android:label="@string/app_name" android:hasCode="true">
        <activity android:name=".MainActivity" android:screenOrientation="landscape" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources><string name="app_name">Prueba Lever</string></resources>\n' \
    > "$fuente/res/values/strings.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources><string name="app_name">Prueba Lever ES</string></resources>\n' \
    > "$fuente/res/values-es/strings.xml"

# Un dibujo por densidad, que es lo que hace que bundletool genere trozos de densidad.
png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
    mkdir -p "$fuente/res/drawable-$d"
    echo "$png" | base64 -d > "$fuente/res/drawable-$d/icono.png"
done

cat > "$fuente/src/com/lever/prueba/MainActivity.java" <<'EOF'
package com.lever.prueba;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.widget.TextView;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle estado) {
        super.onCreate(estado);
        TextView texto = new TextView(this);
        texto.setText("LEVER-OK");
        texto.setTextColor(Color.WHITE);
        texto.setBackgroundColor(Color.rgb(20, 90, 160));
        texto.setTextSize(32);
        setContentView(texto);
        android.util.Log.i("LeverPrueba", "LEVER-OK arrancada");
    }
}
EOF

javac -source 11 -target 11 -nowarn -classpath "$plataforma/android.jar" \
      -d "$fuente/clases" "$fuente/src/com/lever/prueba/MainActivity.java" 2> "$taller/javac.log" \
      || { cat "$taller/javac.log"; morir "javac falló"; }
"$buildtools/d8" --lib "$plataforma/android.jar" --output "$fuente" \
      $(find "$fuente/clases" -name '*.class') > /dev/null 2>&1 || morir "d8 falló"

mkdir -p "$fuente/compilado"
"$buildtools/aapt2" compile --dir "$fuente/res" -o "$fuente/compilado/res.zip" || morir "aapt2 compile falló"
"$buildtools/aapt2" link -o "$fuente/recursos.apk" -I "$plataforma/android.jar" \
      --manifest "$fuente/AndroidManifest.xml" "$fuente/compilado/res.zip" --auto-add-overlay \
      || morir "aapt2 link falló"
"$buildtools/aapt2" link --proto-format -o "$fuente/proto.apk" -I "$plataforma/android.jar" \
      --manifest "$fuente/AndroidManifest.xml" "$fuente/compilado/res.zip" --auto-add-overlay \
      || morir "aapt2 link --proto-format falló"
ok "app compilada con aapt2 y d8"

# ── Los cinco archivos ──────────────────────────────────────────────────────
paso "Armando los archivos de prueba"
archivos="$taller/archivos"; mkdir -p "$archivos"

# 1 y 2: el `.apk` de siempre, sin firma y firmado.
montaje="$taller/montaje"; mkdir -p "$montaje/lib/arm64-v8a" "$montaje/lib/armeabi-v7a" "$montaje/assets"
printf 'datos del juego\n' > "$montaje/assets/datos.txt"
printf 'librería nativa de mentira\n' | tee "$montaje/lib/arm64-v8a/libprueba.so" \
    > "$montaje/lib/armeabi-v7a/libprueba.so"
cp "$fuente/classes.dex" "$montaje/"
cp "$fuente/recursos.apk" "$archivos/sinfirmar.apk"
(cd "$montaje" && zip -q -r -X "$archivos/sinfirmar.apk" classes.dex lib assets)
"$buildtools/zipalign" -f -p 4 "$archivos/sinfirmar.apk" "$archivos/alineada.apk" > /dev/null 2>&1
mv "$archivos/alineada.apk" "$archivos/sinfirmar.apk"

# La clave de la prueba es de la prueba, no la de Lever: Lever se hace la suya al firmar.
openssl req -x509 -newkey rsa:2048 -days 10000 -nodes -sha256 -subj "/CN=Prueba/O=Lever/C=ES" \
    -keyout "$taller/clave.pem" -out "$taller/certificado.pem" > /dev/null 2>&1
openssl pkcs8 -topk8 -inform PEM -outform DER -in "$taller/clave.pem" -out "$taller/clave.pk8" -nocrypt
openssl pkcs12 -export -inkey "$taller/clave.pem" -in "$taller/certificado.pem" -name prueba \
    -out "$taller/almacen.p12" -passout pass:prueba > /dev/null 2>&1
cp "$archivos/sinfirmar.apk" "$archivos/firmada.apk"
"$buildtools/apksigner" sign --key "$taller/clave.pk8" --cert "$taller/certificado.pem" \
    "$archivos/firmada.apk" 2>/dev/null || morir "apksigner falló"
ok "firmada.apk y sinfirmar.apk"

# 3: el App Bundle, con la disposición que pide bundletool.
modulo="$taller/modulo"
mkdir -p "$modulo/manifest" "$modulo/dex" "$modulo/lib/arm64-v8a" "$modulo/lib/armeabi-v7a" "$modulo/assets"
unzip -qo "$fuente/proto.apk" -d "$taller/proto"
cp "$taller/proto/AndroidManifest.xml" "$modulo/manifest/AndroidManifest.xml"
cp "$taller/proto/resources.pb" "$modulo/resources.pb"
[[ -d "$taller/proto/res" ]] && cp -R "$taller/proto/res" "$modulo/res"
cp "$fuente/classes.dex" "$modulo/dex/"
cp "$montaje/lib/arm64-v8a/libprueba.so" "$modulo/lib/arm64-v8a/"
cp "$montaje/lib/armeabi-v7a/libprueba.so" "$modulo/lib/armeabi-v7a/"
cp "$montaje/assets/datos.txt" "$modulo/assets/"
(cd "$modulo" && zip -q -r -X "$taller/base.zip" .)

bundletool="$taller/bundletool.jar"
if [[ ! -f "$bundletool" ]]; then
    nota "Descargando bundletool para fabricar el .aab y el .apks (32 MB)…"
    curl -sL --fail -o "$bundletool" \
        "https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar" \
        || morir "no se pudo descargar bundletool"
fi
java -jar "$bundletool" build-bundle --modules="$taller/base.zip" --output="$archivos/juego.aab" \
    2>/dev/null || morir "bundletool build-bundle falló"
ok "juego.aab"

# 4: el `.apks` con todas las variantes, tal y como sale de bundletool.
java -jar "$bundletool" build-apks --bundle="$archivos/juego.aab" --output="$archivos/juego.apks" \
    --overwrite --ks="$taller/almacen.p12" --ks-pass=pass:prueba --ks-key-alias=prueba \
    --key-pass=pass:prueba 2>/dev/null || morir "bundletool build-apks falló"
ok "juego.apks ($(unzip -l "$archivos/juego.apks" | tail -1 | awk '{print $2}') entradas)"

# 5: el `.xapk`, con los trozos renombrados a la convención de Play —que es la que reparte
# APKPure— y un archivo de expansión al lado.
unzip -qo "$archivos/juego.apks" -d "$taller/apks"
xapk="$taller/xapk"; mkdir -p "$xapk/Android/obb/$PAQUETE"
cp "$taller/apks/splits/base-master.apk" "$xapk/base.apk"
for trozo in "$taller/apks"/splits/base-*.apk; do
    nombre="$(basename "$trozo" .apk)"
    cualidad="${nombre#base-}"
    # Solo la primera variante: las de `_2` y `_3` son la misma app para otro Android, y meterlas
    # todas sería un envoltorio que no reparte nadie.
    [[ "$cualidad" == master || "$cualidad" == *_2 || "$cualidad" == *_3 ]] && continue
    cp "$trozo" "$xapk/config.$cualidad.apk"
done
head -c 200000 /dev/urandom > "$xapk/Android/obb/$PAQUETE/main.7.$PAQUETE.obb"
cat > "$xapk/manifest.json" <<EOF
{
  "xapk_version": 2,
  "package_name": "$PAQUETE",
  "name": "Prueba Lever",
  "version_code": "7",
  "version_name": "1.2.3",
  "min_sdk_version": "24",
  "target_sdk_version": "34",
  "split_apks": [
    {"file": "base.apk", "id": "base"},
    {"file": "config.arm64_v8a.apk", "id": "config.arm64_v8a"},
    {"file": "config.armeabi_v7a.apk", "id": "config.armeabi_v7a"},
    {"file": "config.xxhdpi.apk", "id": "config.xxhdpi"},
    {"file": "config.es.apk", "id": "config.es"}
  ],
  "expansions": [
    {"file": "Android/obb/$PAQUETE/main.7.$PAQUETE.obb",
     "install_location": "EXTERNAL_STORAGE",
     "install_path": "Android/obb/$PAQUETE/main.7.$PAQUETE.obb"}
  ]
}
EOF
(cd "$xapk" && zip -q -r -X "$archivos/juego.xapk" .)
ok "juego.xapk ($(ls "$xapk"/*.apk | wc -l | tr -d ' ') trozos y un .obb de 200 kB)"

# ── La sonda ────────────────────────────────────────────────────────────────
paso "Compilando la sonda que llama al instalador de Lever"
cat > "$taller/sonda.swift" <<'SWIFT'
import Foundation

@main
struct Sonda {
    static func main() async throws {
        let archivo = URL(fileURLWithPath: CommandLine.arguments[1])
        let adb = URL(fileURLWithPath: CommandLine.arguments[2])
        let serial = CommandLine.arguments[3]
        let cache = URL(fileURLWithPath: CommandLine.arguments[4])

        let paquete = AndroidBundleInspector.inspect(archivo)
        print("· formato: \(paquete.kind.rawValue)")
        print("· paquete: \(paquete.facts.packageName ?? "no se sabe")")
        print("· versión: \(paquete.facts.versionName ?? "?") · minSdk: \(paquete.facts.minSdk.map(String.init) ?? "?")")
        print("· firma: \(paquete.signature) · hay que firmarlo: \(paquete.needsSigning)")
        print("· trozos: \(paquete.parts.count) · expansiones: \(paquete.expansions.count)")
        for parte in paquete.parts.sorted(by: { $0.entryName < $1.entryName }) {
            print("   · \(parte.entryName) → \(parte.role)")
        }
        if paquete.readFailed { print("· NO SE PUDO LEER"); exit(1) }

        let runner = ProcessRunner()
        let props = try await runner.run(AndroidLauncher.propertiesCommand(adb: adb, serial: serial))
        let leídas = AndroidLauncher.properties(fromOutput: props.output)
        let aparato = AndroidDevice(
            serial: serial, availability: .ready, model: leídas.model,
            abis: leídas.abis, sdk: leídas.sdk, release: leídas.release
        )
        print("· aparato: \(aparato.displayName) · \(aparato.abis.joined(separator: ", "))")

        let resultado = try await AndroidInstaller.install(
            package: paquete, at: archivo, adb: adb, device: aparato,
            runner: runner, session: ProcessSession(), library: PortLibrary(root: cache),
            onStage: { print("· \($0)") },
            onLine: { línea in
                let limpia = línea.trimmingCharacters(in: .whitespacesAndNewlines)
                if !limpia.isEmpty, !limpia.hasPrefix("WARNING"), !limpia.hasPrefix("#") {
                    print("  \(limpia)")
                }
            }
        )
        print("INSTALADO=\(resultado.packageName ?? "")")
        print("TROZOS=\(resultado.installedParts)")
        print("EXPANSIONES=\(resultado.pushedExpansions)")
        print("FIRMADO=\(resultado.wasSigned)")
    }
}
SWIFT

fuentes=()
while IFS= read -r archivo; do fuentes+=("$archivo"); done \
    < <(find "$raiz/Sources/LeverCore" -name '*.swift')
if ! swiftc -parse-as-library -o "$taller/sonda" "$taller/sonda.swift" "${fuentes[@]}" \
        2> "$taller/compilar.log"; then
    grep "error:" "$taller/compilar.log" | head -5 >&2
    morir "la sonda no compila"
fi
ok "sonda lista"

# ── Probar cada formato ─────────────────────────────────────────────────────

# Lanza la app y espera a que su línea aparezca en el registro del sistema. Es lo único que
# demuestra que la instalación sirvió para algo: un «Success» de adb no dice que la app arranque.
arranca() {
    "$adb" -s "$serial" logcat -c > /dev/null 2>&1
    "$adb" -s "$serial" shell "monkey -p $PAQUETE -c android.intent.category.LAUNCHER 1" > /dev/null 2>&1
    for _ in $(seq 1 15); do
        if "$adb" -s "$serial" logcat -d -s LeverPrueba 2>/dev/null | grep -q "LEVER-OK"; then return 0; fi
        sleep 1
    done
    return 1
}

probar() {
    local etiqueta="$1" archivo="$2"
    paso "$etiqueta"
    "$adb" -s "$serial" uninstall "$PAQUETE" > /dev/null 2>&1
    "$adb" -s "$serial" shell "rm -rf /sdcard/Android/obb/$PAQUETE" > /dev/null 2>&1

    local registro="$taller/$(basename "$archivo").log"
    if ! "$taller/sonda" "$archivo" "$adb" "$serial" "$cache" > "$registro" 2>&1; then
        sed 's/^/    /' "$registro" | tail -15
        mal "$etiqueta: la instalación falló"
        return
    fi
    grep -E '^(·|   ·)' "$registro" | sed 's/^/  /'

    if arranca; then ok "la app arrancó en el aparato"; else mal "$etiqueta: instaló pero no arrancó"; fi
    printf '%s' "$dim"
    "$adb" -s "$serial" shell "pm path $PAQUETE" | sed 's|.*/|      trozo: |'
    printf '%s' "$reset"
}

case "$que" in
    apk|sinfirmar|xapk|apks|aab|todos) ;;
    *) morir "No sé qué es «$que». Usa: apk, sinfirmar, xapk, apks, aab o todos." ;;
esac

# El bash que trae macOS es el 3.2 y no entiende `;;&`, así que cada prueba se pregunta si le
# toca en vez de encadenar ramas de un `case`.
toca() { [[ "$que" == todos || "$que" == "$1" ]]; }

if toca apk; then
    probar "1 · un .apk firmado, como siempre" "$archivos/firmada.apk"
fi

if toca sinfirmar; then
        paso "2 · un .apk sin firmar"
        "$adb" -s "$serial" uninstall "$PAQUETE" > /dev/null 2>&1
        # Primero se enseña que Android lo rechaza: es la razón de que Lever tenga que firmarlo.
        # `adb` deja una línea en blanco al final, así que se mira la salida entera y no la última.
        rechazo="$("$adb" -s "$serial" install -r "$archivos/sinfirmar.apk" 2>&1)"
        if grep -q "NO_CERTIFICATES" <<< "$rechazo"; then
            ok "Android lo rechaza tal cual: $(grep -o 'INSTALL_[A-Z_]*' <<< "$rechazo" | head -1)"
        else
            mal "se esperaba que Android lo rechazara y dijo: $(tr '\n' ' ' <<< "$rechazo")"
        fi
        probar "2 · el mismo .apk, firmado por Lever" "$archivos/sinfirmar.apk"
        grep -q "^FIRMADO=true" "$taller/sinfirmar.apk.log" \
            && ok "lo firmó Lever, no venía firmado" || mal "no consta que Lever lo firmara"
fi

if toca xapk; then
        probar "3 · un .xapk con trozos y un archivo de expansión" "$archivos/juego.xapk"
        # Los trozos instalados tienen que ser los del aparato, no todos: uno por procesador y
        # uno por densidad. Si se colaran dos, Android habría rechazado el conjunto entero.
        instalados="$("$adb" -s "$serial" shell "pm path $PAQUETE" | grep -c split_ || true)"
        [[ "$instalados" -ge 2 ]] && ok "$instalados trozos instalados junto a la base" \
            || mal "esperaba al menos dos trozos y hay $instalados"
        "$adb" -s "$serial" shell "ls -l /sdcard/Android/obb/$PAQUETE/" 2>/dev/null | grep -q "200000" \
            && ok "el .obb está en el aparato con su tamaño" || mal "el .obb no llegó al aparato"
fi

if toca apks; then
    probar "4 · un .apks de bundletool" "$archivos/juego.apks"
fi

if toca aab; then
    probar "5 · un .aab, que ni siquiera es instalable" "$archivos/juego.aab"
    # De un `.aab` no se puede leer el nombre del paquete —su manifiesto está en protobuf—, así
    # que tiene que salir de los `.apk` que genera bundletool. Sin él, la app queda instalada y
    # Lever no puede ni abrirla ni desinstalarla.
    grep -q "^INSTALADO=$PAQUETE\$" "$taller/juego.aab.log" \
        && ok "Lever sabe cómo se llama la app que acaba de instalar" \
        || mal "tras instalar el .aab, Lever se queda sin el nombre del paquete"
fi

paso "Resultado"
if [[ $fallos -eq 0 ]]; then
    printf '%s  Todo en verde.%s\n' "$green" "$reset"
else
    printf '%s  %d comprobaciones fallaron.%s\n' "$red" "$fallos" "$reset"
fi
nota "Los archivos y los registros se quedan en: $taller"
exit $((fallos > 0))
