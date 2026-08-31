import Foundation
import LeverCore

/// Pruebas del reconocimiento de juegos de Electron y del molde del bundle.
///
/// Lo delicado aquí son tres cosas: leer el `.asar`, que no es un ZIP y no se parece a nada más
/// del proyecto; sacar la versión del motor de donde no miente; y renombrar los ayudantes
/// anidados, que es de lo que depende que la ventana dibuje algo en vez de quedarse en negro.
enum ElectronTests {
    static func run() throws {
        try namesEveryDownloadCorrectly()
        try readsAnAsarArchive()
        try recognisesAPackagedGame()
        try trustsTheVersionFileOverTheExecutable()
        try findsNativeModulesAndTheirVersions()
        try readsTheManifestOfAModuleTakenOutOfTheAsar()
        try readsTheRepositoryFieldInAnyOfItsForms()
        try namesTheNodePrebuild()
        try resolvesTheNodeAbiFromTheRegistry()
        try renamesTheNestedHelpers()
        try infoPlistKeepsWhatChromiumNeeds()
    }

    // MARK: - Versiones

    static func namesEveryDownloadCorrectly() throws {
        let v = ElectronVersion(major: 44, minor: 0, patch: 0)
        try expect(ElectronVersion("44.0.0") == v, "un número suelto se lee")
        try expect(ElectronVersion("v44.0.0") == nil, "con la v delante no: eso es la etiqueta, no el número")
        try expect(ElectronVersion("no soy una versión") == nil, "y una cadena cualquiera tampoco")
        try expect(v.releaseTag == "v44.0.0", "la publicación sí lleva v")
        try expect(v.macAssetName(appleSilicon: true) == "electron-v44.0.0-darwin-arm64.zip",
                   "nombre del archivo de ARM: \(v.macAssetName(appleSilicon: true))")
        try expect(v.macDownloadURL(appleSilicon: false).absoluteString
                    == "https://github.com/electron/electron/releases/download/v44.0.0/electron-v44.0.0-darwin-x64.zip",
                   "la dirección: \(v.macDownloadURL(appleSilicon: false))")

        // Comprobado contra las publicaciones de Electron: la 10.4.7 solo tiene darwin-x64 y la
        // 11.0.0 ya trae las dos. Pedir un arm64 anterior da un 404.
        let vieja = ElectronVersion(major: 10, minor: 4, patch: 7)
        try expect(vieja.macAssetName(appleSilicon: true) == "electron-v10.4.7-darwin-x64.zip",
                   "antes de la 11 no hay archivo de arm64")
        try expect(vieja.needsRosetta(appleSilicon: true), "así que esa app irá traducida")
        try expect(!ElectronVersion(major: 11, minor: 0, patch: 0).needsRosetta(appleSilicon: true),
                   "de la 11 en adelante, nativa")
        try expect(!vieja.needsRosetta(appleSilicon: false), "en un Mac de Intel no hay Rosetta que valga")
    }

    // MARK: - El formato .asar

    /// El molde se comprobó contra un `.asar` hecho por `@electron/packager`; aquí se arma a mano
    /// para poder fijar los casos raros —carpetas anidadas y archivos desempaquetados— sin
    /// depender de que haya npm en la máquina que corra las pruebas.
    static func readsAnAsarArchive() throws {
        let fixture = try TemporaryFixture()
        let asar = fixture.directoryURL.appendingPathComponent("app.asar")
        try makeAsar(at: asar, files: [
            "package.json": Data(#"{"name":"x","productName":"El Faro Rojo","version":"2.0"}"#.utf8),
            "js/juego.js": Data("console.log(1)".utf8)
        ], unpacked: ["node_modules/mod/build/Release/mod.node"])

        guard let entradas = AsarArchive.entries(of: asar) else {
            throw TestFailure(description: "no se leyó el asar")
        }
        try expect(entradas.map(\.path) == ["js/juego.js", "node_modules/mod/build/Release/mod.node",
                                            "package.json"],
                   "las carpetas se recorren enteras: \(entradas.map(\.path))")
        try expect(entradas.first { $0.path.hasSuffix(".node") }?.unpacked == true,
                   "un .node va marcado como desempaquetado: dlopen no lee de dentro de un asar")

        guard let datos = AsarArchive.read("package.json", from: asar),
              let texto = String(data: datos, encoding: .utf8) else {
            throw TestFailure(description: "no se pudo sacar el package.json")
        }
        try expect(texto.contains("El Faro Rojo"), "y el contenido sale entero: \(texto)")
        try expect(AsarArchive.read("node_modules/mod/build/Release/mod.node", from: asar) == nil,
                   "lo desempaquetado no está dentro, así que no se puede leer de aquí")
        try expect(AsarArchive.entries(of: fixture.directoryURL.appendingPathComponent("no-existe")) == nil,
                   "lo que no es un asar no se afirma que lo sea")
    }

    // MARK: - Reconocimiento

    static func recognisesAPackagedGame() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "44.0.0")
        guard case .electron(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció el reparto de Electron")
        }
        try expect(game.version == "44.0.0", "la versión del motor: \(game.version)")
        try expect(game.versionOrigin == .versionFile, "de donde no miente")
        try expect(game.suggestedAppName == "El Faro Rojo",
                   "el nombre sale del productName, no del .exe: \(game.suggestedAppName)")
        // El `default_app.asar` es la bienvenida del motor y no pinta nada en un juego.
        try expect(!game.resourceEntries.contains("default_app.asar"), "la app de bienvenida no viaja")
        try expect(game.resourceEntries.contains("app.asar"), "el juego sí")

        // Sin app.asar no es un reparto de Electron, por muchos .dll de Chromium que haya al lado.
        let sinAsar = try TemporaryFixture()
        let otro = try makeGame(in: sinAsar, version: "44.0.0")
        try FileManager.default.removeItem(
            at: otro.deletingLastPathComponent().appendingPathComponent("resources/app.asar"))
        try expect(PortableEngineDetector.detect(program: otro) == nil, "sin app.asar no se afirma nada")
    }

    /// `electron-packager` renombra el ejecutable y de paso le reescribe el recurso de versión con
    /// la del **juego**: un reparto de Electron 44 declara ahí «1.0.0.0». Por eso la versión sale
    /// del archivo `version`, y el respaldo es la cadena de dentro del binario, no ese recurso.
    static func trustsTheVersionFileOverTheExecutable() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "44.0.0")
        let raiz = exe.deletingLastPathComponent()

        try FileManager.default.removeItem(at: raiz.appendingPathComponent("version"))
        guard let (version, origen) = ElectronInspector.engineVersion(in: raiz, executable: exe) else {
            throw TestFailure(description: "sin el archivo version debería quedar el respaldo")
        }
        try expect(version == ElectronVersion(major: 44, minor: 0, patch: 0),
                   "la cadena de dentro del binario también lo dice: \(version)")
        try expect(origen == .embeddedString, "y se sabe que fue por ahí")
    }

    static func findsNativeModulesAndTheirVersions() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "44.0.0", conModuloNativo: true)
        guard case .electron(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.nativeModules.map(\.label) == ["better-sqlite3 12.2.0"],
                   "el nombre sale de la ruta y la versión del package.json de dentro del asar: "
                   + "\(game.nativeModules.map(\.label))")
        try expect(game.nativeModules.first?.repository == "WiseLibs/better-sqlite3",
                   "y el repositorio, que es donde estarán los prebuilds")
        // Antes de empezar no se sabe si hay binario publicado para esta combinación: averiguarlo
        // pide red. Prometer aquí que va a faltar sería mentir la mitad de las veces.
        guard case .electron = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "debería seguir siendo de Electron")
        }
        try expect(PortableEngineDetector.detect(program: exe)?.unresolvedParts == [],
                   "el panel no promete que falten: lo dice el traslado cuando ya lo sabe")

        // Un paquete con ámbito ocupa dos segmentos de ruta, no uno.
        try expect(ElectronInspector.moduleName(inPath: "node_modules/@scope/cosa/build/x.node")
                    == "@scope/cosa", "paquete con ámbito")
        try expect(ElectronInspector.moduleName(inPath: "node_modules/a/node_modules/b/x.node") == "b",
                   "manda el último node_modules: un módulo anidado es suyo, no del de fuera")
        try expect(ElectronInspector.moduleName(inPath: "build/Release/suelto.node") == nil,
                   "sin node_modules no se puede decir de quién es")
    }

    /// El campo `repository` de npm admite media docena de formas y de él depende saber dónde
    /// están los prebuilds. Si no se saca, no hay de dónde bajar nada.
    static func readsTheRepositoryFieldInAnyOfItsForms() throws {
        let casos: [(Any, String?)] = [
            ("WiseLibs/better-sqlite3", "WiseLibs/better-sqlite3"),
            ("github:WiseLibs/better-sqlite3", "WiseLibs/better-sqlite3"),
            (["url": "git://github.com/WiseLibs/better-sqlite3.git"], "WiseLibs/better-sqlite3"),
            (["type": "git", "url": "git+https://github.com/WiseLibs/better-sqlite3.git"],
             "WiseLibs/better-sqlite3"),
            // Un repositorio fuera de GitHub no da ninguna dirección de prebuild que pedir.
            (["url": "https://gitlab.com/otro/cosa.git"], nil),
            ("sinbarra", nil)
        ]
        for (valor, esperado) in casos {
            let salida = ElectronInspector.repository(in: ["repository": valor])
            try expect(salida == esperado, "de \(valor) salía \(salida ?? "nil"), se esperaba \(esperado ?? "nil")")
        }
        try expect(ElectronInspector.repository(in: ["name": "x"]) == nil, "sin repository, nada")
    }

    /// Un módulo que `electron-builder` sacó del `.asar` se lleva su `package.json` con él, y a
    /// veces no deja copia dentro. Mirando solo en el `.asar`, ese módulo se queda sin versión y
    /// sin repositorio: no hay dirección que pedir, y el traslado acaba diciendo «sin binario de
    /// macOS publicado» cuando lo que ha pasado es que ni se ha mirado.
    ///
    /// Medido con Mark Text 0.19.1: sus tres módulos salían sin identificar, y uno de ellos
    /// —keytar 7.9.0— sí publica su binario de macOS.
    static func readsTheManifestOfAModuleTakenOutOfTheAsar() throws {
        let fixture = try TemporaryFixture()
        let resources = fixture.directoryURL.appendingPathComponent("resources", isDirectory: true)
        let suelto = resources.appendingPathComponent("app.asar.unpacked/node_modules/keytar", isDirectory: true)
        try FileManager.default.createDirectory(
            at: suelto.appendingPathComponent("build/Release", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("PE".utf8).write(to: suelto.appendingPathComponent("build/Release/keytar.node"))
        try Data("""
            {"name": "keytar", "version": "7.9.0",
             "repository": {"type": "git", "url": "https://github.com/atom/node-keytar.git"},
             "binary": {"napi_versions": [3]}}
            """.utf8).write(to: suelto.appendingPathComponent("package.json"))

        // El `.asar` no sabe nada de ese módulo: es justo el caso.
        let asar = resources.appendingPathComponent("app.asar")
        try makeAsar(at: asar, files: ["package.json": Data(#"{"productName":"Prueba"}"#.utf8)], unpacked: [])

        let modulos = ElectronInspector.nativeModules(in: resources, asar: asar)
        try expect(modulos.count == 1, "un módulo: \(modulos.count)")
        guard let keytar = modulos.first else { return }
        try expect(keytar.name == "keytar", "el nombre sale de la ruta")
        try expect(keytar.version == "7.9.0",
                   "la versión sale de su package.json de fuera del asar: \(keytar.version ?? "nada")")
        try expect(keytar.repository == "atom/node-keytar", "y el repositorio también")
        try expect(keytar.napiVersions == [3], "y las versiones de N-API: \(keytar.napiVersions)")
        try expect(!keytar.prebuildURLs(abi: 146, appleSilicon: true).isEmpty,
                   "con eso ya hay una dirección que pedir, que era lo que faltaba")
    }

    /// La convención de `prebuild-install`, que es la que usan los módulos al publicar:
    /// `<módulo>-v<versión>-<runtime>-v<abi>-<plataforma>-<arquitectura>.tar.gz`, bajo la etiqueta
    /// `v<versión>` de sus publicaciones.
    static func namesTheNodePrebuild() throws {
        let modulo = NodeNativeModule(name: "better-sqlite3", version: "12.11.1",
                                      relativePath: "app.asar.unpacked/node_modules/better-sqlite3/x.node",
                                      repository: "WiseLibs/better-sqlite3")
        try expect(modulo.prebuildAssetNames(abi: 146, appleSilicon: true)
                    == ["better-sqlite3-v12.11.1-electron-v146-darwin-arm64.tar.gz"],
                   "el archivo: \(modulo.prebuildAssetNames(abi: 146, appleSilicon: true))")
        try expect(modulo.prebuildURLs(abi: 146, appleSilicon: true).first?.absoluteString
                    == "https://github.com/WiseLibs/better-sqlite3/releases/download/v12.11.1/"
                     + "better-sqlite3-v12.11.1-electron-v146-darwin-arm64.tar.gz",
                   "la dirección: \(modulo.prebuildURLs(abi: 146, appleSilicon: true))")

        // Un módulo de N-API no publica con el ABI de Electron: publica **un solo** binario por
        // plataforma, con `napi-v<n>`, porque esa es la promesa de N-API. Pedirle el nombre con el
        // ABI da un 404 y parece que no hay binario de macOS. Medido con keytar 7.9.0, que publica
        // `keytar-v7.9.0-napi-v3-darwin-arm64.tar.gz` y ninguno con ABI.
        let napi = NodeNativeModule(name: "keytar", version: "7.9.0", relativePath: "keytar.node",
                                    repository: "atom/node-keytar", napiVersions: [3])
        let nombres = napi.prebuildAssetNames(abi: 146, appleSilicon: true)
        try expect(nombres.first == "keytar-v7.9.0-napi-v3-darwin-arm64.tar.gz",
                   "el de N-API va primero: \(nombres)")
        try expect(nombres.count == 2 && nombres[1].contains("electron-v146"),
                   "y detrás se sigue probando el del ABI, por si acaso: \(nombres)")
        try expect(napi.prebuildURLs(abi: 146, appleSilicon: true).first?.absoluteString
                    == "https://github.com/atom/node-keytar/releases/download/v7.9.0/"
                     + "keytar-v7.9.0-napi-v3-darwin-arm64.tar.gz",
                   "la dirección de N-API: \(napi.prebuildURLs(abi: 146, appleSilicon: true))")

        // Si declara varias, la más alta primero: es la que se compiló con lo más nuevo.
        let varias = NodeNativeModule(name: "m", version: "1.0.0", relativePath: "m.node",
                                      repository: "a/b", napiVersions: [3, 8, 6])
        try expect(varias.prebuildAssetNames(abi: 146, appleSilicon: true).first?.contains("napi-v8") == true,
                   "la más alta primero: \(varias.prebuildAssetNames(abi: 146, appleSilicon: true))")

        // Y la caché las distingue: un binario de N-API no está atado a ningún ABI, así que
        // guardarlo bajo uno haría que el siguiente Electron se lo volviera a bajar.
        let comoNapi = NativePart(name: "keytar", version: "7.9.0", platform: "macos-arm64",
                                  abi: nil, download: nil, fileName: "x", runtime: "napi3")
        let comoAbi = NativePart(name: "keytar", version: "7.9.0", platform: "macos-arm64",
                                 abi: 146, download: nil, fileName: "x")
        try expect(comoNapi.cacheKey != comoAbi.cacheKey, "no comparten sitio en la caché")
        try expect(comoNapi.cacheKey.hasSuffix("napi3"), "la de N-API se guarda por su N-API: \(comoNapi.cacheKey)")

        // Sin repositorio no hay dónde mirar, y sin versión no hay etiqueta que pedir.
        let sinRepo = NodeNativeModule(name: "x", version: "1.0.0", relativePath: "x.node", repository: nil)
        try expect(sinRepo.prebuildURLs(abi: 146, appleSilicon: true).isEmpty, "sin repositorio, ninguna")
        let sinVersion = NodeNativeModule(name: "x", version: nil, relativePath: "x.node", repository: "a/b")
        try expect(sinVersion.prebuildURLs(abi: 146, appleSilicon: true).isEmpty, "sin versión, tampoco")

        // Y el campo se lee del `package.json` del módulo, que es de donde sale.
        try expect(ElectronInspector.napiVersions(in: ["binary": ["napi_versions": [3]]]) == [3],
                   "se lee binary.napi_versions")
        try expect(ElectronInspector.napiVersions(in: ["version": "1"]).isEmpty,
                   "un módulo que no lo declara no tiene ninguna")

        // La identidad de una parte lleva el ABI dentro: confundir un binario de un ABI con el de
        // otro no da error al montar, solo al arrancar, que es lo peor que puede pasar.
        let a = NativePart(name: "m", version: "1", platform: "macos-arm64", abi: 146,
                           download: nil, fileName: "a")
        let b = NativePart(name: "m", version: "1", platform: "macos-arm64", abi: 148,
                           download: nil, fileName: "a")
        try expect(a.cacheKey != b.cacheKey, "dos ABIs no pueden compartir carpeta en la caché")
        let sinAbi = NativePart(name: "m", version: "1", platform: "macos-arm64", abi: nil,
                                download: nil, fileName: "a")
        try expect(sinAbi.cacheKey == "m-1-macos-arm64", "sin ABI la clave son tres señas: \(sinAbi.cacheKey)")
    }

    /// El ABI depende solo del número mayor de Electron. El registro guarda una fila por mayor,
    /// etiquetada con su primera alfa.
    static func resolvesTheNodeAbiFromTheRegistry() throws {
        let registro = Data("""
        [{"runtime":"node","target":"24.0.0","abi":"137","lts":false,"future":false},
         {"runtime":"electron","target":"42.0.0-alpha.1","abi":"146","lts":false,"future":false},
         {"runtime":"electron","target":"43.0.0-alpha.1","abi":"148","lts":false,"future":false}]
        """.utf8)
        try expect(NodeAbi.forElectron(major: 42, registry: registro) == 146, "Electron 42 usa el ABI 146")
        try expect(NodeAbi.forElectron(major: 43, registry: registro) == 148, "y la 43 el 148")
        // Una versión que el registro no conoce no se adivina: sin ABI no se baja nada.
        try expect(NodeAbi.forElectron(major: 99, registry: registro) == nil, "de una que no está, nada")
        try expect(NodeAbi.forElectron(major: 42, registry: Data("no soy json".utf8)) == nil,
                   "y un registro roto no debería reventar nada")
    }

    // MARK: - Montaje

    /// En Chromium los procesos que dibujan son los ayudantes, y el principal los busca por un
    /// nombre derivado del suyo. `electron-packager` los renombra; si no se hace, la ventana abre
    /// y se queda en negro.
    static func renamesTheNestedHelpers() throws {
        try expect(ElectronPorter.renamedHelper("Electron Helper", to: "El Faro Rojo") == "El Faro Rojo Helper",
                   "el ayudante principal")
        try expect(ElectronPorter.renamedHelper("Electron Helper (GPU)", to: "El Faro Rojo")
                    == "El Faro Rojo Helper (GPU)", "y el resto conserva lo que los distingue")
        try expect(ElectronPorter.renamedHelper("Mantle.framework", to: "El Faro Rojo") == nil,
                   "lo que no empieza por Electron no se toca")

        guard let datos = ElectronPorter.helperPlist(
            from: plistDeAyudante, helperName: "El Faro Rojo Helper (GPU)",
            appIdentifier: "com.lever.electron.El-Faro-Rojo"),
              let plist = (try? PropertyListSerialization.propertyList(from: datos, format: nil))
                as? [String: Any] else {
            throw TestFailure(description: "no se pudo reescribir la ficha del ayudante")
        }
        try expect(plist["CFBundleExecutable"] as? String == "El Faro Rojo Helper (GPU)",
                   "el motor no trae CFBundleExecutable en sus ayudantes: hay que ponerlo")
        try expect(plist["CFBundleIdentifier"] as? String == "com.lever.electron.El-Faro-Rojo.helper",
                   "y el identificador cuelga del de la app: \(plist["CFBundleIdentifier"] ?? "")")
    }

    static func infoPlistKeepsWhatChromiumNeeds() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "44.0.0")
        guard case .electron(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        guard let datos = ElectronPorter.infoPlist(from: plistDeElectron, game: game,
                                                   displayName: "El Faro Rojo", hasCustomIcon: false),
              let plist = (try? PropertyListSerialization.propertyList(from: datos, format: nil))
                as? [String: Any] else {
            throw TestFailure(description: "no se pudo reescribir el Info.plist")
        }
        try expect(plist["CFBundleExecutable"] as? String == "El Faro Rojo", "el ejecutable renombrado")
        try expect(plist["CFBundleIdentifier"] as? String == "com.lever.electron.El-Faro-Rojo",
                   "identificador propio: \(plist["CFBundleIdentifier"] ?? "")")
        // En un .app de Chromium la clase principal no es NSApplication: quitarla deja la app sin
        // nada que arrancar.
        try expect(plist["NSPrincipalClass"] as? String == "AtomApplication",
                   "NSPrincipalClass se queda como estaba")
        try expect(plist["LSMinimumSystemVersion"] as? String == "13.0",
                   "lo que no se toca se conserva: se parte del plist del motor")
    }

    // MARK: - Utilidades

    private static let plistDeElectron = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Electron</string>
        <key>CFBundleIdentifier</key><string>com.github.Electron</string>
        <key>CFBundleName</key><string>Electron</string>
        <key>CFBundleIconFile</key><string>electron.icns</string>
        <key>NSPrincipalClass</key><string>AtomApplication</string>
        <key>LSMinimumSystemVersion</key><string>13.0</string>
    </dict></plist>
    """.utf8)

    private static let plistDeAyudante = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.github.Electron.helper</string>
        <key>CFBundleName</key><string>Electron Helper (GPU)</string>
    </dict></plist>
    """.utf8)

    /// Arma una carpeta como la que produce `electron-packager` para Windows.
    @discardableResult
    private static func makeGame(
        in fixture: TemporaryFixture,
        version: String,
        conModuloNativo: Bool = false
    ) throws -> URL {
        let manager = FileManager.default
        let root = fixture.directoryURL.appendingPathComponent("juego-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)

        var dentro: [String: Data] = [
            "package.json": Data(#"{"name":"faro","productName":"El Faro Rojo","main":"main.js"}"#.utf8),
            "main.js": Data("require('electron')".utf8)
        ]
        var desempaquetados: [String] = []
        if conModuloNativo {
            dentro["node_modules/better-sqlite3/package.json"] = Data(#"""
                {"name":"better-sqlite3","version":"12.2.0",
                 "repository":{"type":"git","url":"git://github.com/WiseLibs/better-sqlite3.git"}}
                """#.utf8)
            desempaquetados.append("node_modules/better-sqlite3/build/Release/better_sqlite3.node")
            let suelto = resources
                .appendingPathComponent("app.asar.unpacked/node_modules/better-sqlite3/build/Release",
                                        isDirectory: true)
            try manager.createDirectory(at: suelto, withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: suelto.appendingPathComponent("better_sqlite3.node"))
        }
        try makeAsar(at: resources.appendingPathComponent("app.asar"), files: dentro,
                     unpacked: desempaquetados)

        // La bienvenida del propio motor, que sobra en cuanto hay juego.
        try Data("bienvenida".utf8).write(to: resources.appendingPathComponent("default_app.asar"))
        try Data((version + "\n").utf8).write(to: root.appendingPathComponent("version"))
        for nombre in ["ffmpeg.dll", "icudtl.dat", "resources.pak", "snapshot_blob.bin"] {
            try Data("motor".utf8).write(to: root.appendingPathComponent(nombre))
        }

        // El ejecutable, con la cadena que deja Chromium dentro y con el recurso de versión ya
        // reescrito por el empaquetador: dice 1.0.0, que es la del juego y no la del motor.
        let exe = root.appendingPathComponent("El Faro Rojo.exe")
        var datos = WindowsBinary(productVersion: (1, 0, 0, 0)).data
        datos += Data("Mozilla/5.0 Chrome/152.0.7977.54 Electron/\(version) Safari/537.36\0".utf8)
        try datos.write(to: exe)
        return exe
    }

    /// Un `.asar` mínimo: cuatro enteros, el JSON del árbol y detrás los contenidos pegados.
    private static func makeAsar(at destination: URL, files: [String: Data], unpacked: [String]) throws {
        var arbol: [String: Any] = [:]
        var datos = Data()

        func mete(_ ruta: String, _ hoja: [String: Any]) {
            let partes = ruta.split(separator: "/").map(String.init)
            func dentro(_ nodo: [String: Any], _ resto: ArraySlice<String>) -> [String: Any] {
                guard let cabeza = resto.first else { return nodo }
                var copia = nodo
                if resto.count == 1 {
                    copia[cabeza] = hoja
                } else {
                    let hijo = (copia[cabeza] as? [String: Any])?["files"] as? [String: Any] ?? [:]
                    copia[cabeza] = ["files": dentro(hijo, resto.dropFirst())]
                }
                return copia
            }
            arbol = dentro(arbol, partes[...])
        }

        for (ruta, contenido) in files.sorted(by: { $0.key < $1.key }) {
            mete(ruta, ["size": contenido.count, "offset": String(datos.count)])
            datos += contenido
        }
        for ruta in unpacked { mete(ruta, ["size": 0, "offset": "0", "unpacked": true]) }

        let json = try JSONSerialization.data(withJSONObject: ["files": arbol])
        // El JSON se rellena hasta múltiplo de cuatro; los dos enteros de en medio son de la
        // serialización de Chromium y se calculan a partir de ese tamaño ya rellenado.
        let relleno = (4 - json.count % 4) % 4
        let rellenado = json.count + relleno
        var salida = Data()
        for valor in [4, rellenado + 8, rellenado + 4, json.count] {
            var v = UInt32(valor).littleEndian
            salida += Data(bytes: &v, count: 4)
        }
        salida += json + Data(count: relleno) + datos
        try salida.write(to: destination)
    }
}
