<div align="center">

# Lever

**Abre archivos `.exe` de Windows, descomprime `.rar` e instala `.apk` de Android desde tu Mac.**
Sin cuentas, sin servidor, sin telemetría. Todo local.

</div>

> **El nombre.** Una palanca es lo que metes en la rendija de un cajón clavado para abrirlo: eso es
> descomprimir. Y en sentido figurado, *leverage* es la fuerza que te abre una puerta que estaba
> cerrada: eso es lo que hace Wine con un `.exe`. Palabra corriente, sin inventar nada.

---

## Qué hace

| | |
|---|---|
| **Programas** | Ejecuta `.exe` y `.msi` de Windows a través de Wine, en un entorno propio que no toca nada más de tu Mac. |
| **Juegos nativos** | Hay `.exe` que solo son un envoltorio: en Godot el juego vive en el `.pck` de al lado, en Ren'Py son guiones de Python y en LÖVE va pegado al final del propio `.exe`. Esos archivos sirven igual en Mac. La app los junta con el motor oficial de macOS y te deja un `.app` nativo, sin Wine y sin Rosetta. |
| **Comprimidos** | Extrae `.rar`, `.zip`, `.7z`, `.tar`, `.iso`, `.cab` y compañía. Admite contraseñas y nunca borra el original. |
| **Android** | Ejecuta un `.apk` en el propio Mac, dentro de un emulador que la app monta y arranca sola. También sirve un móvil enchufado por USB. Y los formatos que traen la app partida en trozos —`.xapk`, `.apks`, `.aab`— se desmontan, se eligen los trozos que le tocan a tu aparato y se instalan juntos, con sus datos de expansión. |
| **Consolas** | Reconoce un juego de consola por su cabecera —no por la extensión— y lo ejecuta con el núcleo de libretro que le toca, que se descarga solo. Once máquinas, de la NES a la PSP. Los controles se mapean con un diagrama que tiene la forma del mando que tengas enchufado. |
| **Consola híbrida** | Los paquetes `.nsp`, `.xci`, `.nsz` y `.xcz` se abren y se leen: qué juego traen, qué actualizaciones y qué contenido añadido, con su versión y su tamaño. Esa consola **no** la emula un núcleo de libretro, así que el emulador lo pones tú; la app lo encuentra y lanza. Los paquetes comprimidos se rehacen antes de jugar. |
| **Familia PlayStation** | PS2, PS3, PS4 y Vita, cada una con su emulador aparte. Lee el `PARAM.SFO` que llevan dentro —y que va **sin cifrar**— para decirte el título de verdad, la versión y si eso es el juego, un parche o un DLC. Entra en las imágenes de disco, en los `.pkg` y en los `.vpk`, y acepta la **carpeta** del juego, que es como vienen los de PS3 y PS4. |

Arrastra un archivo a la ventana —o al icono de la app en el Dock— y la app se coloca sola en la
pestaña que toca. También funciona con «Abrir con» desde el Finder.

Lo que hayas abierto antes queda en **«Abiertos hace poco»**, con su icono y su tamaño, para no
tener que volver a buscarlo: se abre con un clic. Desde el menú de cada fila puedes cambiarle el
nombre, moverlo a otra carpeta, mostrarlo en el Finder o quitarlo de la lista.

Español e inglés, con el selector de bandera arriba a la derecha. El idioma se recuerda entre
sesiones y arranca según el del sistema.

## Instalar

```bash
bash scripts/install.sh
```

Revisa qué falta, **instala solo lo que se puede instalar sin preguntar**, compila la app, genera
el icono y deja `Lever.app` en el Escritorio, lista para abrir con doble clic.

Si prefieres solo construirla en `dist/`, o solo revisar las dependencias:

```bash
bash scripts/build-app.sh          # compilar y armar el .app
open dist/Lever.app

bash scripts/dependencies.sh          # revisar e instalar lo automático
bash scripts/dependencies.sh --check  # solo informar, sin tocar nada
```

### Qué se instala solo y qué no

`scripts/dependencies.sh` mira los mismos directorios que mira la app —no el `PATH` de tu
terminal, que no es el que hereda una app abierta desde el Finder— y parte lo que falta en dos:

| | |
|---|---|
| **Se instala solo** | `sevenzip` (`7zz`), `unar` y `adb`. Pocos megas, sin licencias, sin contraseña, sin decisiones. |
| **Se explica, no se instala** | Wine, Rosetta 2 y el SDK de Android. Son gigas, o piden tu contraseña, o hay que elegir entre opciones que no son equivalentes. |

Lo del segundo grupo sale impreso con la orden exacta lista para pegar. Instalarlo a ciegas sería
descargar varios gigas que quizá no quieres y elegir por ti entre cosas distintas. La app arranca
igual y te dice qué le falta cuando lo necesita.

## Requisitos

- macOS 13 o posterior (probado en macOS 15, Apple Silicon).
- Xcode Command Line Tools, solo para compilar.

Las herramientas externas **no** vienen incluidas. La app las busca sola y, si falta alguna, ofrece
instalarla con Homebrew desde la propia ventana:

```bash
brew install sevenzip unar     # para los comprimidos
```

Para ejecutar `.exe` hace falta además un runtime Wine y, en los Mac con chip Apple, Rosetta 2
(`softwareupdate --install-rosetta`).

Para ejecutar un `.apk` **dentro del Mac** hace falta un Android dentro: el emulador. La app lo
monta sola —hay un botón en la pestaña Android— o desde la terminal:

```bash
bash scripts/android-emulator.sh
```

Descarga el SDK, la imagen de sistema `arm64` (nativa en un Mac con chip Apple; una `x86_64` se
emularía instrucción a instrucción y sería inservible) y crea el emulador ajustado a la máquina:
2 GB de RAM y 4 GB de disco, para no ahogar un Mac de 8 GB. **Ocupa unos 6 GB y pide 8 libres**,
porque el emulador sigue creciendo con el uso. El guion es idempotente: si se corta, se vuelve a
lanzar y sigue donde estaba.

Si prefieres no gastar ese espacio, con un móvil Android enchufado y la depuración por USB
activada basta `adb`, que ocupa unos megas y lo pone el instalador.

Para los **juegos de consola** hace falta RetroArch, que es quien carga los núcleos:

```bash
brew install --cask retroarch
```

Los núcleos los descarga la app sola, uno por máquina, y **de la arquitectura de RetroArch, no la
del Mac**: un núcleo se carga dentro de su proceso, así que el RetroArch de Intel que instala
Homebrew pide núcleos de Intel aunque el Mac sea de Apple. Lo que la app **no** puede darte son las
BIOS que algunas máquinas exigen —PlayStation, Dreamcast—: salen de una consola de verdad. Se avisa
antes de descargar nada.

La **consola híbrida** es otra cosa y conviene decirlo claro:

- **No hay núcleo de libretro para ella.** Hace falta un emulador entero aparte, que instalas tú.
  La app no lo descarga y no fija ninguno: busca el que tengas —la línea de Ryujinx y sus
  bifurcaciones, Sudachi, Citron, Eden— y también acepta el que le señales a mano. Los dos
  emuladores originales cerraron en 2024, así que una dirección de descarga fija en el código
  apuntaría a un enlace roto en unos meses.
- **Las llaves del sistema las pones tú.** Un `prod.keys` sale de una consola; no se descarga y la
  app no trae ninguna. Sin él se ve igual qué hay dentro del paquete —qué juego, qué
  actualizaciones, qué añadidos— porque el índice va en claro; lo que no se ve es el nombre y el
  icono, que están dentro de una pieza cifrada. La ruta del archivo se guarda en los ajustes;
  **el contenido no**: se lee cuando hace falta y se olvida.
- Para rehacer un `.nsz` o un `.xcz` hace falta `zstd` (`brew install zstd`). El paquete rehecho va
  a una carpeta de la app, pesa lo que pesa el juego y se hace una vez.

Para la **familia PlayStation**, cada máquina tiene lo suyo y no todas están igual de maduras.
Lever te lo dice en la propia ventana en vez de dejarte descubrirlo:

| Máquina | Emulador | Estado | Qué más hace falta |
|---|---|---|---|
| PlayStation | núcleo `swanstation` | se juega | BIOS de una PS1 |
| PSP | núcleo `ppsspp` | se juega | nada |
| PlayStation 2 | PCSX2 | se juega | BIOS de una PS2 |
| PlayStation 3 | RPCS3 | experimental | firmware `PS3UPDAT.PUP` |
| PlayStation 4 | shadPS4 | experimental | nada |
| PS Vita | Vita3K | experimental | nada |
| PlayStation 5 | — | **no existe** | — |

Las dos primeras ya funcionaban: las lleva RetroArch con su núcleo y no hace falta instalar nada
más. Las cuatro siguientes necesitan su programa, que instalas tú.

Y una distinción que importa más de lo que parece: **la BIOS de una PS2 sale de una PS2** y no hay
descarga que valga, pero **el firmware de una PS3 lo publica Sony** en su web para cualquiera, y
RPCS3 lo pide por su nombre. Tratarlos como si fueran lo mismo deja a la gente atascada sin motivo,
así que Lever los distingue y te dice de cuál se trata.

De la **PlayStation 5 no existe ningún emulador**. No es que Lever no lo traiga: no lo hay. Lo que
circula anunciado como tal no es un emulador, y bajarlo es un mal negocio. Si sueltas un juego de
PS5, Lever lo reconoce y te lo dice.

**Qué Wine usar en un Mac con chip Apple.** Los casks de WineHQ (`wine-stable`, `wine@devel`,
`wine@staging`) están obsoletos por no pasar el control de Gatekeeper y Homebrew los desactiva el
2026-09-01; además fallan al crear el entorno de Windows. La opción libre que funciona es el Game
Porting Toolkit de Gcenx:

```bash
brew tap gcenx/wine
HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask gcenx/wine/game-porting-toolkit
```

Choca con `wine-stable`, así que hay que desinstalar ese antes. La app trae una hoja con estas
opciones y la orden lista para copiar: está en el aviso «Falta Wine».

## Lo que la app te dice antes de que pierdas el tiempo

**Qué extractor abrirá tu archivo, y por qué.** Es la decisión menos evidente que toma y la que más
daño hace si se equivoca.

**Si tu `.exe` es de 32 o 64 bits**, leído de su cabecera PE. Los Wine que funcionan hoy en Mac con
chip Apple son solo de 64 bits, así que un programa de 32 no va a arrancar: mejor saberlo antes de
esperar dos minutos a que se cree el entorno de Windows.

**Si el comprimido está partido en varias partes o pide contraseña**, antes de intentar extraerlo.

**Si el `.apk` no va a instalarse en el aparato que has elegido.** Un paquete trae código nativo
para procesadores concretos (`arm64-v8a`, `x86_64`…) y pide una versión mínima de Android; el
aparato dice cuáles ejecuta y cuál tiene. Si no coinciden, `adb` falla con
`INSTALL_FAILED_NO_MATCHING_ABIS` después de que hayas esperado a que arranque el emulador. La app
compara las dos listas antes y lo dice en una frase. Es la misma promesa que con los 32 bits de un
`.exe`, con otro dominio.

**Si el `.apk` es un trozo de un App Bundle** —un «split», sin `classes.dex`— que Android va a
rechazar siempre porque no es una app entera.

**Si el `.apk` viene sin firmar**, que Android también rechaza siempre. La app lo firma con una
clave suya antes de instalarlo, y avisa de la consecuencia: a partir de ahí ese juego ya no podrá
actualizarse encima con una versión firmada por su autor.

**Si un archivo de la lista ya no está.** Se comprueba al leerla, no al guardarla: entre dos
sesiones puede haberse movido o borrado desde fuera. Los que faltan salen apagados, con su carpeta
para saber dónde estaban, y lo único que se ofrece de ellos es quitarlos.

**En qué postura arranca la app.** Se lee `android:screenOrientation` de la actividad de inicio
—la que lleva el filtro `LAUNCHER`, no la primera que aparezca— y la pantalla se pone vertical u
horizontal antes de abrirla. Con un aviso honesto: muchos juegos hechos con Unity no lo declaran y
deciden la postura desde su propio código al arrancar, así que hay un conmutador
**Automática / Vertical / Horizontal** que manda sobre lo que diga el manifiesto.

## Detalles que importan

**Para los `.rar` se usa `unar`, no `7zz`.** No es un capricho: `7zz` no sabe descomprimir varios
métodos de RAR antiguos y, en vez de negarse, **crea los archivos vacíos, de 0 bytes**. `unar` los
abre todos. Para el resto de formatos manda `7zz`, que es más rápido, cubre más y va informando del
progreso. Si el primero falla, la app reintenta sola con el otro.

**Wine se ejecuta en un entorno aparte.** La app crea su propio «disco C:» en
`~/Library/Application Support/Lever/wine`, así que no pisa un `~/.wine` que ya tuvieras. Se puede
abrir, configurar o borrar desde el menú de herramientas.

**macOS bloquea Wine si viene de Homebrew.** Los `.cask` se marcan como descargados de internet y
macOS cierra Wine nada más abrirlo, sin mensaje alguno. La app lo detecta y ofrece desbloquearlo con
un botón.

**Nada se cuelga esperando.** Todos los procesos se lanzan con la entrada cerrada, así que un
comprimido con contraseña falla con un error legible en vez de quedarse esperando para siempre.

**El `.apk` se lee a mano, sin el SDK de Android.** Un `.apk` es un `.zip` con un
`AndroidManifest.xml` en formato binario dentro, y los dos formatos están documentados: la app los
lee directamente para sacar el paquete, la versión, el Android mínimo y los ABIs. Pedir `aapt2`
—varios gigas de build-tools, más Java, más aceptar licencias— para poder avisar de que algo no va
a funcionar sería cobrar el diagnóstico más caro que la instalación.

**Una app partida en trozos hay que repartirla a mano.** Google partió las apps: un `.apk` por
procesador, otro por densidad de pantalla, otro por idioma. Play le manda a cada móvil los suyos, y
fuera de Play no hace eso nadie. Instalarlos todos no vale —dos trozos del mismo procesador se
pisan y Android rechaza el conjunto— y con la base sola la app se cierra al abrirla, sin sus
librerías. Así que la app pregunta al aparato qué procesador y qué densidad tiene y elige: uno de
cada, y todos los idiomas, que pesan poco y evitan que el juego se quede en inglés el día que
cambies el idioma del móvil.

**De un `.apks` y de un `.aab` se encarga `bundletool`, que es su dueño.** Un `.xapk` trae los
trozos planos y se eligen por el nombre, pero un `.apks` guarda en un `toc.pb` en protobuf la tabla
de qué variante le toca a cada aparato, y esa tabla la escribe y la entiende la herramienta de
Google. Se descarga sola la primera vez —32 MB— y se dice antes de empezar, con Java al lado si
tampoco lo tuvieras. Adivinar esa tabla habría sido inventarse el reparto.

**Los `.obb` van a una ruta que no se elige.** Los juegos grandes reparten sus datos aparte, en
archivos de expansión, y Android solo los busca en `Android/obb/<paquete>/` con el nombre exacto
que lleva dentro el número de versión. Se copian de uno en uno: pasan de los dos gigas y tener dos
a la vez en el disco, para nada, es la diferencia entre que quepa y que no.

**`adb install` no siempre falla con un código de error.** Hay versiones que terminan con código 0
y escriben «Failure [...]» por la salida. La app lee el texto, no solo el código, y traduce cada
motivo conocido a una frase que dice qué hacer.

**De un móvil solo se toca lo que le pidas.** La app instala, abre y desinstala el paquete que le
has dado, y nada más. «Desinstalar» solo aparece después de una instalación que salió bien.

## Desarrollo

```bash
swift run LeverTests    # suite completa, incluidas pruebas de extracción reales
swift build
```

Las pruebas son un ejecutable propio con aserciones a mano: las Command Line Tools de este equipo no
incluyen XCTest. Las de integración se saltan solas si no hay extractores instalados.

```
Sources/
  LeverCore/          Lógica: localizar herramientas, construir órdenes, lanzar procesos
    ApkInspector        Lee el zip y el AndroidManifest.xml binario de un .apk
    AndroidBundleInspector  Abre .xapk, .apks y .aab y dice qué trozos hay dentro
    AndroidInstaller    Elige los trozos del aparato, firma si hace falta e instala
    AndroidTools        Consigue bundletool, el firmador y el Java que los mueve
    AndroidLauncher     Órdenes de adb y del emulador, y lectura de sus respuestas
    RecentFiles         La lista de abiertos hace poco: renombrar, mover, quitar
  Lever/              Interfaz SwiftUI
scripts/
  build-app.sh        Compila y arma el .app
  dependencies.sh     Revisa e instala lo que falta
  android-emulator.sh Monta el SDK de Android y crea el emulador
  probar-android.sh   Fabrica una app real en los cuatro formatos y la instala de verdad
  install.sh          Lo anterior + copia al Escritorio
  make-icon.swift     Dibuja el icono y genera el .iconset
```

> ⚠️ En `scripts/build-app.sh`, la compilación se hace **antes** de pedir la ruta del binario.
> `swift build --show-bin-path` solo imprime la ruta: no compila. Usarlo como único paso metía en
> el `.app` un binario viejo y la ventana salía vacía.

## Qué esperar de cada cosa

### Wine

Wine no es Windows. Los programas que necesitan controladores, sistemas anti-trampas o gráficos
avanzados fallarán. Los instaladores y las utilidades sencillas son los que mejor funcionan. Si un
programa no arranca, no es culpa de la app: es el límite de la capa de compatibilidad.

### Android

Un `.apk` no se ejecuta *directamente* en macOS como un `.exe` bajo Wine: hace falta un Android
donde instalarlo, y por eso esta pestaña tiene algo que las otras no necesitan —elegir dónde—.
Pulsar **Ejecutar** hace la cadena entera: arranca el emulador si no hay ningún aparato, espera a
que termine de arrancar, instala, abre la app y pone la pantalla en su postura.

El emulador es Android de verdad corriendo en arm64, nativo en tu chip. Los juegos 2D y las apps
normales van bien; los juegos 3D pesados y todo lo que lleve anti-trampas sufrirá o no arrancará.
Con 8 GB de RAM, cerrar cosas antes ayuda.

Instalar fuera de Google Play se salta sus comprobaciones. Pon solo archivos de origen conocido.

## Bitácora

- [`progress.md`](progress.md) — qué se ha hecho y por qué
- [`memoria.md`](memoria.md) — contexto del proyecto y trampas conocidas
