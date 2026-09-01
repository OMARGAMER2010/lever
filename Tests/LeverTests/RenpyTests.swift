import Foundation
import LeverCore

/// Pruebas del reconocimiento de juegos hechos con Ren'Py.
///
/// Lo que de verdad hay que fijar es la versión: el intérprete compilado y el código Python de
/// `renpy/` van emparejados, así que descargar el SDK equivocado da un juego que abre y muere.
enum RenpyTests {
    static func run() throws {
        try readsTheStampedVersion()
        try fallsBackToTheScriptVersion()
        try namesTheSDKDownload()
        try recognisesMacLibraryFolders()
        try noticesGamesThatAlreadyCarryMac()
        try needsBothRenpyAndGame()
        try rejectsVersionsTooOldForMacOS()
        try infoPlistUsesTheExecutableName()
    }

    // MARK: - Versión

    static func readsTheStampedVersion() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "8.6.0.25112108")

        guard case .renpy(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció como juego de Ren'Py")
        }
        try expect(game.fullVersion == "8.6.0.25112108", "la versión completa no coincide: \(game.fullVersion)")
        try expect(game.sdkVersion == "8.6.0", "el SDK se nombra con tres números, no cuatro")
        try expect(game.pythonLibraryName == "python3.12", "no encontró la biblioteca de Python")
        try expect(game.iconRelativePath == "game/gui/window_icon.png", "no encontró el icono de ventana")
        try expect(game.bundleExecutableName == "the_question", "el ejecutable sale del nombre del .exe")
    }

    /// Algún juego poda la carpeta `renpy/` y se lleva por delante `vc_version.py`. Ren'Py deja
    /// la versión también en `game/script_version.txt`, que es de donde se rescata.
    static func fallsBackToTheScriptVersion() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: nil, scriptVersionTuple: "(8, 3, 7)")

        guard case .renpy(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "sin vc_version.py debería seguir reconociéndose")
        }
        try expect(game.sdkVersion == "8.3.7", "no rescató la versión de script_version.txt: \(game.sdkVersion)")
    }

    static func namesTheSDKDownload() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "8.4.1.24080904")
        guard case .renpy(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.sdkURL.absoluteString == "https://www.renpy.org/dl/8.4.1/renpy-8.4.1-sdk.zip",
                   "la dirección del SDK no coincide: \(game.sdkURL)")
    }

    // MARK: - Binarios

    /// Ren'Py ha cambiado el nombre de la carpeta de macOS con los años; hay que reconocerlas todas.
    static func recognisesMacLibraryFolders() throws {
        for name in ["py3-mac-universal", "py2-mac-x86_64", "darwin-x86_64"] {
            try expect(RenpyInspector.isMacLibraryFolder(name), "\(name) es de macOS y no se reconoció")
        }
        for name in ["py3-windows-x86_64", "py3-linux-x86_64", "python3.12"] {
            try expect(!RenpyInspector.isMacLibraryFolder(name), "\(name) no es de macOS y se coló")
        }
    }

    /// Los paquetes «market» y «steam» traen las tres plataformas: ahí no hay nada que descargar.
    static func noticesGamesThatAlreadyCarryMac() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "8.6.0.1", extraLibraries: ["py3-mac-universal"])
        guard case .renpy(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.carriesMacRuntime, "debería haber visto que ya trae los binarios de macOS")
        try expect(game.runtimeIsCachedShortcut, "con los binarios dentro no hace falta descargar nada")
    }

    /// `game/` sola la tienen muchas cosas; `renpy/` sola, también. Hacen falta las dos.
    static func needsBothRenpyAndGame() throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("solo-game", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("game"), withIntermediateDirectories: true)
        let exe = root.appendingPathComponent("algo.exe")
        try Data("MZ".utf8).write(to: exe)
        try expect(PortableEngineDetector.detect(program: exe) == nil,
                   "una carpeta con solo game/ no es un juego de Ren'Py")
    }

    static func rejectsVersionsTooOldForMacOS() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "6.99.14.3218")
        guard case .renpy(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "debería reconocerlo aunque no lo soporte")
        }
        try expect(!game.isSupported, "Ren'Py 6 trae binarios de 32 bits: macOS ya no los ejecuta")

        // El fixture va en una variable propia: si se crea al vuelo, se libera en el acto y se
        // lleva la carpeta por delante antes de que dé tiempo a mirarla.
        let olderFixture = try TemporaryFixture()
        let seven = try makeGame(in: olderFixture, version: "7.5.3.22090809")
        guard case .renpy(let old)? = PortableEngineDetector.detect(program: seven) else {
            throw TestFailure(description: "Ren'Py 7 debería reconocerse")
        }
        try expect(old.isSupported, "Ren'Py 7 sí funciona")
        try expect(old.needsRosetta, "Ren'Py 7 solo trae binarios de Intel")
    }

    static func infoPlistUsesTheExecutableName() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, version: "8.6.0.1")
        guard case .renpy(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        let plist = RenpyPorter.infoPlist(for: game, displayName: "The Question")
        try expect(plist.contains("<key>CFBundleExecutable</key>\n\t<string>the_question</string>"),
                   "Ren'Py renombra el intérprete al nombre del juego: tiene que cuadrar con el Info.plist")
        try expect(plist.contains("<string>icon</string>"),
                   "el icono va sin extensión, como en las apps que genera Ren'Py")
    }

    // MARK: - Utilidades

    /// Arma la estructura mínima de un juego de Ren'Py exportado para Windows.
    @discardableResult
    private static func makeGame(
        in fixture: TemporaryFixture,
        version: String?,
        scriptVersionTuple: String? = nil,
        extraLibraries: [String] = []
    ) throws -> URL {
        let manager = FileManager.default
        let root = fixture.directoryURL.appendingPathComponent("the_question-win", isDirectory: true)

        for folder in ["game/gui", "renpy", "lib/python3.12", "lib/py3-windows-x86_64"] + extraLibraries.map({ "lib/\($0)" }) {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("icono".utf8).write(to: root.appendingPathComponent("game/gui/window_icon.png"))

        if let version {
            try Data("official = True\nversion = '\(version)'\n".utf8)
                .write(to: root.appendingPathComponent("renpy/vc_version.py"))
        }
        // Ren'Py escribe siempre esta tupla dentro de `game/`.
        try Data((scriptVersionTuple ?? "(8, 6, 0)").utf8)
            .write(to: root.appendingPathComponent("game/script_version.txt"))

        let exe = root.appendingPathComponent("the_question.exe")
        try Data("MZ".utf8).write(to: exe)
        return exe
    }
}

private extension RenpyGame {
    /// Si el juego ya trae los binarios de macOS, la caché es irrelevante.
    var runtimeIsCachedShortcut: Bool { carriesMacRuntime }
}
