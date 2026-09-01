import Foundation
import LeverCore

/// Pruebas de la detección y el traslado de juegos hechos con Godot.
///
/// El grueso está en armar paquetes `.pck` de verdad byte a byte. Es lo que de verdad hay que
/// comprobar: un desplazamiento mal leído no da error, da un juego que abre en negro.
enum GodotTests {
    static func run() throws {
        try versionNamesReleasesLikeGodotDoes()
        try readsExtensionConfig()
        try picksHostArchitecture()
        try namesAddonFromPath()
        try readsPackFormat3()
        try readsPackFormat2()
        try findsPackEmbeddedInTheExecutable()
        try ignoresFilesThatAreNotGames()
        try prefersTheProjectNameOverTheExecutable()
        try neverOverwritesAnExistingApp()
        try infoPlistCarriesTheExecutableName()
        try spaceEstimateGrowsWhenBuilding()
    }

    // MARK: - Versiones

    /// Godot omite el parche cuando es cero. Equivocarse aquí es un 404 al descargar el motor.
    static func versionNamesReleasesLikeGodotDoes() throws {
        try expect(GodotVersion(major: 4, minor: 6, patch: 2).releaseTag == "4.6.2-stable",
                   "4.6.2 debería publicarse como 4.6.2-stable")
        try expect(GodotVersion(major: 4, minor: 3, patch: 0).releaseTag == "4.3-stable",
                   "4.3.0 debería publicarse como 4.3-stable, sin el cero")
        try expect(GodotVersion(major: 4, minor: 6, patch: 0).templatesURL.absoluteString
                    .hasSuffix("4.6-stable/Godot_v4.6-stable_export_templates.tpz"),
                   "la dirección de las plantillas no coincide con la de GitHub")
    }

    // MARK: - Complementos nativos

    static func readsExtensionConfig() throws {
        let config = """
        [configuration]
        entry_symbol = "gozen_library_init"

        [libraries]

        windows.release.x86_64 = "res://addons/gde_gozen/bin/libgozen.windows.template_release.x86_64.dll"
        macos.debug.arm64 = "res://addons/gde_gozen/bin/libgozen.macos.template_debug.arm64.dylib"
        macos.release.arm64 = "res://addons/gde_gozen/bin/libgozen.macos.template_release.arm64.dylib"
        macos.release.x86_64 = "res://addons/gde_gozen/bin/libgozen.macos.template_release.x86_64.dylib"
        """
        let arm = GodotInspector.macLibraryPath(inConfig: config, hostArchitecture: "arm64")
        try expect(arm == "res://addons/gde_gozen/bin/libgozen.macos.template_release.arm64.dylib",
                   "en arm64 debería elegir la librería de arm64 y de release, no la de depuración")

        let intel = GodotInspector.macLibraryPath(inConfig: config, hostArchitecture: "x86_64")
        try expect(intel?.hasSuffix("template_release.x86_64.dylib") == true,
                   "en Intel debería elegir la de x86_64")

        try expect(GodotInspector.macLibraryPath(inConfig: "[libraries]\nwindows.release.x86_64 = \"a.dll\"") == nil,
                   "si el .gdextension no menciona macOS no hay nada que copiar")
    }

    /// Una clave sin arquitectura vale para cualquier Mac; una de otra arquitectura, no.
    static func picksHostArchitecture() throws {
        let config = "[libraries]\nmacos.release = \"res://bin/lib.dylib\""
        try expect(GodotInspector.macLibraryPath(inConfig: config, hostArchitecture: "arm64") == "res://bin/lib.dylib",
                   "una clave sin arquitectura debería servir")

        let other = "[libraries]\nmacos.release.x86_64 = \"res://bin/intel.dylib\""
        try expect(GodotInspector.macLibraryPath(inConfig: other, hostArchitecture: "arm64") == nil,
                   "una librería de Intel no sirve en un Mac con Apple silicon")
    }

    static func namesAddonFromPath() throws {
        try expect(GodotInspector.addonName(fromConfigPath: "addons/gde_gozen/gozen.gdextension") == "gde_gozen",
                   "el nombre del complemento sale de la carpeta dentro de addons/")
        try expect(GodotInspector.addonName(fromConfigPath: "jolt.gdextension") == "jolt",
                   "sin carpeta addons/ vale el nombre del propio archivo")
    }

    // MARK: - Lectura del paquete

    static func readsPackFormat3() throws {
        let fixture = try TemporaryFixture()
        let pack = try makePack(format: 3, version: (4, 6, 2))
        try pack.write(to: fixture.directoryURL.appendingPathComponent("Juego.pck"))
        let exe = try fixture.makeFile(named: "Juego.exe")

        guard let game = GodotInspector.inspect(program: exe, library: emptyLibrary()) else {
            throw TestFailure(description: "no se reconoció el paquete en formato 3")
        }
        try expect(game.version == GodotVersion(major: 4, minor: 6, patch: 2),
                   "la versión leída no coincide: \(game.version)")
        try expect(game.projectName == "juegodeprueba", "no se leyó el nombre del proyecto")
        try expect(game.extensions.count == 1, "debería haber encontrado un .gdextension")
        try expect(game.extensions[0].addonName == "gde_gozen", "el complemento no se llamó bien")
        try expect(game.unresolvedExtensions.count == 1,
                   "sin el .dylib guardado, el complemento debería contar como pendiente")
        try expect(game.bundleExecutableName == "Juego",
                   "el ejecutable del bundle tiene que llamarse igual que el .pck")
    }

    /// El formato 2 (Godot 4.0–4.4) pone el índice justo detrás de la cabecera, no al final.
    static func readsPackFormat2() throws {
        let fixture = try TemporaryFixture()
        let pack = try makePack(format: 2, version: (4, 2, 1))
        try pack.write(to: fixture.directoryURL.appendingPathComponent("Otro.pck"))
        let exe = try fixture.makeFile(named: "Otro.exe")

        guard let game = GodotInspector.inspect(program: exe, library: emptyLibrary()) else {
            throw TestFailure(description: "no se reconoció el paquete en formato 2")
        }
        try expect(game.version == GodotVersion(major: 4, minor: 2, patch: 1),
                   "la versión leída no coincide: \(game.version)")
        try expect(game.extensions.count == 1, "el índice del formato 2 no se recorrió bien")
    }

    /// Exportación de un solo archivo: el paquete va pegado al final del `.exe`.
    static func findsPackEmbeddedInTheExecutable() throws {
        let fixture = try TemporaryFixture()
        let exe = fixture.directoryURL.appendingPathComponent("Solo.exe")

        var blob = Data("MZ".utf8) + Data(repeating: 0, count: 4094) // relleno de cabecera falsa
        let start = UInt64(blob.count)
        let pack = try makePack(format: 3, version: (4, 5, 0))
        blob += pack
        blob += littleEndian(UInt64(pack.count))            // tamaño del bloque
        blob += Data([0x47, 0x44, 0x50, 0x43])              // "GDPC" de cierre
        try blob.write(to: exe)

        try expect(GodotInspector.embeddedPackOffset(in: exe) == start,
                   "no se encontró el paquete incrustado en el sitio correcto")

        guard let game = GodotInspector.inspect(program: exe, library: emptyLibrary()) else {
            throw TestFailure(description: "no se reconoció el juego con el paquete incrustado")
        }
        try expect(game.pack.isEmbedded, "debería haberlo marcado como incrustado")
        try expect(game.version == GodotVersion(major: 4, minor: 5, patch: 0),
                   "la versión del paquete incrustado no coincide")
    }

    /// Lo normal es que un `.exe` no sea de Godot: eso no es un fallo, es que no aplica.
    static func ignoresFilesThatAreNotGames() throws {
        let fixture = try TemporaryFixture()
        let exe = try fixture.makeFile(named: "Cualquiera.exe")
        try expect(GodotInspector.inspect(program: exe, library: emptyLibrary()) == nil,
                   "un .exe corriente no debería pasar por juego de Godot")
    }

    // MARK: - Montaje

    /// El ejecutable suele ser una sigla y el proyecto lleva el nombre de verdad: `TC.exe` con
    /// `townscharm` dentro tiene que salir como «townscharm.app», no como «TC.app».
    static func prefersTheProjectNameOverTheExecutable() throws {
        let game = try sampleGame(named: "TC", projectName: "townscharm")
        try expect(game.suggestedAppName == "townscharm", "debería mandar el nombre del proyecto")
        try expect(game.bundleExecutableName == "TC",
                   "el ejecutable de dentro sigue siendo el del .exe, que es como se busca el .pck")

        let sinProyecto = try sampleGame(named: "MiJuego", projectName: nil)
        try expect(sinProyecto.suggestedAppName == "MiJuego",
                   "sin nombre de proyecto vale el del ejecutable")
    }

    static func neverOverwritesAnExistingApp() throws {
        let fixture = try TemporaryFixture()
        let game = try sampleGame(named: "Juego", projectName: "Juego")
        let first = GodotPorter.destinationURL(for: game, in: fixture.directoryURL)
        try expect(first.lastPathComponent == "Juego.app", "el primer nombre debería ser el limpio")

        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = GodotPorter.destinationURL(for: game, in: fixture.directoryURL)
        try expect(second.lastPathComponent == "Juego 2.app",
                   "con una app ya puesta debería buscar otro nombre en vez de pisarla")
    }

    static func infoPlistCarriesTheExecutableName() throws {
        let game = try sampleGame(named: "TC")
        let plist = GodotPorter.infoPlist(for: game, displayName: "Town's Charm & Co")
        try expect(plist.contains("<key>CFBundleExecutable</key>\n\t<string>TC</string>"),
                   "Godot busca el .pck por el nombre del ejecutable: tiene que ir en el Info.plist")
        try expect(plist.contains("Town's Charm &amp; Co"), "el ampersand debería ir escapado en el XML")
    }

    static func spaceEstimateGrowsWhenBuilding() throws {
        let game = try sampleGame(named: "Juego", projectName: "Juego", addon: "gde_gozen")
        let withoutBuilding = GodotPorter.requiredBytes(for: game, hasTemplate: true, buildingExtensions: false)
        let building = GodotPorter.requiredBytes(for: game, hasTemplate: true, buildingExtensions: true)
        try expect(building > withoutBuilding,
                   "compilar FFmpeg ocupa gigas: la estimación tiene que reflejarlo")
    }

    // MARK: - Utilidades

    private static func sampleGame(
        named name: String,
        projectName: String? = nil,
        addon: String? = nil
    ) throws -> GodotGame {
        let exe = URL(fileURLWithPath: "/tmp/\(name).exe")
        let extensions = addon.map {
            [GodotExtension(
                configPath: "addons/\($0)/\($0).gdextension",
                addonName: $0,
                macLibraryPath: "res://addons/\($0)/bin/lib.macos.template_release.arm64.dylib",
                isSatisfied: false
            )]
        } ?? []
        return GodotGame(
            executable: exe,
            version: GodotVersion(major: 4, minor: 6, patch: 2),
            pack: .sibling(URL(fileURLWithPath: "/tmp/\(name).pck")),
            packFormat: 3,
            projectName: projectName,
            iconPath: nil,
            extensions: extensions
        )
    }

    /// Una biblioteca vacía y aparte. Si apuntara a la de verdad, en cuanto el usuario compilara
    /// GoZen una vez estas pruebas empezarían a fallar solas.
    private static func emptyLibrary() -> PortLibrary {
        PortLibrary(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("LeverTests-lib-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    private static func littleEndian(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) })
    }

    /// Arma un `.pck` real con dos archivos dentro: un `.gdextension` y el `project.binary`.
    ///
    /// Se escribe a mano en vez de guardar un binario de ejemplo en el repo porque así la prueba
    /// documenta el formato: si Godot lo cambia, aquí se ve exactamente qué campo se movió.
    private static func makePack(format: Int, version: (Int, Int, Int)) throws -> Data {
        let config = Data("""
        [configuration]
        entry_symbol = "algo_init"

        [libraries]
        macos.release.arm64 = "res://addons/gde_gozen/bin/libgozen.macos.template_release.arm64.dylib"
        macos.release.x86_64 = "res://addons/gde_gozen/bin/libgozen.macos.template_release.x86_64.dylib"
        """.utf8)

        // `project.binary`: "ECFG", número de ajustes y, por cada uno, clave y valor en formato
        // Variant (tipo 4 = cadena).
        var project = Data("ECFG".utf8) + littleEndian(UInt32(1))
        let key = Data("application/config/name".utf8)
        let text = Data("juegodeprueba".utf8)
        let value = littleEndian(UInt32(4)) + littleEndian(UInt32(text.count)) + text
        project += littleEndian(UInt32(key.count)) + key
        project += littleEndian(UInt32(value.count)) + value

        let files: [(String, Data)] = [
            ("res://addons/gde_gozen/gozen.gdextension", config),
            ("res://project.binary", project)
        ]

        let headerSize = format == 3 ? 40 : 96
        var body = Data()
        var placed: [(String, UInt64, UInt64)] = []
        for (path, data) in files {
            placed.append((path, UInt64(body.count), UInt64(data.count)))
            body += data
        }

        var directory = littleEndian(UInt32(files.count))
        for (path, offset, size) in placed {
            var name = Data(path.utf8)
            while name.count % 4 != 0 { name.append(0) } // Godot alinea las rutas a cuatro bytes
            directory += littleEndian(UInt32(name.count)) + name
            directory += littleEndian(offset) + littleEndian(size)
            directory += Data(repeating: 0, count: 16)   // md5, que aquí no se comprueba
            directory += littleEndian(UInt32(0))         // banderas del archivo
        }

        // En el formato 3 los datos van justo detrás de la cabecera y el índice al final; en el
        // formato 2 es al revés, así que la base de los datos se corre lo que ocupe el índice.
        let fileBase = format == 3 ? headerSize : headerSize + directory.count

        var header = Data([0x47, 0x44, 0x50, 0x43])       // "GDPC"
        header += littleEndian(UInt32(format))
        header += littleEndian(UInt32(version.0))
        header += littleEndian(UInt32(version.1))
        header += littleEndian(UInt32(version.2))
        header += littleEndian(UInt32(2))                 // base relativa al inicio del paquete
        header += littleEndian(UInt64(fileBase))

        if format == 3 {
            header += littleEndian(UInt64(headerSize + body.count)) // dónde está el índice
            return header + body + directory
        }
        header += Data(repeating: 0, count: 64)           // enteros reservados
        return header + directory + body
    }
}
