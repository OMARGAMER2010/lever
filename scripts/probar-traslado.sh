#!/usr/bin/env bash
# Traslada un .exe con el porteador de verdad y comprueba que la app resultante abre y dibuja.
#
# Es el paso que ninguna prueba de `swift run LeverTests` puede dar: ahí se comprueba que el
# reconocimiento y el montaje hacen lo que dicen, pero no que macOS arranque lo montado. Este
# guion cierra ese hueco sin pasar por la ventana de Lever, para poder repetirlo a mano.
#
#   bash scripts/probar-traslado.sh <ruta al .exe> [carpeta de caché]
#
# La app trasladada se deja en una carpeta temporal y se lanza. Si el juego escribe algo en
# /tmp/lever-nw.log (los juegos de prueba de este repositorio lo hacen), se enseña.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Uso: bash scripts/probar-traslado.sh <ruta al .exe> [carpeta de caché]" >&2
    exit 2
fi

programa="$1"
raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
taller="${TMPDIR:-/tmp}/lever-probar-$(date +%s)"
cache="${2:-$taller/cache}"
salida="$taller/salida"
mkdir -p "$salida" "$cache"

# El porteador vive en una biblioteca, no en un ejecutable: se compila una sonda que lo llame.
cat > "$taller/sonda.swift" <<'SWIFT'
import Foundation

@main
struct Sonda {
    static func main() async throws {
        let exe = URL(fileURLWithPath: CommandLine.arguments[1])
        let salida = URL(fileURLWithPath: CommandLine.arguments[2])
        let cache = URL(fileURLWithPath: CommandLine.arguments[3])

        guard let motor = PortableEngineDetector.detect(program: exe) else {
            print("· no se reconoce ningún motor en ese .exe"); exit(1)
        }
        print("· motor: \(motor.displayName)")
        print("· contemplado: \(motor.isSupported)")
        print("· partes sin resolver: \(motor.unresolvedParts)")
        guard motor.isSupported else { exit(1) }

        let biblioteca = PortLibrary(root: cache)
        print("· motor en caché: \(motor.runtimeIsCached(in: biblioteca))")

        let resultado = try await NativePorter.makeApp(
            for: motor, into: salida, buildMissingParts: false,
            runner: ProcessRunner(), session: ProcessSession(), library: biblioteca,
            onStage: { print("· \($0)") },
            onLine: { linea in
                let limpia = linea.trimmingCharacters(in: .whitespacesAndNewlines)
                if !limpia.isEmpty, !limpia.hasPrefix("#"), Int(limpia.prefix(1)) == nil {
                    print("  \(limpia)")
                }
            }
        )
        print("APP=\(resultado.app.path)")
    }
}
SWIFT

echo "▸ Compilando la sonda…"
# La ruta del proyecto lleva espacios: sin recoger los nombres uno a uno, `find` los parte.
fuentes=()
while IFS= read -r fuente; do fuentes+=("$fuente"); done \
    < <(find "$raiz/Sources/LeverCore" -name '*.swift')
if ! swiftc -parse-as-library -o "$taller/sonda" "$taller/sonda.swift" "${fuentes[@]}" \
        2> "$taller/compilar.log"; then
    grep "error:" "$taller/compilar.log" | head -5 >&2
    exit 1
fi

echo "▸ Trasladando…"
app="$("$taller/sonda" "$programa" "$salida" "$cache" | tee /dev/stderr | grep '^APP=' | cut -d= -f2-)"
if [[ -z "$app" ]]; then echo "✗ no se creó ninguna app" >&2; exit 1; fi

echo "▸ Firma:"
codesign --verify --deep --strict "$app" 2>&1 | tail -2 || true

echo "▸ Abriendo la app…"
# NW.js y Chromium dejan cerrojos si se les mata a lo bruto, y el siguiente arranque se queda
# esperando en ellos: se limpian antes de cada intento.
find "$(getconf DARWIN_USER_TEMP_DIR)" -maxdepth 1 -name ".io.nwjs*" -exec rm -rf {} + 2>/dev/null || true
rm -f /tmp/lever-nw.log
binario="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
"$binario" > "$taller/salida-app.log" 2>&1 &
pid=$!
for _ in $(seq 1 20); do
    if grep -q "cuadros=\|frames-dibujados" /tmp/lever-nw.log "$taller/salida-app.log" 2>/dev/null; then break; fi
    sleep 1
done
kill "$pid" 2>/dev/null || true

echo "▸ Lo que dijo el juego:"
cat /tmp/lever-nw.log 2>/dev/null || true
grep -E "LEVER-PRUEBA" "$taller/salida-app.log" 2>/dev/null || true
echo "▸ Errores del arranque:"
head -6 "$taller/salida-app.log"
echo
echo "La app trasladada se queda en: $app"
