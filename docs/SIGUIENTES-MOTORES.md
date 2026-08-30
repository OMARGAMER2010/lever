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

### NW.js (RPG Maker MV y MZ) — funcionando

- Reconoce por dos señales a la vez: `nw.dll` en la carpeta y un `package.json` con `main`. Por
  separado no dicen nada; `package.json` lo tiene medio mundo.
- **La versión sale de `nw.dll`**, con el mismo lector que LÖVE. RPG Maker renombra `nw.exe` a
  `Game.exe` y hay herramientas que de paso le reescriben la versión al ejecutable.
- Descarga `https://dl.nwjs.io/v<X.Y.Z>/nwjs-v<X.Y.Z>-osx-<x64|arm64>.zip`. La lista de versiones
  y de qué archivos existen para cada una está en `https://nwjs.io/versions.json`. Binarios de
  Apple silicon desde la 0.77.0; antes solo Intel.
- **El motor que se monta casi nunca es el del juego, y eso es lo que hace que esto sirva de
  algo.** El suelo medido en macOS 15 sobre un M2 es la **0.77.0**: la 0.48.4 arranca el proceso y
  lo mantiene vivo los veinte segundos, pero la página no llega a ejecutar ni su primera línea; la
  0.77.0 y la 0.115.0 la ejecutan entera. El corte cae justo en la primera compilación de arm64, y
  como por debajo no existe ninguna, no se puede separar «Rosetta» de «Chromium viejo»: lo medido
  es dónde está el corte, no cuál de los dos lo causa. Como MV reparte la 0.29 y MZ la 0.48,
  respetar la versión del juego habría dejado fuera a todo RPG Maker.
- Se puede sustituir porque un juego de NW.js es HTML y JavaScript y no lee ningún formato atado a
  su motor, al revés que Godot con su `.pck` o Ren'Py con su bytecode. Comprobado en la 0.77.0 y en
  la 0.115.0 que van las cuatro cosas de las que depende RPG Maker: leer sus datos con XHR desde
  `file://`, guardar con `fs`, WebGL y pintar. Y `require('nw.gui')` —la API anterior a la 0.13—
  sigue existiendo en la 0.115, así que ni siquiera un juego muy viejo se queda sin ella.
- Se monta **la más antigua que dibuja**, no la última: mover el suelo bajo el juego lo menos
  posible. Y se dice en el panel, con su aviso propio, en vez de cambiárselo callando.
- Montaje: el juego entero, sin los archivos del motor, va a `Contents/Resources/app.nw/`. La
  separación se hace por descarte porque los repartos no se parecen —MV mete todo en `www/`, MZ lo
  deja suelto—, mientras que la lista de archivos que pone NW.js sí es fija.
- Nombre: del `window.title` del `package.json`, no del `.exe`. RPG Maker llama `Game.exe` a todo
  lo que exporta.
- Probado de punta a punta con los dos repartos —`bash scripts/probar-nwjs.sh [versión] [mv|mz]`—:
  un MZ con 0.48.4 y un MV con 0.29.4 se trasladan montando la 0.77.0, y la app abre, lee sus datos
  desde `file://`, guarda y pinta treinta cuadros. Y desde la ventana de Lever: el panel dice las
  dos versiones, el botón descarga la 0.77.0 y la app que deja en el Escritorio dibuja.
- **Lo que sigue sin comprobarse**: un juego de RPG Maker de verdad. No hay ninguno a mano y el
  editor es de pago. Lo medido es que el motor nuevo hace lo que MV y MZ necesitan; lo que no se
  puede afirmar es que ningún complemento de ningún juego dependa de algo que Chromium cambiara
  por el camino.

### Java (Launch4j y LWJGL) — funcionando

- Reconoce por un jar con `Main-Class` en su manifiesto: pegado al final del `.exe` —lo que hace
  Launch4j— o suelto al lado. Un `.exe` sin eso no tiene nada que lanzar, y un jar sin `Main-Class`
  es una librería. Va el último en el detector: su señal es la más laxa de las cinco.
- **Qué Java hace falta**: si el reparto trae un `jre/`, su `release` manda —dice con qué lo probó
  su autor, no el mínimo con el que compila—; si no, el número mayor del formato de la clase
  principal menos 44, que es la tabla del propio JVM (52 es Java 8, 61 es Java 17).
- **Motor**: el JRE de Temurin, `https://api.adoptium.net/v3/binary/latest/<N>/ga/mac/<aarch64|x64>/jre/hotspot/normal/eclipse`.
  Viene en `.tar.gz` —el único de los cinco que no es ZIP— y como bundle firmado de macOS, así que
  el `java` está en `Contents/Home/bin/java`. Solo se piden versiones de soporte largo: pedir una
  que Adoptium ya no publique da un 404 a mitad del traslado.
- **Java 8 no existe para Apple silicon.** Comprobado contra la API de Adoptium: de la 11 en
  adelante hay `aarch64`, de la 8 solo `x64`. Un juego de Java 8 baja el de Intel y va con Rosetta,
  que es más fiel que subirlo a la 11 —donde se quitaron cosas— sin un juego con el que
  comprobarlo. La arquitectura elegida arrastra también a los nativos de LWJGL.
- **Las librerías nativas sí tienen arreglo, y basta con cambiar el jar.** LWJGL 3 carga sus
  binarios del propio classpath, no de `java.library.path`: no hay que tocar cómo se lanza el
  juego. Medido con un juego hecho a mano: con el jar de Windows falla con
  `UnsatisfiedLinkError: liblwjgl.dylib` y LWJGL avisa de «Platform/architecture mismatch»;
  cambiando solo el jar, arranca y pinta. Eso responde el «por verificar» que había aquí.
- Cada jar de nativos se reconoce por `LWJGL-Platform` de su manifiesto, no por el nombre del
  archivo. De ahí salen también el artefacto de Maven (`Implementation-Title`: `lwjgl`,
  `lwjgl-glfw`…) y la versión (`Specification-Version`; **`Implementation-Version` no sirve, ahí
  pone «build 1»**). La versión tiene que ser la misma: LWJGL comprueba que los bindings y los
  binarios coincidan y se niega a arrancar si no.
- **Ojo con el nombre del archivo de Intel**: es `natives-macos` a secas, sin `-x64`. El de ARM sí
  lleva sufijo, `natives-macos-arm64`. Es la misma trampa de nombre que LÖVE.
- **Montaje**: es el único motor sin un `.app` de plantilla que copiar, porque Java no publica
  ninguno, así que el bundle se arma entero. El juego va a `Contents/Resources/`, el JRE a
  `Resources/jre/`, y `Contents/MacOS/<nombre>` es un guion de shell. Un guion puede ser el
  ejecutable de un bundle y aguanta `codesign --deep`: comprobado firmando y abriendo desde el
  Finder.
- **`-XstartOnFirstThread` no es opcional** con GLFW: sin él, LWJGL se niega en seco con «GLFW may
  only be used on the main thread». Y el `exec` del guion tampoco, porque esa bandera exige que la
  máquina virtual sea el primer hilo del proceso, y eso solo se cumple si sustituye al shell.
  **No se pone siempre**: con AWT o Swing esa bandera estorba, porque su bucle de eventos quiere
  para sí el mismo hilo. Se pone cuando el juego trae `lwjgl-glfw`.
- El classpath se nombra entero en el guion en vez de fiarse del `Class-Path` del manifiesto: no
  todos los repartos lo traen, y muchos dejan esa lista en un `.bat` que no viaja. Las entradas del
  manifiesto que quedan colgando tras el cambio de nativos se ignoran sin ruido.
- El guion hace `cd` a `Resources` antes de lanzar: el juego busca sus datos por rutas relativas,
  como cuando lo lanzaba su `.exe` desde la carpeta del juego.
- Icono: solo si el reparto dejó un `.png` reconocible al lado. El de verdad va dentro del `.exe`,
  en los recursos del PE, y sacarlo de ahí es otro trabajo; mejor sin icono que con uno inventado.
- Probado de punta a punta con los dos repartos —`bash scripts/probar-java.sh [versión] [pegado|suelto]`—:
  un juego de LWJGL 3.3.6 compilado con `javac` de verdad, con sus jars de Maven y su `.exe` estilo
  Launch4j, se traslada y la app abre una ventana, arranca OpenGL sobre Metal y pinta treinta
  cuadros del color esperado. Y desde la ventana de Lever, con el botón, hasta la app del
  Escritorio.
- **Lo que sigue sin comprobarse**: un juego comercial de Java de verdad, y los repartos que no
  usan LWJGL —AWT/Swing, o LWJGL 2, que sí carga por `java.library.path` y necesitaría otra rama—.
  Lo medido es el camino de LWJGL 3, que es el dominante.

### Electron — funcionando

- Reconoce por `resources/app.asar` al lado del `.exe`. Es como el propio Electron encuentra el
  código de la app, y ningún otro motor de los contemplados reparte así.
- **La versión del motor sale del archivo `version` de la raíz.** No del recurso del PE, y esto no
  es una precaución teórica: comprobado con `electron-packager`, que renombra `electron.exe` al
  nombre del juego y de paso le reescribe el recurso con la versión **del juego**. Un reparto de
  Electron 44 declara ahí «1.0.0.0». Es la misma trampa que en LÖVE, con otro disfraz.
- Respaldo, si el reparto no trae el archivo: la cadena `Chrome/… Electron/<X.Y.Z>` que queda
  dentro del ejecutable y sobrevive al renombrado. Cae por el último tercio de un binario de 244 MB,
  así que se busca por trozos con solape —y con `Data.range(of:)`, no comparando a mano: recorrer
  eso rebanada a rebanada tarda **minutos**—.
- **Motor**: `https://github.com/electron/electron/releases/download/v<X>/electron-v<X>-darwin-<arm64|x64>.zip`.
  Binarios de Apple silicon **desde la 11.0.0**, comprobado contra sus publicaciones: la 10.4.7
  solo tiene `darwin-x64`. Antes de la 11 la app irá con Rosetta y se avisa.
- **Montaje comparado con el que produce `electron-packager` para el mismo juego**, que es lo único
  que evita adivinar: copiar `Electron.app`, renombrar `Contents/MacOS/Electron`, poner el
  `app.asar` donde estaba el `default_app.asar`, y reescribir la ficha. La estructura sale idéntica
  salvo el `_CodeSignature` —Lever sí firma— y el identificador, que va en el espacio de Lever.
- **Hay que renombrar los cuatro ayudantes anidados** (`Electron Helper.app`, `… (GPU)`,
  `… (Plugin)`, `… (Renderer)`), su binario de dentro y su `Info.plist`. En Chromium los procesos
  que dibujan son esos y el principal los busca por un nombre derivado del suyo. Los binarios son
  **idénticos** —mismo SHA1 antes y después—: lo único que cambia es el nombre. Ojo: los ayudantes
  del motor **no traen `CFBundleExecutable`**, así que no basta con reescribirlo, hay que ponerlo.
- `NSPrincipalClass` se queda como está: en Electron es `AtomApplication`. Y hay que firmar con
  `codesign --deep`, como en NW.js, por los `.app` anidados.
- Se lee el `.asar` desde Swift, en `AsarArchive.swift`. No es un ZIP y no comprime: cuatro enteros
  de 32 bits, un JSON con el árbol —tamaño y desplazamiento de cada archivo, **el desplazamiento
  como cadena** porque en JavaScript un entero grande pierde precisión— y detrás los contenidos
  pegados. De ahí salen el `productName` del juego y los módulos nativos.
- **Módulos `.node`**: se encuentran en los dos sitios donde pueden estar —sueltos en
  `app.asar.unpacked/`, que es lo normal porque `dlopen` no lee de dentro de un asar, y dentro del
  propio asar—, se identifican con nombre, versión y repositorio del `package.json` del módulo, y
  **se sustituyen** por el prebuild que publica cada uno. Ver «Partes nativas».
- El panel **no** los lista como partes que van a faltar antes de trasladar: saber si hay binario
  publicado para esa combinación pide red, y prometerlo antes sería mentir la mitad de las veces.
  Lo dice el traslado, cuando ya lo sabe.
- Probado de punta a punta con `bash scripts/probar-electron.sh [versión]`, que arma el reparto con
  `@electron/packager` —la herramienta del propio motor, no una imitación— y le mete un módulo
  nativo **de verdad**: better-sqlite3 instalado con npm y con su binario de Windows encima. La app
  trasladada abre, carga el módulo y lo usa (`modulo-nativo=7`), lee sus datos, arranca WebGL y
  pinta treinta cuadros del color esperado.
- La versión por omisión de esa prueba es la 42.10.1 a propósito: su ABI es el 146, el más nuevo
  para el que better-sqlite3 12.11.1 publica binarios de macOS y de Windows a la vez.
- Comprobado también en la ventana de Lever: el panel dice «Este juego está hecho con Electron
  42.10.1», anuncia los 130 MB del motor, y el botón deja en el Escritorio una app que carga su
  módulo nativo y dibuja.
- **Lo que sigue sin comprobarse**: un juego comercial de Electron de verdad, una versión anterior
  a la 11 —que va por Rosetta y podría chocar con lo mismo que NW.js: Chromium viejo de x86_64 no
  arranca su proceso de dibujo en macOS 15—, y `app.asar.unpacked` con un módulo nativo que el
  juego use de verdad.

### Partes nativas: un solo resolvedor — funcionando

Los tres motores con partes nativas hacían lo mismo sin conocerse. Ahora comparten
`NativeParts.swift`, y lo único que se queda con cada motor es armar la dirección, que es lo que
depende del ecosistema.

- **La identidad de una parte son cuatro señas**: nombre, versión, plataforma y —cuando va atada a
  una— el ABI. Eso es también la clave de la caché (`PortLibrary.nativePartURL`), y llevar el ABI
  dentro no es cosmético: un `.node` de otro ABI no da error al montar, solo al arrancar.
- **Las tres estrategias, en orden**: lo que ya está guardado se usa; lo que se sabe de dónde bajar
  se baja; y lo que no, se nombra. Un 404 no es un fallo del traslado: quiere decir que ese módulo
  no publica esa combinación, que es de lo más normal.
- **LWJGL** (Java): artefacto de Maven Central por (módulo, versión, plataforma). Sin ABI.
- **Prebuilds de Node** (Electron): la convención de `prebuild-install`,
  `<módulo>-v<versión>-electron-v<abi>-darwin-<arch>.tar.gz`, en las publicaciones de GitHub del
  propio módulo bajo la etiqueta `v<versión>`. El `owner/repo` sale del campo `repository` de su
  `package.json`, que admite media docena de formas. **Solo GitHub**: de un repositorio en otro
  sitio no sale ninguna dirección que pedir, y devolver algo sería inventársela.
- **El ABI sale del registro de `node-abi`**, que es el mismo que usa `prebuild-install`, así que
  por construcción coincide con lo que los módulos publican. Depende solo del número mayor de
  Electron. Pesa ocho kilobytes, así que se vuelve a bajar cada vez en lugar de tenerlo escrito a
  mano y que envejezca; si no hay red se usa la copia guardada, y si tampoco, no se adivina.
- Comprobado de punta a punta, que era lo que faltaba: un juego de Electron con better-sqlite3
  puesto con su `.node` de Windows (`PE32+ DLL`) sale trasladado con el de macOS y el juego lo
  carga y lo usa.
- **Lo que sigue sin comprobarse**: un módulo con ámbito (`@scope/nombre`), donde la convención dice
  que el ámbito no entra en el nombre del archivo pero no hay ningún caso a mano; y las otras dos
  convenciones de prebuilds, `prebuildify` —que mete los binarios dentro del propio paquete de npm,
  así que no hay nada que bajar— y `node-pre-gyp`, que usa otra plantilla de dirección.

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

### 3.1 Android — «lo mismo para los .apk»

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
- `NSPrincipalClass` en un `.app` de Chromium **no** es `NSApplication`, es `BrowserCrApplication`.
  Quitarla deja la app sin nada que arrancar.
- Un motor con `.app` anidados dentro (NW.js esconde cuatro ayudantes en su framework) hay que
  firmarlo con `codesign --deep`. Firmando archivo a archivo, el bundle de fuera queda «not signed
  at all» y macOS no lanza los procesos hijos, que en Chromium son los que dibujan.
- NW.js deja `SingletonLock` y un zócalo en el directorio temporal. Matar sus procesos a lo bruto
  deja el siguiente arranque esperando en ellos.
- El recurso de versión de un `.exe` **de Electron** dice la versión del juego, no la del motor:
  `electron-packager` se lo reescribe al renombrarlo. La del motor está en el archivo `version`.
- Buscar una cadena en un binario de doscientos megas comparando rebanadas a mano tarda minutos.
  `Data.range(of:)` lo hace en menos de un segundo. Es una función que corre al elegir un archivo.
- `unzip` sale con **1** —aviso, no error— cuando el ZIP lleva bytes delante: extrae bien igual.
  Exigirle un 0 deja fuera precisamente el reparto de Launch4j, que es un jar detrás de un `.exe`.
- **Restar cadenas para sacar una ruta relativa sale mal en el temporal.** `/var` es un enlace a
  `/private/var` y `/tmp` a `/private/tmp`: el enumerador de archivos devuelve la ruta ya resuelta
  y la carpeta de partida casi nunca lo está, así que la resta no encuentra nada y deja la ruta
  absoluta entera. No falla en el acto: falla después, montando media jerarquía del disco dentro
  del bundle. Está resuelto en `PortPaths.relativePath(of:from:)`; usarlo.
- Un paso que dice «hecho» sin comprobar que lo hizo esconde el fallo hasta el final. El cambio de
  nativos de LWJGL anunciaba los tres jars cambiados mientras no cambiaba ninguno.
- Un NW.js anterior a la 0.77 en un Mac de Apple silicon abre el proceso, lo mantiene vivo y no
  ejecuta la página: ni una línea, ni un error, ni en su salida ni en la del sistema. Buscarle la
  causa al montaje, a la firma o al aislamiento es perder la sesión; lo que hay que mirar es la
  versión del motor.
- `requestAnimationFrame` no corre si la ventana queda detrás. Para una sonda automática, temporizador.
- `process.stdout` desde la página no llega a la terminal en las versiones viejas de NW.js. Para
  saber hasta dónde llega el arranque, una baliza HTTP contra un servidor local: no depende de Node
  ni de que la página tenga permisos.

---

## 5. Límites honestos

- **Unity**: los datos son casi portables, pero los shaders van compilados para DirectX y, desde
  IL2CPP, el C# es código máquina x86-64. No hay motor suelto que descargar. Se queda en Wine.
- **Unreal**: los `.pak` están cocinados por plataforma y el C++ del juego va dentro del
  ejecutable. No.
- **GameMaker**: el `data.win` sí es portable, pero el runner de macOS no se distribuye suelto.
- **Godot 3**: se detecta y se avisa; no se traslada. Otra plantilla y otro bundle, y no hay un
  juego de Godot 3 a mano para probarlo.
