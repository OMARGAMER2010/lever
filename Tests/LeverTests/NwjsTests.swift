import Foundation
import LeverCore

/// Pruebas del reconocimiento de juegos hechos con NW.js.
///
/// Lo delicado aquí es separar el juego del motor: los repartos no se parecen entre sí —RPG Maker
/// MV mete todo en `www/` y MZ lo deja suelto en la raíz—, así que la separación se hace por
/// descarte, y esa lista de descarte es lo que hay que fijar.
enum NwjsTests {
    static func run() throws {
        try namesEveryDownloadCorrectly()
        try knowsWhichVersionsDrawSomething()
        try readsTheManifest()
        try needsBothTheEngineAndTheManifest()
        try separatesTheGameFromTheEngine()
        try recognisesAnRpgMakerMvLayout()
        try noticesModulesBuiltOnlyForWindows()
        try namesTheAppAfterTheWindowTitle()
        try infoPlistStopsActingLikeABrowser()
    }

    // MARK: - Versiones

    static func namesEveryDownloadCorrectly() throws {
        let mz = NwjsVersion(major: 0, minor: 48, patch: 4)
        try expect(mz.releaseTag == "v0.48.4", "NW.js publica cada versión con la v delante")
        try expect(mz.macAssetName(appleSilicon: false) == "nwjs-v0.48.4-osx-x64.zip",
                   "nombre del archivo de Intel: \(mz.macAssetName(appleSilicon: false))")
        try expect(mz.macDownloadURL(appleSilicon: false).absoluteString
                    == "https://dl.nwjs.io/v0.48.4/nwjs-v0.48.4-osx-x64.zip",
                   "la dirección no cuadra: \(mz.macDownloadURL(appleSilicon: false))")

        // Los binarios de Apple silicon llegaron en la 0.77.0. Pedirlos antes da un 404, así que
        // una versión anterior tiene que seguir bajando los de Intel aunque el Mac sea de ARM.
        try expect(mz.macAssetName(appleSilicon: true) == "nwjs-v0.48.4-osx-x64.zip",
                   "antes de la 0.77 no hay archivo de arm64")
        let nueva = NwjsVersion(major: 0, minor: 77, patch: 0)
        try expect(nueva.macAssetName(appleSilicon: true) == "nwjs-v0.77.0-osx-arm64.zip",
                   "desde la 0.77 sí lo hay: \(nueva.macAssetName(appleSilicon: true))")
        try expect(nueva.macAssetName(appleSilicon: false) == "nwjs-v0.77.0-osx-x64.zip",
                   "en un Mac de Intel se sigue bajando el de Intel")

        try expect(mz.needsRosetta(appleSilicon: true), "la 0.48 va traducida en Apple silicon")
        try expect(!nueva.needsRosetta(appleSilicon: true), "la 0.77 es nativa")
        try expect(!mz.needsRosetta(appleSilicon: false), "en un Mac de Intel no hay Rosetta que valga")
    }

    /// El corte no es de gusto: por debajo de la 0.48 el proceso que dibuja muere antes de cargar
    /// la página y la ventana se queda en negro.
    static func knowsWhichVersionsDrawSomething() throws {
        try expect(!NwjsVersion(major: 0, minor: 29, patch: 4).isSupported, "la 0.29 no dibuja")
        try expect(!NwjsVersion(major: 0, minor: 47, patch: 3).isSupported, "la 0.47 tampoco")
        try expect(NwjsVersion(major: 0, minor: 48, patch: 0).isSupported, "la 0.48 es la primera que va")
        try expect(NwjsVersion(major: 0, minor: 115, patch: 0).isSupported, "y de ahí en adelante")
    }

    // MARK: - Manifiesto

    static func readsTheManifest() throws {
        let mz = Data("""
        { "name": "kadokawa-rpgmakermz", "main": "index.html",
          "window": { "title": "El Faro Rojo", "icon": "icon/icon.png", "width": 816 } }
        """.utf8)
        guard let manifest = NwjsInspector.parseManifest(mz) else {
            throw TestFailure(description: "no se leyó el package.json")
        }
        try expect(manifest.main == "index.html", "la página de arranque")
        try expect(manifest.title == "El Faro Rojo", "el título de la ventana")
        try expect(manifest.icon == "icon/icon.png", "el icono declarado")

        // Sin `main` NW.js no sabe qué abrir: eso no es un manifiesto suyo.
        try expect(NwjsInspector.parseManifest(Data(#"{ "name": "cualquier-cosa" }"#.utf8)) == nil,
                   "un package.json de Node cualquiera no es un juego")
        try expect(NwjsInspector.parseManifest(Data("no soy json".utf8)) == nil,
                   "un archivo roto no debería reventar nada")
    }

    // MARK: - Reconocimiento

    static func needsBothTheEngineAndTheManifest() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: (0, 48, 4, 0), layout: .mz)
        guard case .nwjs = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció como juego de NW.js")
        }

        // Sin nw.dll no hay forma de saber la versión, y con la equivocada la ventana sale negra.
        let sinDll = try TemporaryFixture()
        let otro = try makeGame(in: sinDll, version: (0, 48, 4, 0), layout: .mz)
        try FileManager.default.removeItem(at: otro.deletingLastPathComponent().appendingPathComponent("nw.dll"))
        try expect(PortableEngineDetector.detect(program: otro) == nil, "sin nw.dll no se afirma nada")

        let sinManifiesto = try TemporaryFixture()
        let tercero = try makeGame(in: sinManifiesto, version: (0, 48, 4, 0), layout: .mz)
        try FileManager.default.removeItem(
            at: tercero.deletingLastPathComponent().appendingPathComponent("package.json"))
        try expect(PortableEngineDetector.detect(program: tercero) == nil,
                   "sin package.json el motor no sabría qué abrir")
    }

    static func separatesTheGameFromTheEngine() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: (0, 48, 4, 0), layout: .mz)
        guard case .nwjs(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.gameEntries == ["css", "data", "icon", "img", "index.html", "js", "package.json"],
                   "se coló algo del motor o falta algo del juego: \(game.gameEntries)")
        try expect(game.gameBytes > 0, "el tamaño del juego se calcula para el aviso de sitio")

        for name in ["nw.dll", "nw.exe", "node.dll", "resources.pak", "locales", "swiftshader",
                     "icudtl.dat", "v8_context_snapshot.bin", "natives_blob.bin", "msvcp140.dll"] {
            try expect(NwjsInspector.isEngineFile(name), "\(name) la reparte NW.js")
        }
        for name in ["index.html", "package.json", "game.dll", "greenworks.node"] {
            try expect(!NwjsInspector.isEngineFile(name), "\(name) es del juego")
        }
    }

    /// RPG Maker MV mete el juego entero dentro de `www/` y deja el manifiesto apuntando ahí.
    static func recognisesAnRpgMakerMvLayout() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: (0, 48, 4, 0), layout: .mv)
        guard case .nwjs(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció el reparto de MV")
        }
        try expect(game.manifest.main == "www/index.html", "en MV la página cuelga de www/")
        try expect(game.gameEntries == ["package.json", "www"], "en MV solo viajan esas dos cosas: \(game.gameEntries)")
    }

    static func noticesModulesBuiltOnlyForWindows() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: (0, 48, 4, 0), layout: .mz,
                               extras: ["greenworks.node", "js/libs/sqlite3.dll"])
        guard case .nwjs(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.windowsModules == ["greenworks.node", "sqlite3.dll"],
                   "deberían salir los dos: \(game.windowsModules)")
    }

    // MARK: - Montaje

    /// RPG Maker llama `Game.exe` a todo lo que exporta, así que el nombre del ejecutable no dice
    /// nada. El del juego está en el título de la ventana.
    static func namesTheAppAfterTheWindowTitle() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: (0, 48, 4, 0), layout: .mz)
        guard case .nwjs(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.bundleExecutableName == "El Faro Rojo",
                   "debería llamarse como el juego, no «Game»: \(game.bundleExecutableName)")

        // Un título puede traer barras y dos puntos; un nombre de archivo, no.
        try expect(NwjsGame.sanearNombre("Aventura: 2/2") == "Aventura  2 2",
                   "los caracteres que rompen una ruta se cambian por espacios")
    }

    static func infoPlistStopsActingLikeABrowser() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: (0, 48, 4, 0), layout: .mz)
        guard case .nwjs(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        guard let patched = NwjsPorter.infoPlist(from: engineInfoPlist, game: game,
                                                 displayName: "El Faro Rojo", hasCustomIcon: true),
              let plist = (try? PropertyListSerialization.propertyList(from: patched, format: nil))
                as? [String: Any] else {
            throw TestFailure(description: "no se pudo reescribir el Info.plist")
        }
        try expect(plist["CFBundleExecutable"] as? String == "El Faro Rojo", "el ejecutable lleva el nombre del juego")
        try expect(plist["CFBundleIdentifier"] as? String == "com.lever.nwjs.El-Faro-Rojo",
                   "identificador propio: \(plist["CFBundleIdentifier"] ?? "")")
        try expect(plist["CFBundleDocumentTypes"] == nil, "un juego no abre archivos HTML ni GIF")
        try expect(plist["CFBundleURLTypes"] == nil, "ni responde a esquemas de URL")
        try expect(plist["CFBundleIconFile"] as? String == "icon", "el icono del juego")
        try expect(plist["CFBundleIconName"] == nil, "el catálogo compilado ganaría al .icns")
        try expect(plist["LSMinimumSystemVersion"] as? String == "10.10",
                   "lo que no se toca se conserva: se parte del plist del motor")
    }

    // MARK: - Utilidades

    /// Copia recortada del `Info.plist` que trae `nwjs.app`, con las claves que importan.
    private static let engineInfoPlist: Data = {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDocumentTypes</key>
            <array>
                <dict>
                    <key>CFBundleTypeName</key>
                    <string>HTML document</string>
                    <key>LSItemContentTypes</key>
                    <array><string>public.html</string></array>
                </dict>
            </array>
            <key>CFBundleExecutable</key>
            <string>nwjs</string>
            <key>CFBundleIconFile</key>
            <string>app.icns</string>
            <key>CFBundleIconName</key>
            <string>app</string>
            <key>CFBundleIdentifier</key>
            <string>io.nwjs.nwjs</string>
            <key>CFBundleName</key>
            <string>nwjs</string>
            <key>CFBundleURLTypes</key>
            <array>
                <dict><key>CFBundleURLSchemes</key><array><string>http</string></array></dict>
            </array>
            <key>LSMinimumSystemVersion</key>
            <string>10.10</string>
        </dict>
        </plist>
        """.utf8)
    }()

    private enum Layout { case mv, mz }

    /// Arma una carpeta como la que exporta RPG Maker para Windows.
    @discardableResult
    private static func makeGame(
        in fixture: TemporaryFixture,
        version: (Int, Int, Int, Int),
        layout: Layout,
        extras: [String] = []
    ) throws -> URL {
        let manager = FileManager.default
        let root = fixture.directoryURL.appendingPathComponent("juego-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        // Los binarios del motor, tal como los reparte NW.js.
        try WindowsBinary(productVersion: version).data.write(to: root.appendingPathComponent("nw.dll"))
        for name in ["node.dll", "ffmpeg.dll", "libEGL.dll", "resources.pak", "icudtl.dat",
                     "v8_context_snapshot.bin", "credits.html"] {
            try Data("motor".utf8).write(to: root.appendingPathComponent(name))
        }
        for folder in ["locales", "swiftshader"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        let interior = layout == .mv ? "www/" : ""
        for folder in ["js", "data", "img", "css", "icon"] {
            try manager.createDirectory(at: root.appendingPathComponent(interior + folder),
                                        withIntermediateDirectories: true)
        }
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent(interior + "index.html"))
        try Data("{}".utf8).write(to: root.appendingPathComponent(interior + "data/Map001.json"))
        try Data("""
        { "name": "kadokawa-rpgmaker", "main": "\(interior)index.html",
          "window": { "title": "El Faro Rojo", "icon": "\(interior)icon/icon.png" } }
        """.utf8).write(to: root.appendingPathComponent("package.json"))

        for extra in extras {
            let file = root.appendingPathComponent(interior + extra)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: file)
        }

        // RPG Maker renombra `nw.exe` y le deja siempre el mismo nombre.
        let exe = root.appendingPathComponent("Game.exe")
        try Data("MZ".utf8).write(to: exe)
        return exe
    }
}
