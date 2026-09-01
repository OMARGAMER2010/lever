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

### Android: los formatos empaquetados — funcionando

Hasta ahora Lever solo instalaba un `.apk` suelto y rechazaba el resto con un mensaje que mandaba
al usuario a buscarse la vida. Ahora entran los cuatro formatos y el `.apk` sin firma.

- **Reconoce por la extensión**, que aquí sí basta: `.apk`, `.xapk` y `.apkm` (que por dentro es un
  `.xapk`), `.apks` y `.aab`. Un envoltorio es un ZIP con varios `.apk` dentro.
- **Los datos de la app salen del `.apk` de base, no de la ficha.** El `manifest.json` de un
  `.xapk` lo escribe quien empaquetó y no siempre dice la verdad; se saca la base a un archivo
  temporal y se lee con el mismo lector de siempre. La ficha vale para dos cosas que no están en
  ningún otro sitio —la lista de trozos y la de expansiones— y como respaldo si la base no se abre.
- **Cuál es la base, por capas**: lo que declare la ficha; el que se llame `base.apk`; el
  `…-master.apk` de `bundletool`; y si nada de eso, el único que no parece un trozo de
  configuración. Esa última capa existe porque hay `.xapk` viejos donde la base se llama con el
  nombre del paquete, `com.ejemplo.juego.apk`.
- **Elegir los trozos es la parte que hacía Play y fuera de Play no hace nadie.** Del procesador va
  uno solo, el primero de `ro.product.cpu.abilist` que el paquete traiga; de la densidad, la que
  llega o pasa los puntos por pulgada del aparato —una pantalla de 420 usa xxhdpi (480) encogido, no
  xhdpi (320) estirado—; de los idiomas, **todos**, que pesan poco y elegir uno deja el juego en
  inglés el día que cambies el idioma del móvil. Los módulos aparte también, porque aquí no hay
  quien los descargue después.
- **Instalar los trozos es una sola sesión**, `adb install-multiple`. De uno en uno falla el
  primero: un trozo suelto no tiene con qué formar una app.
- **Los `.obb`** se sacan y se empujan de uno en uno a `/sdcard/Android/obb/<paquete>/`, que es la
  única ruta donde Android los busca, con el nombre exacto que traen —lleva dentro el número de
  versión con el que la app los pide—. `adb push` no crea la carpeta: hay que hacerla antes.
- **`.apks` y `.aab` son de `bundletool`.** Un `.apks` guarda en su `toc.pb`, en protobuf, qué
  variante le toca a cada aparato; esa tabla la escribe y la entiende su herramienta. Para un
  `.aab`: `build-apks --connected-device` genera solo los trozos de ese aparato y `install-apks`
  los instala. Se descarga el `bundletool-all.jar` (32 MB) a la biblioteca, con la misma regla que
  los motores: lo que ya está no se vuelve a bajar.
- **Firmar un `.apk` sin firma**: se reconoce por no tener ni certificado en `META-INF/` ni el
  bloque de firma moderno delante del directorio central. Se firma **una copia**, nunca el archivo
  del usuario, con `zipalign` primero y `apksigner` después. La clave y el certificado se hacen una
  vez con el `openssl` que trae macOS —así firmar no depende de tener Java para nada más— y se
  guardan; que sea siempre la misma importa, porque si cambiara, un juego firmado ayer no podría
  actualizarse con el de hoy.
- **`apksigner` se ejecuta como `java -jar`, no por su guion**: el guion se busca un Java por su
  cuenta y aquí ya sabemos cuál queremos. Sale de las build-tools del SDK si el usuario las tiene,
  y si no se bajan (76 MB).
- Probado de punta a punta con `bash scripts/probar-android.sh`, que compila una app de Android de
  verdad con `aapt2`, `d8` y `apksigner`, la empaqueta en los cinco casos con `bundletool` y la
  instala con el instalador de Lever en el emulador: los cinco instalan y **la app arranca**, que
  es lo que se comprueba —no que `adb` dijera «Success»—. Y desde la ventana de Lever: el panel
  dice «11 trozos dentro · 200 KB de datos aparte», el botón instala cuatro trozos y empuja el
  `.obb`, y con el `.apk` sin firma el panel avisa y el botón lo firma e instala.
- **Lo que sigue sin comprobarse**: un `.xapk` comercial de verdad —los de APKPure son de juegos
  ajenos de cientos de megas—; un `.apkm` de APKMirror, que se trata como un `.xapk` porque por
  dentro lo es, pero del que no hay ninguno a mano; y un `.aab` con módulos de Play Asset Delivery,
  que se instalan pero cuyos datos Play entregaría aparte.
- **Fuera a propósito**: sacar el `.apk` de una app ya instalada (`adb shell pm path` + `adb pull`).
  Es el «extra útil» del plan y no forma parte de instalar nada; pide su propio trozo de interfaz
  —elegir entre las apps del aparato— y se dejó sin hacer en vez de dejar los mandos escritos y sin
  llamar por nadie.

### Programas reales: la primera pasada

Los seis motores estaban probados contra juegos que generé con las herramientas del propio motor.
Eso comprueba el caso limpio; lo que sigue es lo que apareció al pasar programas de verdad,
descargados de las publicaciones de sus autores.

- **Godot 4 — funciona con una app real.** Pixelorama 1.2.1 (Godot 4.7.1), el editor de píxeles
  de Orama Interactive, repartido para Windows: se traslada, abre su ventana en tres segundos,
  arranca OpenGL sobre Metal en el M2 y pinta el editor entero. Sin tocar nada.
- **Godot 3 se reconoce y se dice, y ahora está comprobado con un juego real.** Pixelorama 0.11.4
  es Godot 3.5.2: el detector lo nombra y avisa de que no se traslada, que es lo que promete el
  documento. El motivo de que no se traslade sigue en pie, pero ya no es «no hay con qué probarlo».
- **Electron: dos fallos de verdad, los dos arreglados.**
  1. **El `package.json` de un módulo nativo no siempre está dentro del `.asar`.** Cuando
     `electron-builder` saca un módulo, saca su carpeta entera y a veces no deja copia dentro.
     Lever solo miraba en el `.asar`, así que los tres módulos de Mark Text salían **sin versión y
     sin repositorio**: sin eso no hay dirección que pedir y el traslado decía «sin binario de macOS
     publicado», que suena a que el módulo no lo publica cuando lo que pasaba es que ni se había
     mirado. Ahora se mira en los dos sitios.
  2. **Un módulo de N-API no publica con el ABI de Electron.** Publica **un solo** binario por
     plataforma, con `napi-v3` donde los demás ponen `electron-v146`; esa es justo la promesa de
     N-API. Lever solo armaba el nombre con el ABI, así que pedía un archivo que no existe. Ahora
     lee `binary.napi_versions` del módulo y prueba primero esos nombres. Medido con `keytar`
     7.9.0, que publica `keytar-v7.9.0-napi-v3-darwin-arm64.tar.gz` y ninguno con ABI.
  Con las dos cosas, el `keytar.node` del reparto de Mark Text sale del traslado como **Mach-O
  arm64** en vez de como la DLL de Windows que entraba.
- **Lo que sigue sin resolverse, y no es culpa de Lever**: `ced` y `native-keymap`, los otros dos
  módulos de Mark Text, no publican binario de macOS **en ninguna parte** —comprobado abriendo sus
  paquetes de npm: no traen ningún `.node`, se compilan al instalar—. Lever lo dice y no lo
  disimula. Esa app concreta, por tanto, se traslada pero no llega a abrir su ventana.
- **Lo que sigue sin comprobarse**: Ren'Py, LÖVE, NW.js y Java con programas reales. No es que
  fallen: es que no les he pasado ninguno todavía.

### Consolas: emulación y mapeo de mandos — primera entrega

Lever ya tenía tres formas de ejecutar algo ajeno —Wine, los motores nativos y Android—. La cuarta
son las consolas: una ROM no se ejecuta ni se instala, se **interpreta**.

- **La arquitectura, igual que con los motores**: Lever no reimplementa nada. RetroArch es a una
  ROM lo que Wine es a un `.exe`, y los núcleos de libretro son las piezas que le faltan,
  publicadas por el propio proyecto. Lever reconoce el archivo, consigue el núcleo, escribe la
  configuración y lanza.
- **Se reconoce por la cabecera, no por la extensión.** `.bin` y `.chd` los usan media docena de
  máquinas y un archivo renombrado se cuela. Casi todas las consolas marcan sus ROMs —el `NES` del
  principio, el logotipo que la Game Boy comprueba antes de arrancar, el `SEGA` de la Mega Drive,
  la suma y su complemento de la Super Nintendo—, así que se mira ahí y solo se cae en la extensión
  cuando la máquina no marca nada. La interfaz **dice cuál de las dos** ha sido.
- **Doce máquinas**, cubriendo las seis clases del plan: 8 bits (NES, Game Boy, Master System),
  16 (Super Nintendo, Mega Drive), 32 (Game Boy Advance, PlayStation), 64 (Nintendo 64), dos
  pantallas y táctil (DS, 3DS) e híbridas (Dreamcast, PSP).
- **Controles en tres niveles**: para todo, para una consola o para un juego, y gana el más
  concreto. La disposición de fábrica es la de siempre —cursores, Z y X, Enter— a propósito: es la
  que asumen todas las guías, y tener otra es una pelea que no vale la pena.
- **El diagrama del mando**: se pulsa el botón dibujado y luego la tecla o el botón de verdad. Cada
  etiqueta enseña **las dos** asignaciones, la del teclado y la del mando, porque las dos valen a la
  vez: RetroArch escribe una línea para cada una.

  El dibujo tiene la **forma del mando conectado**, no la de un esquema. El problema de asignar
  controles es espacial: nadie recuerda qué es «el botón B» de una consola que no ha tenido nunca,
  pero todo el mundo reconoce el botón de abajo del rombo en el mando que tiene en la mano. Por eso:

  - La silueta cambia con la familia. En un mando de Xbox la palanca izquierda está **donde un
    PlayStation tiene la cruceta**; dibujarlas iguales sería mandar a buscar un botón donde no está.
  - Los nombres son los que lleva serigrafiados: `○ ✕ △ □` en un DualSense y `B A Y X` en uno de
    Xbox —ojo, van por **posición** del RetroPad, no por letra—, y «Create» y «Options» en vez de
    «Select» y «Start», que en un DualSense no aparecen por ninguna parte.
  - Los botones que el mando tiene y **esta consola no usa** salen apagados y no se pueden pulsar.
    Sin ellos, una NES enseñaría dos botones sueltos flotando donde el usuario espera cuatro.
  - Cada etiqueta va a la altura de su botón y en su lado, unida por una línea. Las posiciones están
    en `Models/GamepadFaceplate.swift`, aparte de la vista, para poder comprobar sin abrir ninguna
    ventana que no hay dos controles en el mismo sitio.
- Probado de punta a punta con `nestest.nes`, la ROM de dominio público con la que se validan los
  emuladores de NES: desde la ventana de Lever, el panel dice «NES / Famicom · 8 bits · reconocido
  por su cabecera», el botón descarga el núcleo y **el juego arranca y dibuja**.
- **La partida**: dos casillas en el panel, y las dos comprobadas ejecutándolas.
  - *Abrir a pantalla completa*: el juego arranca ocupando la pantalla entera —medido, la ventana
    sale del tamaño del monitor— y dentro se cambia con la tecla F en los dos sentidos. Se hace con
    una ventana sin bordes y no cambiando la resolución del monitor: la otra forma deja el
    escritorio reordenado al salir y, si el emulador se cierra mal, el Mac se queda en la
    resolución del juego.
  - *Continuar donde lo dejaste*: al cerrar se guarda un estado automático y al abrir se retoma.
    Comprobado moviendo el cursor del menú de `nestest` cinco líneas, saliendo y volviendo a
    abrir: el cursor estaba donde se dejó. Aparte, la memoria de la pila se vuelca cada diez
    segundos, que es lo que salva a los juegos que guardaban solos de un cierre a lo bruto.

#### El mando físico

El número que RetroArch escribe en `input_playerN_<control>_btn` **no es una propiedad del botón**:
es la posición que ese botón ocupa en la lista que arma el emulador al reconocer el mando. Por eso
no se puede deducir del nombre que le dé el sistema. Lo que se hace es armar la misma lista con la
misma regla, traducida de `input/drivers_hid/iohidmanager_hid.c` de RetroArch 1.22.2, en
`Services/RetroPadNumbering.swift`. Tres pasos, y ninguno es evidente:

1. Los elementos HID se ordenan por página, uso y galleta **antes** de mirarlos.
2. Cada botón entra ordenado por su uso, no por el orden en que aparece.
3. Un uso repetido no pisa al primero: se va **al final**, detrás de todos.

Lo comprobado hasta ahora: la regla, contra las dos únicas tablas que no son de esta casa —la del
Nimbus, que la propia fuente de RetroArch documenta en un comentario, y la de un **DualSense de
verdad** leída de este Mac por IOKit (catorce botones, seis ejes y una cruceta, con las galletas de
las palancas desordenadas)—, y que la app instalada abre el diagrama y lo dibuja con los ocho
botones de la NES. **Lo que falta**: pulsar el botón físico con el diagrama escuchando, lanzar el
juego y ver que hace lo asignado. El mando de la casa se duerme y no volvió a aparecer en la
sesión; sin eso no se puede dar por bueno.
- **Y tampoco está jugada ninguna otra máquina**: de las doce, solo la NES se ha llegado a jugar.
  El reconocimiento de las once restantes sí está cubierto con cabeceras reales en las pruebas,
  pero una cosa es reconocer la ROM y otra que ese núcleo arranque en este Mac.

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

## 3. Lo que viene

### Nada pendiente

El apartado 3.1 —Android— era el último de la lista y está hecho. Lo que queda escrito como no
comprobado está en cada motor, en su párrafo de «lo que sigue sin comprobarse».

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
- **RetroArch se cuelga si toca `~/Documents`.** Guarda ahí sus listas y su historial, y esa
  carpeta la protege macOS: lanzado desde otra app el permiso no se puede pedir y la lectura se
  queda esperando **para siempre**. El síntoma es una ventana que no llega a abrirse y un registro
  que se corta en «Loading history file», sin ningún error. Se le dan sus carpetas dentro de las de
  Lever y no las toca.
- **El núcleo tiene que ser de la arquitectura de RetroArch, no la del Mac.** El cask de Homebrew
  instala el de Intel, así que en un Mac con chip Apple hay que bajarle núcleos de Intel; el de ARM
  lo rechaza con «incompatible architecture» al cargarlo, no antes.
- **`menu_driver = ozone` deja la ventana en negro** si RetroArch no tiene su paquete de recursos
  gráficos, que la versión de Homebrew no trae. No hay error en ninguna parte. `rgui` va dibujado
  dentro del programa y siempre funciona.
- **RetroArch reescribe el archivo de configuración, y `config_save_on_exit = false` no lo evita.**
  Las noventa líneas que escribe Lever vuelven convertidas en tres mil trescientas con todo lo suyo
  dentro, y pasa **mientras corre**, no al salir. Lo que lo deja sin efecto es que Lever reescribe el
  archivo entero antes de cada lanzamiento: el juego siempre arranca con lo que Lever pidió. Sirve
  para leer los valores de fábrica de RetroArch —el archivo hinchado los trae todos— pero no para
  fiarse de lo que hay ahí escrito.
- **Una configuración pasada con `-c` que no nombre los atajos deja a RetroArch sin ninguno.** No
  hereda los suyos de fábrica: los que la configuración no declare, no existen. El síntoma es que
  la tecla F no pone el juego a pantalla completa, y no hay ningún error. Lever declara tres —`f`
  para pantalla completa, `f1` para el menú y `escape` para salir— y deja fuera el resto a
  propósito, porque varios caen en letras que la disposición de fábrica usa para jugar: la `h`
  **reinicia la partida** y la `r` rebobina. No declararlos es lo que impide dispararlos sin querer.
- **Salir con Escape pide confirmación**: `quit_press_twice` viene puesto y hay que pulsarla dos
  veces. Importa porque el cierre limpio es el que guarda la partida; matar la ventana no guarda.
- RetroArch **pausa el juego cuando su ventana no tiene el foco**, y un emulador lanzado desde otra
  app no lo tiene: se abre parado, con el icono de pausa y sin nada que lo explique.
- **`strings` esconde los nombres de tres letras.** Por omisión solo saca cadenas de cuatro o más,
  así que buscar `hid` o `mfi` en el binario de RetroArch no encuentra nada y parece que esos
  drivers no están. Hace falta `strings -n 3`. Con la respuesta equivocada se diseña el mapeo
  entero contra el driver que no es.
- **RetroArch de Homebrew no trae el driver `mfi`.** En un Mac usa `hid` sobre `iohidmanager`, es
  decir, HID en crudo. Lo dice su propio registro: «Found HID driver: "iohidmanager"», «Found joypad
  driver: "hid"». Importa porque `mfi` numera los botones como el RetroPad y `hid` los numera por
  posición en la lista de elementos: **son numeraciones distintas para el mismo botón**.
- **El número de un botón solo significa algo dentro de su driver.** Por eso la configuración fija
  `input_joypad_driver`: sin esa línea, un cambio de driver movería todos los botones de sitio sin
  dar ningún error. Y si algún día no existiera, RetroArch coge el primero que arranque en vez de
  quedarse sin mando, así que fijarlo no puede dejar a nadie tirado.
- **`GameController` no ve el mando.** Con un DualSense emparejado por Bluetooth en este Mac
  devuelve **cero mandos**: ni desde un ejecutable suelto, ni desde una app con su ventana delante y
  activa. IOKit lo ve sin dudar. Además `GameController` no enseña galletas ni usos HID, que es de
  donde sale el número. Se usa IOKit para las dos cosas, que además es lo que ve RetroArch: enseñar
  una lista de mandos que no es la suya sería mentir. Lo que se pierde es el porcentaje de batería,
  que IOKit no publica para este mando.
- **Un gatillo en reposo no vale cero: vale el extremo.** Un umbral que mire solo el valor da por
  pulsado un gatillo que nadie ha tocado, y la primera casilla que se intente asignar se lleva ese
  gatillo sola. Hay que guardar cómo estaba cada eje al empezar a escuchar y mirar el movimiento.
- **RetroArch solo lee los treinta y dos primeros botones** (`joykey < 32`). El treinta y tres se
  guarda sin error y no hace nada nunca.
- **Una asignación explícita gana a la autoconfiguración de RetroArch, y `nul` se la deja puesta.**
  Está en `input_driver.c`: `bind_joykey != NO_BTN ? bind_joykey : autobind_joykey`. Es justo lo que
  se quiere —solo se pisa lo que el usuario ha tocado— pero conviene saberlo: escribir `nul` no
  desactiva un botón, lo devuelve a lo que RetroArch decida.
- **El DualSense no está en la tabla de mandos conocidos de RetroArch 1.22.2** (sí el DualShock 3 y
  el 4). Por eso va por el camino genérico de elementos HID, que es el que Lever replica. Si algún
  día lo añaden, RetroArch pasará a leerlo por informe y **la numeración cambiará**.
- **El `package.json` de un módulo de Electron puede estar fuera del `.asar`.** Si solo se mira
  dentro, un módulo desempaquetado se queda sin versión y sin repositorio, y el traslado acaba
  diciendo «no publica binario de macOS» sobre un módulo que ni se ha llegado a identificar. Un
  mensaje que culpa al módulo esconde un fallo propio.
- **N-API cambia el nombre del archivo que hay que pedir**: `napi-v3` en vez de `electron-v146`, y
  un solo binario para todas las versiones de Electron. Está en `binary.napi_versions` del módulo.
- `open` no siempre lanza un `.app` recién montado en una carpeta temporal, y no dice por qué. Para
  comprobar que una app trasladada abre, ejecutar su binario directamente.
- **`compression_stream_init` deja el flujo a cero**: si los punteros de entrada y salida se ponen
  en el constructor, `init` los borra, y con `dst_size` en cero la librería no descomprime nada
  mientras «lo escrito» —`chunkSize - dst_size`— sale el búfer entero. El archivo salía con un mega
  de basura sin que fallara nada. Los punteros van **después** de `init`.
- `bundletool` repite cada trozo una vez por variante de Android y les pone `_2`, `_3` para que no
  choquen los nombres. Ese sufijo no dice nada del trozo: sin quitarlo, `base-arm64_v8a_2.apk` no
  coincide con ningún procesador y pasa por un módulo aparte. Y entre los `…-master.apk` hay que
  leer **el que no lleva sufijo**: es el de la variante del Android más antiguo, así que es el que
  dice el mínimo de verdad. Leerlo de la `_3` diría que la app pide Android 12 cuando se instala
  desde el 7.
- **`--local-testing` de `bundletool` no se usa.** Sirve para las apps que reparten datos por Play
  Asset Delivery y necesita `run-as`, que solo funciona si la app es depurable. Con una app normal
  la instalación sale bien pero escupe un error rojo —«package not debuggable»— que parece que ha
  fallado todo.
- El nombre del archivo de las build-tools cambió de guion a subrayado en la r35:
  `build-tools_r34-macosx.zip` pero `build-tools_r35_macosx.zip`. La forma vieja da un 404.
- `/usr/bin/java` **no** sirve para saber si hay Java: en macOS ese archivo está siempre y, sin
  ninguna máquina virtual instalada, lo único que hace es abrir una ventana diciendo que no la hay.
- El `bash` que trae macOS es el 3.2 y no entiende `;;&` en un `case`. Un guion que lo use falla con
  «syntax error near unexpected token &» solo al llegar ahí, después de haber hecho todo el trabajo.
- `adb install` deja una línea en blanco al final: `tail -1` de su salida devuelve vacío y un guion
  que compruebe ahí el motivo del fallo no encuentra nada.
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
