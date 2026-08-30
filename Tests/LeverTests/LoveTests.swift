import Foundation
import LeverCore

/// Pruebas del reconocimiento de juegos hechos con LÖVE.
///
/// Aquí lo delicado son dos lecturas de formatos ajenos: el recurso de versión de un binario de
/// Windows y el final de un ZIP escondido detrás de un `.exe`. Las dos se prueban contra archivos
/// armados byte a byte, porque con datos inventados a medias siempre pasan.
enum LoveTests {
    static func run() throws {
        try namesEveryDownloadCorrectly()
        try knowsWhichVersionsMacOSStillRuns()
        try readsTheVersionFromTheDLL()
        try findsTheGameStuckToTheExe()
        try recognisesAFusedGame()
        try recognisesAGameNextToTheEngine()
        try ignoresAnExeWithSomeOtherZipInside()
        try needsTheEngineLibrary()
        try tellsGameLibrariesFromEngineLibraries()
        try readsTheWindowIconFromConf()
        try infoPlistStopsClaimingLoveFiles()
    }

    // MARK: - Versiones

    /// LÖVE nombró sus archivos de tres maneras distintas a lo largo de diecisiete
    /// publicaciones. Cada forma se comprobó contra la lista real de GitHub.
    static func namesEveryDownloadCorrectly() throws {
        let cases: [(LoveVersion, String, String)] = [
            (LoveVersion(major: 11, minor: 5, patch: 0), "11.5", "love-11.5-macos.zip"),
            (LoveVersion(major: 11, minor: 4, patch: 0), "11.4", "love-11.4-macos.zip"),
            // La 11.0 es la excepción: etiqueta de dos cifras, archivo de tres.
            (LoveVersion(major: 11, minor: 0, patch: 0), "11.0", "love-11.0.0-macos.zip"),
            (LoveVersion(major: 0, minor: 10, patch: 2), "0.10.2", "love-0.10.2-macosx-x64.zip"),
            (LoveVersion(major: 0, minor: 9, patch: 0), "0.9.0", "love-0.9.0-macosx-x64.zip")
        ]
        for (version, tag, asset) in cases {
            try expect(version.releaseTag == tag, "la etiqueta de \(version) debería ser \(tag)")
            try expect(version.macAssetName == asset, "el archivo de \(version) debería ser \(asset)")
            try expect(
                version.macDownloadURL.absoluteString
                    == "https://github.com/love2d/love/releases/download/\(tag)/\(asset)",
                "la dirección de \(version) no cuadra: \(version.macDownloadURL)"
            )
        }
    }

    static func knowsWhichVersionsMacOSStillRuns() throws {
        // Hasta la 0.8 los binarios son universales de PowerPC e Intel de 32 bits, y macOS dejó
        // de ejecutar 32 bits en Catalina.
        try expect(!LoveVersion(major: 0, minor: 8, patch: 0).isSupported, "la 0.8 es de 32 bits")
        try expect(LoveVersion(major: 0, minor: 10, patch: 2).isSupported, "la 0.10.2 arranca en macOS 15")
        try expect(LoveVersion(major: 11, minor: 5, patch: 0).isSupported, "la 11.5 arranca")

        // Los binarios nativos de arm64 llegaron en la 11.4.
        try expect(LoveVersion(major: 0, minor: 10, patch: 2).needsRosetta, "la 0.10.2 es solo Intel")
        try expect(LoveVersion(major: 11, minor: 3, patch: 0).needsRosetta, "la 11.3 es solo Intel")
        try expect(!LoveVersion(major: 11, minor: 4, patch: 0).needsRosetta, "la 11.4 ya trae arm64")
    }

    /// La versión sale del recurso `VS_VERSION_INFO`, que vive dentro del árbol de recursos del
    /// PE y hay que alcanzar bajando tres niveles: tipo, nombre e idioma.
    static func readsTheVersionFromTheDLL() throws {
        let fixture = try TemporaryFixture()
        let dll = fixture.directoryURL.appendingPathComponent("love.dll")
        try WindowsBinary(productVersion: (11, 5, 0, 2)).data.write(to: dll)

        guard let version = WindowsVersionResource.productVersion(of: dll) else {
            throw TestFailure(description: "no se leyó el recurso de versión")
        }
        try expect(version == LoveVersion(major: 11, minor: 5, patch: 0),
                   "la versión leída no cuadra: \(version)")

        let vieja = fixture.directoryURL.appendingPathComponent("vieja.dll")
        try WindowsBinary(productVersion: (0, 10, 2, 0)).data.write(to: vieja)
        try expect(WindowsVersionResource.productVersion(of: vieja) == LoveVersion(major: 0, minor: 10, patch: 2),
                   "la serie 0.x lleva las tres cifras en el recurso")
    }

    // MARK: - Encontrar el juego

    /// El `.love` no lleva ningún pie que diga dónde empieza: se reconstruye restando al final
    /// del directorio central su tamaño y su desplazamiento.
    static func findsTheGameStuckToTheExe() throws {
        let fixture = try TemporaryFixture()
        let love = try makeLove(in: fixture, named: "juego.love", extra: ["conf.lua": "-- nada"])
        let prefix = Data(repeating: 0x90, count: 4096)
        let exe = fixture.directoryURL.appendingPathComponent("pegado.exe")
        try (prefix + (try Data(contentsOf: love))).write(to: exe)

        guard let start = ZipTrailer.archiveStart(of: exe) else {
            throw TestFailure(description: "no encontró el principio del ZIP")
        }
        try expect(start == 4096, "el ZIP empieza en 4096, no en \(start)")
        try expect(ZipTrailer.containsMainLua(in: exe, archiveStart: start), "main.lua está en la raíz")
    }

    static func recognisesAFusedGame() throws {
        let fixture = try TemporaryFixture()
        let root = try makeDistribution(in: fixture, version: (11, 5, 0, 2), fused: true)

        guard case .love(let game)? = PortableEngineDetector.detect(program: root) else {
            throw TestFailure(description: "no se reconoció como juego de LÖVE")
        }
        try expect(game.version == "11.5", "la versión sale de love.dll: \(game.version)")
        try expect(game.bundleExecutableName == "MiJuego", "la app se llama como el .exe")
        guard case .fused(_, let offset) = game.payload else {
            throw TestFailure(description: "debería estar pegado al .exe")
        }
        try expect(offset > 0, "el .love empieza después del ejecutable")
        try expect(game.payloadBytes > 0, "el tamaño del .love se sabe sin extraerlo")
    }

    /// Hay quien reparte `love.exe` con el `.love` al lado en vez de fusionarlos.
    static func recognisesAGameNextToTheEngine() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeDistribution(in: fixture, version: (11, 5, 0, 2), fused: false)

        guard case .love(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció con el .love suelto")
        }
        guard case .sibling(let file) = game.payload else {
            throw TestFailure(description: "debería ser el .love de al lado")
        }
        try expect(file.lastPathComponent == "juego.love", "cogió otro archivo: \(file.lastPathComponent)")
        try expect(game.bundleExecutableName == "juego",
                   "con el love.exe de serie el nombre bueno es el del .love, no «love»")
    }

    /// Un instalador autoextraíble también es un `.exe` con un ZIP pegado. Lo que separa a un
    /// juego de LÖVE es el `main.lua` en la raíz del ZIP.
    static func ignoresAnExeWithSomeOtherZipInside() throws {
        let fixture = try TemporaryFixture()
        let folder = fixture.directoryURL.appendingPathComponent("instalador", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WindowsBinary(productVersion: (11, 5, 0, 2)).data
            .write(to: folder.appendingPathComponent("love.dll"))

        let zip = try makeZip(in: fixture, named: "otro.zip", files: ["leeme.txt": "hola"])
        let exe = folder.appendingPathComponent("instalador.exe")
        try (Data(repeating: 0x90, count: 512) + (try Data(contentsOf: zip))).write(to: exe)

        try expect(PortableEngineDetector.detect(program: exe) == nil,
                   "un ZIP sin main.lua no es un juego de LÖVE")
    }

    /// Sin `love.dll` no hay forma de saber qué versión del motor pide el juego, y con la
    /// equivocada el juego abre y muere. Mejor no reconocerlo que prometer un traslado a ciegas.
    static func needsTheEngineLibrary() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeDistribution(in: fixture, version: (11, 5, 0, 2), fused: true)
        try FileManager.default.removeItem(at: exe.deletingLastPathComponent().appendingPathComponent("love.dll"))

        try expect(PortableEngineDetector.detect(program: exe) == nil,
                   "sin love.dll no se puede afirmar la versión")
    }

    static func tellsGameLibrariesFromEngineLibraries() throws {
        for name in ["love.dll", "lua51.dll", "SDL2.dll", "OpenAL32.dll", "msvcr120.dll", "VCRUNTIME140.dll"] {
            try expect(LoveInspector.isEngineLibrary(name), "\(name) la trae el motor")
        }
        for name in ["https.dll", "sqlite3.dll", "cimgui.dll"] {
            try expect(!LoveInspector.isEngineLibrary(name), "\(name) la trae el juego")
        }

        let fixture = try TemporaryFixture()
        let exe = try makeDistribution(in: fixture, version: (11, 5, 0, 2), fused: true,
                                       extraLibraries: ["https.dll", "socket/core.dll"])
        guard case .love(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.windowsLibraries == ["core.dll", "https.dll"],
                   "debería nombrar las dos del juego: \(game.windowsLibraries)")
    }

    // MARK: - Montaje

    static func readsTheWindowIconFromConf() throws {
        let conf = """
        function love.conf(t)
            t.window.title = "Juego"
            t.window.icon = "assets/icono.png"
        end
        """
        try expect(LovePorter.windowIconPath(inConf: conf) == "assets/icono.png",
                   "no encontró el icono declarado")

        // Un icono comentado es un icono que el desarrollador quitó.
        let comentado = """
        function love.conf(t)
            -- t.window.icon = "viejo.png"
            t.window.title = "Juego"
        end
        """
        try expect(LovePorter.windowIconPath(inConf: comentado) == nil,
                   "un comentario no declara nada")
    }

    /// El `Info.plist` del motor dice que la app abre archivos `.love` y que es la dueña de ese
    /// tipo. Si se copia tal cual, cada juego trasladado se pelea con los demás por abrirlos.
    static func infoPlistStopsClaimingLoveFiles() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeDistribution(in: fixture, version: (11, 5, 0, 2), fused: true)
        guard case .love(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }

        guard let patched = LovePorter.infoPlist(from: engineInfoPlist, game: game,
                                                 displayName: "Mi Juego", hasCustomIcon: true),
              let plist = (try? PropertyListSerialization.propertyList(from: patched, format: nil))
                as? [String: Any] else {
            throw TestFailure(description: "no se pudo reescribir el Info.plist")
        }

        try expect(plist["CFBundleExecutable"] as? String == "MiJuego",
                   "el ejecutable se renombra al nombre del juego")
        try expect(plist["CFBundleIdentifier"] as? String == "com.lever.love.MiJuego",
                   "cada juego necesita su propio identificador")
        try expect(plist["CFBundleName"] as? String == "Mi Juego", "el nombre visible es el del juego")
        try expect(plist["UTExportedTypeDeclarations"] == nil, "ya no declara el tipo .love")
        try expect(plist["CFBundleDocumentTypes"] == nil,
                   "un juego trasladado no abre archivos: el .love de dentro gana siempre")
        try expect(plist["CFBundleIconFile"] as? String == "icon", "el icono del juego")
        try expect(plist["CFBundleIconName"] == nil,
                   "el catálogo compilado ganaría al .icns si se quedara")
        try expect(plist["CFBundleSignature"] as? String == "LoVe",
                   "lo que no se toca se conserva: se parte del plist del motor, no de uno nuevo")
    }

    // MARK: - Utilidades

    /// Copia recortada del `Info.plist` que trae `love.app`, con las claves que importan.
    private static let engineInfoPlist: Data = {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDocumentTypes</key>
            <array>
                <dict>
                    <key>CFBundleTypeExtensions</key>
                    <array><string>love</string></array>
                    <key>CFBundleTypeName</key>
                    <string>LÖVE Project</string>
                    <key>LSItemContentTypes</key>
                    <array><string>org.love2d.love-game</string></array>
                </dict>
            </array>
            <key>CFBundleExecutable</key>
            <string>love</string>
            <key>CFBundleIconFile</key>
            <string>OS X AppIcon</string>
            <key>CFBundleIconName</key>
            <string>OS X AppIcon</string>
            <key>CFBundleIdentifier</key>
            <string>org.love2d.love</string>
            <key>CFBundleName</key>
            <string>LÖVE</string>
            <key>CFBundleSignature</key>
            <string>LoVe</string>
            <key>UTExportedTypeDeclarations</key>
            <array>
                <dict>
                    <key>UTTypeIdentifier</key>
                    <string>org.love2d.love-game</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        return Data(text.utf8)
    }()

    /// Arma una carpeta como la que reparte un juego de LÖVE para Windows.
    @discardableResult
    private static func makeDistribution(
        in fixture: TemporaryFixture,
        version: (Int, Int, Int, Int),
        fused: Bool,
        extraLibraries: [String] = []
    ) throws -> URL {
        let manager = FileManager.default
        let root = fixture.directoryURL.appendingPathComponent("MiJuego-win64-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        try WindowsBinary(productVersion: version).data.write(to: root.appendingPathComponent("love.dll"))
        for name in ["lua51.dll", "SDL2.dll"] + extraLibraries {
            let target = root.appendingPathComponent(name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: target)
        }

        let love = try makeLove(in: fixture, named: "juego.love", extra: [:])
        if fused {
            let exe = root.appendingPathComponent("MiJuego.exe")
            try (Data(repeating: 0x90, count: 2048) + (try Data(contentsOf: love))).write(to: exe)
            return exe
        }
        let exe = root.appendingPathComponent("love.exe")
        try Data("MZ".utf8).write(to: exe)
        try manager.copyItem(at: love, to: root.appendingPathComponent("juego.love"))
        return exe
    }

    private static func makeLove(in fixture: TemporaryFixture, named: String, extra: [String: String]) throws -> URL {
        var files = ["main.lua": "function love.draw() end"]
        files.merge(extra) { _, new in new }
        return try makeZip(in: fixture, named: named, files: files)
    }

    /// Se comprime con `zip` de verdad y no con un ZIP escrito a mano: lo que hay que probar es
    /// que el lector aguanta lo que produce una herramienta real.
    private static func makeZip(in fixture: TemporaryFixture, named: String, files: [String: String]) throws -> URL {
        let manager = FileManager.default
        let workshop = fixture.directoryURL.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workshop, withIntermediateDirectories: true)
        for (name, body) in files {
            let file = workshop.appendingPathComponent(name)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file)
        }

        let archive = fixture.directoryURL.appendingPathComponent("\(UUID().uuidString)-\(named)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "."]
        process.currentDirectoryURL = workshop
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard manager.fileExists(atPath: archive.path) else {
            throw TestFailure(description: "no se pudo crear el ZIP de prueba")
        }
        return archive
    }
}

/// Un PE de Windows mínimo pero válido, con un recurso `VS_VERSION_INFO` dentro.
///
/// Se arma byte a byte porque no se puede meter una `love.dll` de verdad en el repositorio, y
/// porque un archivo inventado a medias haría pasar la prueba sin recorrer el árbol de recursos,
/// que es justo la parte que puede salir mal.
private struct WindowsBinary {
    let productVersion: (Int, Int, Int, Int)

    private static let sectionRVA: UInt32 = 0x1000
    private static let sectionOffset: UInt32 = 0x400

    var data: Data {
        let resources = resourceSection
        var file = Data()

        // Cabecera DOS: solo importan la firma y el puntero a la cabecera PE.
        var dos = Data(repeating: 0, count: 64)
        dos[0] = 0x4D; dos[1] = 0x5A                       // "MZ"
        dos.replaceSubrange(60..<64, with: le32(0x40))     // e_lfanew
        file += dos

        file += Data([0x50, 0x45, 0x00, 0x00])             // "PE\0\0"

        // Cabecera COFF.
        file += le16(0x8664)                               // máquina: x86-64
        file += le16(1)                                    // una sección
        file += le32(0) + le32(0) + le32(0)                // fecha y tabla de símbolos
        file += le16(240)                                  // tamaño de la cabecera opcional
        file += le16(0x2022)

        // Cabecera opcional PE32+: todo ceros salvo la firma y el directorio de recursos.
        var optional = Data(repeating: 0, count: 240)
        optional.replaceSubrange(0..<2, with: le16(0x20B))
        let directoryStart = 112 + 2 * 8                   // entrada 2: recursos
        optional.replaceSubrange(directoryStart..<(directoryStart + 4), with: le32(Self.sectionRVA))
        optional.replaceSubrange((directoryStart + 4)..<(directoryStart + 8), with: le32(UInt32(resources.count)))
        file += optional

        // Cabecera de la sección `.rsrc`.
        var name = Data(".rsrc".utf8)
        name.append(Data(repeating: 0, count: 8 - name.count))
        file += name
        file += le32(UInt32(resources.count))              // tamaño virtual
        file += le32(Self.sectionRVA)
        file += le32(UInt32(resources.count))              // tamaño en el archivo
        file += le32(Self.sectionOffset)
        file += Data(repeating: 0, count: 16)

        file += Data(repeating: 0, count: Int(Self.sectionOffset) - file.count)
        file += resources
        return file
    }

    /// Tres directorios encadenados —tipo, nombre e idioma— y al final la hoja con los datos.
    private var resourceSection: Data {
        let directorySize = 16 + 8
        let typeDirectory = 0
        let nameDirectory = directorySize
        let languageDirectory = directorySize * 2
        let dataEntry = directorySize * 3
        let blob = dataEntry + 16

        var section = Data()
        section += directory(entryName: 16, target: UInt32(nameDirectory), isDirectory: true)       // RT_VERSION
        section += directory(entryName: 1, target: UInt32(languageDirectory), isDirectory: true)
        section += directory(entryName: 0x409, target: UInt32(dataEntry), isDirectory: false)

        let contents = versionBlob
        section += le32(Self.sectionRVA + UInt32(blob))    // la hoja apunta con dirección virtual
        section += le32(UInt32(contents.count))
        section += le32(0) + le32(0)
        section += contents

        _ = typeDirectory
        return section
    }

    private func directory(entryName: UInt32, target: UInt32, isDirectory: Bool) -> Data {
        var block = Data()
        block += le32(0) + le32(0)                         // características y fecha
        block += le16(0) + le16(0)                         // versión del formato
        block += le16(0)                                   // entradas con nombre
        block += le16(1)                                   // entradas con número
        block += le32(entryName)
        block += le32(isDirectory ? target | 0x8000_0000 : target)
        return block
    }

    private var versionBlob: Data {
        var block = Data()
        block += le16(0) + le16(52) + le16(0)              // longitudes y tipo
        for scalar in "VS_VERSION_INFO".unicodeScalars { block += le16(UInt16(scalar.value)) }
        block += le16(0)
        while block.count % 4 != 0 { block += Data([0]) }

        block += le32(0xFEEF_04BD)                         // firma del bloque fijo
        block += le32(0x0001_0000)                         // versión de la estructura
        block += le32(0) + le32(0)                         // versión del archivo (aquí no se usa)
        block += le32(UInt32(productVersion.0) << 16 | UInt32(productVersion.1))
        block += le32(UInt32(productVersion.2) << 16 | UInt32(productVersion.3))
        block += Data(repeating: 0, count: 28)             // resto del bloque fijo
        return block
    }

    private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
