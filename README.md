<div align="center">

# Lever

**Abre archivos `.exe` de Windows y descomprime `.rar` en tu Mac.**
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
| **Comprimidos** | Extrae `.rar`, `.zip`, `.7z`, `.tar`, `.iso`, `.cab` y compañía. Admite contraseñas y nunca borra el original. |

Arrastra un archivo a la ventana —o al icono de la app en el Dock— y la app se coloca sola en la
pestaña que toca. También funciona con «Abrir con» desde el Finder.

Español e inglés, con el selector de bandera arriba a la derecha. El idioma se recuerda entre
sesiones y arranca según el del sistema.

## Instalar

```bash
bash scripts/install.sh
```

Compila la app, genera el icono y deja `Lever.app` en el Escritorio, lista para abrir con doble
clic. Si prefieres solo construirla en `dist/`:

```bash
bash scripts/build-app.sh
open dist/Lever.app
```

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

## Desarrollo

```bash
swift run LeverTests    # suite completa, incluidas pruebas de extracción reales
swift build
```

Las pruebas son un ejecutable propio con aserciones a mano: las Command Line Tools de este equipo no
incluyen XCTest. Las de integración se saltan solas si no hay extractores instalados.

```
Sources/
  LeverCore/     Lógica: localizar herramientas, construir órdenes, lanzar procesos
  Lever/          Interfaz SwiftUI
scripts/
  build-app.sh    Compila y arma el .app
  install.sh      Lo anterior + copia al Escritorio
  make-icon.swift Dibuja el icono y genera el .iconset
```

> ⚠️ En `scripts/build-app.sh`, la compilación se hace **antes** de pedir la ruta del binario.
> `swift build --show-bin-path` solo imprime la ruta: no compila. Usarlo como único paso metía en
> el `.app` un binario viejo y la ventana salía vacía.

## Qué esperar de Wine

Wine no es Windows. Los programas que necesitan controladores, sistemas anti-trampas o gráficos
avanzados fallarán. Los instaladores y las utilidades sencillas son los que mejor funcionan. Si un
programa no arranca, no es culpa de la app: es el límite de la capa de compatibilidad.

## Bitácora

- [`progress.md`](progress.md) — qué se ha hecho y por qué
- [`memoria.md`](memoria.md) — contexto del proyecto y trampas conocidas
