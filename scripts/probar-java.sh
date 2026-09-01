#!/usr/bin/env bash
# Arma un juego de Java para Windows con las herramientas de verdad y lo pasa por el porteador.
#
#   bash scripts/probar-java.sh [versión de LWJGL] [pegado|suelto]
#
# «pegado» deja el jar detrás del .exe, como hace Launch4j; «suelto» lo deja al lado. Los dos
# repartos existen y el reconocimiento es distinto, así que conviene probar los dos.
#
# El juego hace lo mismo que el de NW.js: abre una ventana, pinta naranja y lee el píxel de
# vuelta, dejando el rastro en /tmp/lever-java.log. Si sale «cuadros=30» y el píxel es naranja,
# el traslado funciona: se cambió el JRE, se cambiaron los binarios de LWJGL y arranca.
#
# Hace falta un `javac` en la máquina. No se puede generar el bytecode de otra manera, y meter un
# .class ya compilado en el repositorio sería justo lo contrario de comprobarlo.
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-3.3.6}"
reparto="${2:-pegado}"
case "$reparto" in pegado|suelto) ;; *) echo "reparto desconocido: $reparto" >&2; exit 2 ;; esac

if ! command -v javac >/dev/null; then
    echo "✗ hace falta javac para generar el juego de prueba (brew install --cask temurin)" >&2
    exit 1
fi

taller="${TMPDIR:-/tmp}/lever-java-$(date +%s)"
juego="$taller/reparto"
maven="${TMPDIR:-/tmp}/lever-maven/$version"
mkdir -p "$juego/lib" "$taller/src/prueba" "$maven"

echo "▸ Bajando LWJGL $version de Maven Central…"
for modulo in lwjgl lwjgl-glfw lwjgl-opengl; do
    for clasificador in "" "-natives-windows"; do
        archivo="$modulo-$version$clasificador.jar"
        [ -s "$maven/$archivo" ] || curl -s --fail --max-time 120 -o "$maven/$archivo" \
            "https://repo1.maven.org/maven2/org/lwjgl/$modulo/$version/$archivo"
    done
done
cp "$maven"/*.jar "$juego/lib/"

cat > "$taller/src/prueba/Juego.java" <<'JAVA'
package prueba;

import org.lwjgl.BufferUtils;
import org.lwjgl.Version;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GL11;
import org.lwjgl.system.Platform;

import java.io.PrintWriter;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/** Abre una ventana con GLFW, pinta naranja y lee el píxel de vuelta. Lo que va pasando queda en
 *  /tmp/lever-java.log, porque la salida estándar de una app lanzada desde el Finder no va a
 *  ninguna parte que se pueda mirar después. */
public class Juego {
    static final List<String> lineas = new ArrayList<>();

    static void apunta(String t) {
        lineas.add("LEVER-PRUEBA " + t);
        try (PrintWriter w = new PrintWriter("/tmp/lever-java.log")) {
            for (String l : lineas) w.println(l);
        } catch (Exception e) { }
    }

    public static void main(String[] args) {
        apunta("arranca java=" + System.getProperty("java.version")
               + " arch=" + System.getProperty("os.arch"));
        apunta("lwjgl=" + Version.getVersion() + " plataforma=" + Platform.get()
               + "/" + Platform.getArchitecture());
        try {
            corre();
        } catch (Throwable t) {
            apunta("FALLA=" + t.getClass().getSimpleName() + ": " + t.getMessage());
            System.exit(1);
        }
        System.exit(0);
    }

    static void corre() {
        if (!GLFW.glfwInit()) throw new IllegalStateException("glfwInit devolvió false");
        apunta("glfw=" + GLFW.glfwGetVersionString());

        long ventana = GLFW.glfwCreateWindow(640, 480, "Prueba Lever Java", 0, 0);
        if (ventana == 0) throw new IllegalStateException("no se creó la ventana");
        GLFW.glfwMakeContextCurrent(ventana);
        GL.createCapabilities();
        apunta("opengl=" + GL11.glGetString(GL11.GL_VERSION));

        ByteBuffer pixel = BufferUtils.createByteBuffer(4);
        int cuadro = 0;
        while (cuadro < 30) {
            GL11.glClearColor(240f / 255f, 160f / 255f, 40f / 255f, 1f);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
            cuadro++;
            // Del buffer trasero y antes de intercambiarlo: después de swap su contenido ya no
            // está definido y leerlo no demostraría nada.
            if (cuadro == 30) {
                GL11.glReadPixels(320, 240, 1, 1, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, pixel);
                apunta("pixel=rgb(" + (pixel.get(0) & 0xff) + "," + (pixel.get(1) & 0xff)
                       + "," + (pixel.get(2) & 0xff) + ")");
            }
            GLFW.glfwSwapBuffers(ventana);
            GLFW.glfwPollEvents();
        }
        apunta("cuadros=" + cuadro);
        GLFW.glfwDestroyWindow(ventana);
        GLFW.glfwTerminate();
    }
}
JAVA

echo "▸ Compilando el juego…"
classpath="$juego/lib/lwjgl-$version.jar:$juego/lib/lwjgl-glfw-$version.jar:$juego/lib/lwjgl-opengl-$version.jar"
# --release 17 fija el formato de clase, que es de donde Lever deduce qué JRE hace falta.
javac --release 17 -nowarn -cp "$classpath" -d "$taller/clases" "$taller/src/prueba/Juego.java"

# El Class-Path del manifiesto nombra los jars de Windows: así es como sale de verdad, y así se
# comprueba que las entradas que quedan colgando después del cambio no molestan.
{
    echo "Main-Class: prueba.Juego"
    printf 'Class-Path:'
    for j in "$juego"/lib/*.jar; do printf ' lib/%s' "$(basename "$j")"; done
    echo
} > "$taller/manifiesto.txt"
jar cfm "$taller/Juego.jar" "$taller/manifiesto.txt" -C "$taller/clases" .

# Un PE mínimo como cabeza, que es lo que Launch4j pone delante de su jar.
python3 - "$taller/stub.exe" <<'PY'
import struct, sys
def le16(v): return struct.pack('<H', v)
def le32(v): return struct.pack('<I', v)
dos = bytearray(b'\0' * 64); dos[0:2] = b'MZ'; dos[60:64] = le32(0x40)
coff = le16(0x14c) + le16(1) + le32(0) + le32(0) + le32(0) + le16(224) + le16(0x0102)
opcional = bytearray(b'\0' * 224); opcional[0:2] = le16(0x10b)
seccion = b'.text' + b'\0' * 3 + le32(16) + le32(0x1000) + le32(16) + le32(0x200) + b'\0' * 16
archivo = bytes(dos) + b'PE\0\0' + coff + bytes(opcional) + seccion
open(sys.argv[1], 'wb').write(archivo + b'\0' * (0x200 - len(archivo)) + b'lanzador de Launch4j\n')
PY

if [ "$reparto" = pegado ]; then
    cat "$taller/stub.exe" "$taller/Juego.jar" > "$juego/Game.exe"
else
    cp "$taller/stub.exe" "$juego/Game.exe"
    cp "$taller/Juego.jar" "$juego/Game.jar"
fi
# Una .dll suelta que no es de LWJGL: no hay de dónde bajar su versión de macOS y Lever tiene que
# nombrarla en vez de callársela.
printf 'binario de windows' > "$juego/steam_api64.dll"

echo "▸ Reparto ($reparto) listo en $juego"
exec bash "$raiz/scripts/probar-traslado.sh" "$juego/Game.exe" "${LEVER_CACHE:-}"
