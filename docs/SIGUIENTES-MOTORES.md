# Lever · traslados nativos: estado y plan

Documento de continuidad. Lo escribo para que otra sesión pueda seguir sin releer el código
entero. Lo **verificado** y lo **por verificar** van marcados aparte a propósito.

---

## 1. La idea de fondo

Muchos `.exe` no son el programa: son un envoltorio. El motor es de Windows, pero los datos del
juego no. Si el motor existe compilado para Mac y se puede descargar, no hay nada que emular:
se juntan las dos mitades y sale una app nativa. Wine pasa a ser el plan B.

Hacen falta **dos condiciones a la vez**:

1. Que los datos no estén *cocinados* para Windows. Unreal cocina los shaders a DirectX: queda fuera.
2. Que el motor de macOS se publique suelto. Unity no lo publica: queda fuera.

Y hay una tercera trampa, que es donde se rompe casi siempre: **las partes nativas del juego**
(GDExtension, `.node`, JNI). Los datos viajan, pero ese trozo de código sigue siendo de Windows.

---

## 2. Qué está hecho y verificado

### Godot 4 — funcionando

- Reconoce por la cabecera `GDPC` del `.pck`, sea archivo aparte o incrustado al final del `.exe`.
- Formatos de paquete 2 (Godot 4.0–4.4) y 3 (4.5+).
- Descarga la plantilla oficial (`.tpz`), extrae solo `templates/macos.zip`, borra el resto.
- Ojo con el nombre de la publicación: Godot llama `4.6-stable` a la 4.6.0, sin el cero.
- El `.pck` dentro del bundle **debe** llamarse igual que el ejecutable.
- **Complemento GoZen** (vídeo `.mp4`): se compila desde fuente con `scripts/build-gozen.sh`.
- Probado de punta a punta con Town's Charm 0.9.1: la app renderiza el menú y reproduce vídeo.

### Ren'Py 7 y 8 — funcionando

- Reconoce por tener a la vez `renpy/` y `game/`.
- Versión de `renpy/vc_version.py`; respaldo `game/script_version.txt`. **No** sirve
  `renpy/__init__.py`: ahí la versión se importa, no hay número literal.
- Descarga `https://www.renpy.org/dl/<X.Y.Z>/renpy-<X.Y.Z>-sdk.zip` y extrae solo `lib/*mac*`.
- El molde del bundle se copió del que genera el propio Ren'Py, comparado byte a byte.
- Probado de punta a punta con «The Question» exportado a Windows con el SDK: la app abre el juego.
- Si el juego ya trae `lib/py3-mac-universal` (paquetes «market» y «steam»), no descarga nada.

### LÖVE (Love2D) 0.9 – 11.5 — funcionando

- Reconoce por dos señales a la vez: `love.dll` en la carpeta y un ZIP con `main.lua` en la raíz,
  esté pegado al final del `.exe` o suelto al lado. La segunda evita confundirlo con cualquier
  instalador autoextraíble, que también es un `.exe` con un ZIP detrás.
- **La versión sale de `love.dll`, no del `.exe`.** `makelove` y `love-release` reescriben el icono
  y el recurso de versión del ejecutable con los del juego: ahí el `.exe` miente. La DLL no la toca
  nadie. Se lee el `VS_FIXEDFILEINFO` del recurso `RT_VERSION`, que da la versión en enteros.
- El principio del `.love` pegado se reconstruye desde el final del directorio central del ZIP
  —tamaño y desplazamiento— porque, al revés que el `.pck` de Godot, no hay ningún pie que lo diga.
  Es lo que hace PhysicsFS, que es con lo que LÖVE monta su propio ejecutable. Contemplado ZIP64.
- Tres convenciones de nombre en las diecisiete publicaciones que existen: `macosx-ub` hasta la 0.8,
  `macosx-x64` de la 0.9 a la 0.10.2 y `macos` de la 11 en adelante. **La 11.0 es la excepción**:
  etiqueta `11.0`, archivo `love-11.0.0-macos.zip`.
- arm64 nativo desde la 11.4 (`changes.txt`: «Added native arm64 support on macOS»). De la 0.9 a la
  11.3 son solo Intel y va con Rosetta. Hasta la 0.8 son universales de 32 bits: macOS ya no los
  ejecuta y se dice, no se intenta.
- Montaje: el `.love` va en `Contents/Resources/` de una copia de `love.app` y el motor lo encuentra
  solo. `getLoveInResources()` pide al bundle *cualquier* archivo con extensión `.love`, así que el
  nombre da igual, y `love.cpp` lo mete como primer argumento junto a `--fused`.
- El binario se renombra al nombre del juego —los `rpath` apuntan al bundle, no al archivo— para
  que el Dock no diga «love».
- El `Info.plist` se parcha, no se escribe de cero: se le quitan `UTExportedTypeDeclarations` y
  `CFBundleDocumentTypes`. Sin eso cada juego se declara dueño del tipo `.love` y editor de
  cualquier documento, y sale en «Abrir con» de todo. Puede quitarse entero porque la rama que lee
  archivos soltados encima solo corre *cuando no hay* un `.love` dentro del bundle.
- Icono: el `t.window.icon` de `conf.lua`, sacado del propio `.love`. Si no hay, queda el corazón
  de LÖVE que ya viene en `Assets.car`.
- Las `.dll` de la carpeta que no son del motor se nombran como partes sin resolver: son módulos de
  Lua compilados (`https`, `luasocket`, `sqlite3`) y no hay ningún sitio de donde bajar su versión
  de macOS.
- Probado de punta a punta con 11.5 y con 0.10.2: juego generado con la receta oficial de Windows
  (`copy /b love.exe+juego.love juego.exe`), trasladado, abierto desde el Finder y comprobado que
  dibuja noventa fotogramas y lee sus datos de dentro del bundle.

### Textos que decían «Godot» y los usaban los tres

`portStageDownloading`, `errPortEngine` y `errPortRuntime` nombraban a Godot, y Ren'Py ya pasaba
por ellos: trasladar una novela visual anunciaba «Descargando el motor de Godot 8.6.0». Corregidos
a texto neutro en los dos idiomas.

### Cómo añadir un motor

1. `Models/<Motor>Models.swift` — hechos del juego, `Sendable` y `Equatable`.
2. `Services/<Motor>Inspector.swift` — `inspect(program:) -> <Motor>Game?`. Devuelve `nil` sin
   drama: que un `.exe` no sea de ese motor es lo normal.
3. `Services/<Motor>Porter.swift` — `makeApp(...) async throws -> PortOutcome`.
4. Un `case` en `PortableEngine` y sus propiedades calculadas.
5. Una rama en `NativePorter.makeApp` y otra en `PortableEngineDetector.detect`.
6. Dos claves de texto: `bodyKey` y `unsupportedKey`, en los dos idiomas.

**La vista y el `AppModel` no se tocan.** Ya son genéricos.

Piezas compartidas en `Services/PortCommands.swift`: `PortCommands` (descargar, descomprimir,
firmar, clonar en APFS, lanzar guiones), `PortPaths` (nombre libre, `.icns`) y `PortSigning`.

---

## 3. Lo que viene, por orden

### 3.1 NW.js — RPG Maker MV y MZ

- Reconocer: `www/index.html` + `package.json` (MV), o `package.json` con `js/` y `data/` (MZ).
- Motor: `https://dl.nwjs.io/v<X.Y.Z>/nwjs-v<X.Y.Z>-osx-arm64.zip`.
- Montaje: el juego entero va como `nwjs.app/Contents/Resources/app.nw`.
- **Por verificar**, y es el punto delicado: de dónde sacar la versión de NW.js. El
  `package.json` no la dice; probablemente haya que leerla del recurso de versión del `.exe` o
  de `nw.dll`. Una versión demasiado nueva rompe juegos viejos: mejor errar por abajo.

### 3.2 Java — y aquí entra «las librerías nativas de Windows»

**Sí se puede arreglar**, y por el mismo mecanismo que GoZen: identificar (nombre, versión) y
bajar el artefacto de macOS que el propio proyecto publica.

- Reconocer: `.exe` de Launch4j (lleva un ZIP con `META-INF/MANIFEST.MF`), o un `.jar` al lado,
  o una carpeta `jre/`.
- Motor: un JRE de Temurin —
  `https://api.adoptium.net/v3/binary/latest/<N>/ga/mac/aarch64/jre/hotspot/normal/eclipse`.
- **Librerías nativas**: el caso dominante es LWJGL, y publica los binarios de cada plataforma
  en Maven Central, por versión:
  `https://repo1.maven.org/maven2/org/lwjgl/lwjgl/<ver>/lwjgl-<ver>-natives-macos-arm64.jar`
  (y lo mismo para `lwjgl-glfw`, `lwjgl-openal`, `lwjgl-opengl`, `lwjgl-stb`, `lwjgl-jemalloc`).
  La versión sale del `MANIFEST.MF` del `lwjgl.jar` que trae el juego. JNA y `sqlite-jdbc`
  también publican jars multiplataforma.
- **Por verificar**: si conviene reescribir el `-Djava.library.path` o basta sustituir los jars.

### 3.3 Electron — y aquí entra «los `.node` nativos»

**También se puede**, con un matiz: hay que acertar el ABI.

- Reconocer: `resources/app.asar` junto al `.exe`.
- Motor: `https://github.com/electron/electron/releases/download/v<X>/electron-v<X>-darwin-arm64.zip`.
- Versión de Electron: **por verificar**. La pista más fiable suele ser la cadena
  `Chrome/… Electron/<X.Y.Z>` que queda dentro del binario; también el recurso de versión del PE.
- **Módulos `.node`**: cada uno es una librería compilada. Tres estrategias, en este orden:
  1. Ya lo tenemos guardado en `PortLibrary`.
  2. Descargar el *prebuild* que publica el módulo (convenciones `prebuild`, `prebuildify`,
     `node-pre-gyp`) para `darwin-arm64` **y el ABI de esa versión de Electron**
     (`process.versions.modules`). El nombre y la versión del módulo salen de
     `app.asar` → `node_modules/<mod>/package.json`.
  3. Recompilar con `@electron/rebuild` — necesita Node y las herramientas de Xcode. Es el mismo
     patrón que `build-gozen.sh`: una receta con su aviso de tiempo y espacio.

### 3.4 Generalizar el resolvedor de partes nativas

Cuando estén Java y Electron, `NativePartRecipe` se queda corto. Lo que pide el problema es un
**resolvedor** con la firma `(nombre, versión, plataforma, abi) -> URL o receta`, con las tres
estrategias de arriba. `PortLibrary` ya es la caché; `NativePartRecipe` ya es la receta. Falta la
estrategia intermedia: la tabla de descargas conocidas.

### 3.5 Android — «lo mismo para los .apk»

Lever hoy **rechaza** los formatos empaquetados y lo dice en su propio mensaje de error. Ese es
el hueco más claro:

- **`.xapk`**: es un ZIP con `base.apk`, varios `config.*.apk`, un `manifest.json` y a veces
  `Android/obb/<paquete>/*.obb`. Instalar: descomprimir, `adb install-multiple base.apk config.*.apk`
  y empujar los OBB a `/sdcard/Android/obb/<paquete>/`.
- **`.apks`** (salida de bundletool): ZIP con `splits/` o `standalones/`. Igual que el anterior.
- **`.aab`**: hace falta `bundletool` (un `.jar` de sus *releases*) y una clave de firma;
  `bundletool build-apks --local-testing` genera un `.apks` instalable.
- **`.apk` sin firmar**: Android lo rechaza. Se arregla generando un almacén de claves de
  depuración y pasando `apksigner`.
- Extra útil: sacar el `.apk` de una app ya instalada (`adb shell pm path` + `adb pull`).

---

## 4. Cómo se trabaja aquí

- **Comentarios en español y explican el porqué**, no el qué. Si un comentario describe la línea
  siguiente, sobra.
- **Nada se da por bueno sin ejecutarlo.** Para Ren'Py generé un juego de Windows real con el SDK
  (`./renpy.sh launcher distribute the_question --package win`) y comparé mi bundle con el que
  produce `--package mac`. Adivinar la estructura habría salido mal.
- Pruebas en `Tests/LeverTests/`, con el corredor propio: registrar en `TestRunner.swift` **y**
  añadir su línea `PASS`. `swift run LeverTests` tiene que salir entero en verde.
- `LocalizationTests` obliga a que ninguna clave se quede sin traducir.
- Los guiones pesados van en `scripts/` y `build-app.sh` los copia dentro del `.app`.
- Construir e instalar: `bash scripts/build-app.sh` y copiar a `~/Desktop/Lever.app`.

### Trampas ya pagadas, para no repetirlas

- `iconutil` falla con el conjunto entero si el `.iconset` trae **un** nombre fuera de su tabla.
- `codesign` exige firmar las piezas internas **antes** que el bundle.
- `screencapture` **no** ve la superficie Metal de Godot a pantalla completa: devuelve el splash
  y parece que está colgado. Verificar con `--write-movie` y sacar un frame del AVI.
- Los botones de SwiftUI no exponen título a System Events: para automatizar clics, coordenadas.
- Un `TemporaryFixture` creado al vuelo se libera en el acto y se lleva la carpeta.
- Al renombrar un archivo Swift queda su `.o` viejo en `.build/`: da símbolos duplicados.
- Un Lever ya abierto **no se entera** de que has reinstalado el `.app`: `open -a` activa el proceso
  viejo y parece que el motor nuevo no se detecta. Salir de la app antes de probar.
- `CFBundleIconName` resuelve contra el catálogo compilado y **gana** al `.icns`: si se deja puesto,
  el icono que montes no se ve nunca.
- El recurso de versión de un `.exe` de un juego lo reescriben las herramientas de empaquetado. La
  versión del motor hay que buscarla en su DLL.

---

## 5. Límites honestos

- **Unity**: los datos son casi portables, pero los shaders van compilados para DirectX y, desde
  IL2CPP, el C# es código máquina x86-64. No hay motor suelto que descargar. Se queda en Wine.
- **Unreal**: los `.pak` están cocinados por plataforma y el C++ del juego va dentro del
  ejecutable. No.
- **GameMaker**: el `data.win` sí es portable, pero el runner de macOS no se distribuye suelto.
- **Godot 3**: se detecta y se avisa; no se traslada. Otra plantilla y otro bundle, y no hay un
  juego de Godot 3 a mano para probarlo.
