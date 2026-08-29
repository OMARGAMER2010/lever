# EXE & RAR

Utilidad local y sencilla para macOS Apple Silicon:

- Intenta ejecutar archivos `.exe` mediante un runtime Wine instalado.
- Extrae archivos `.rar` con `7zz`, `unar` o `unrar`.
- No usa servidor, cuentas, base de datos ni telemetría.
- Conserva los archivos existentes durante la extracción y nunca borra el RAR original.

## Requisitos

- macOS 13 o posterior.
- Mac Apple Silicon, como un MacBook Pro M2.
- Swift/Xcode Command Line Tools para compilar desde el código.
- Un runtime Wine para ejecutar `.exe`.
- Homebrew para usar la preparación automática del extractor RAR.

La app no incluye Wine. Busca `wine` en rutas habituales, la instalación estándar de Wine Stable y también permite seleccionar manualmente un ejecutable o una app Wine desde `Buscar Wine`. Wine es una capa de compatibilidad: algunos programas que necesitan drivers, anti-cheat, servicios de Windows o requisitos gráficos especiales no funcionarán.

## Preparar RAR

Desde Terminal:

```bash
brew install sevenzip unar
```

También puedes usar `Preparar herramientas` dentro de la app si Homebrew está disponible.

## Ejecutar desde el código

```bash
swift run ExeRarTests
swift build
```

El primer comando ejecuta las suites locales de descubrimiento, comandos, procesos y estado. Se usa un runner ejecutable porque las Command Line Tools de este equipo no incluyen XCTest.

## Crear la app `.app`

```bash
bash scripts/build-app.sh
open dist/EXE-RAR.app
```

El bundle se genera únicamente para uso local y recibe una firma ad-hoc cuando `codesign` está disponible. No está preparado para distribución notarizada.

## Uso

1. Abre `EXE-RAR.app`.
2. Para Windows, pulsa `Elegir .exe`. Si Wine no aparece como disponible, usa `Buscar Wine`.
3. Para RAR, pulsa `Elegir .rar`, elige la carpeta de destino y pulsa `Extraer`.
4. Revisa el panel `Actividad` para ver el resultado del proceso o el error.
