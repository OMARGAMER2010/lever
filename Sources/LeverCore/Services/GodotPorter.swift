import Foundation

/// Convierte un juego de Godot exportado para Windows en un `.app` de macOS.
///
/// El truco es que no hay nada que traducir: el `.exe` solo es el motor, y el motor existe
/// compilado para Mac. Se descarga la plantilla oficial de la misma versión, se le pone al lado
/// el `.pck` del juego y se firma. El resultado corre nativo, sin Wine y sin Rosetta.
public enum GodotPorter {
    // MARK: - Órdenes sueltas (el punto por donde entran las pruebas)

    public static func downloadTemplatesCommand(version: GodotVersion, into file: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            // `--fail` es lo que convierte un 404 en un error en vez de en un archivo con una
            // página de GitHub dentro que luego reventaría al descomprimir.
            arguments: ["-L", "--fail", "--progress-bar", "-o", file.path, version.templatesURL.absoluteString],
            currentDirectoryURL: nil
        )
    }

    /// Del `.tpz` —que trae todas las plataformas— solo interesa `templates/macos.zip`.
    public static func extractMacArchiveCommand(from archive: URL, into folder: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-o", "-j", archive.path, "templates/macos.zip", "-d", folder.path],
            currentDirectoryURL: nil
        )
    }

    public static func unzipCommand(_ archive: URL, into folder: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", "-o", archive.path, "-d", folder.path],
            currentDirectoryURL: nil
        )
    }

    /// Deja el binario del motor solo con la arquitectura de este Mac.
    ///
    /// Ahorra la mitad del tamaño, pero sobre todo evita que el motor arranque en x86_64 bajo
    /// Rosetta y luego no pueda cargar un complemento compilado para arm64.
    public static func thinCommand(binary: URL, architecture: String, output: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: [binary.path, "-thin", architecture, "-output", output.path],
            currentDirectoryURL: nil
        )
    }

    /// Copia con `-c`: en APFS es un clon, así que el `.pck` de trescientos megas no ocupa el
    /// doble. Es importante en discos llenos, que es justo cuando la gente instala juegos.
    public static func cloneCommand(from source: URL, to destination: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", source.path, destination.path],
            currentDirectoryURL: nil
        )
    }

    public static func signCommand(_ target: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", target.path],
            currentDirectoryURL: nil
        )
    }

    /// Sin esto macOS trataría el `.app` como descargado y pediría permiso al abrirlo.
    public static func clearQuarantineCommand(_ target: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-cr", target.path],
            currentDirectoryURL: nil
        )
    }

    public static func buildExtensionCommand(
        script: URL,
        output: URL,
        architecture: String
    ) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, output.path, architecture],
            currentDirectoryURL: nil,
            // Una app lanzada desde el Finder recibe un PATH mínimo, y el guion necesita
            // Homebrew para `scons` y `cmake`.
            environment: ["PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":")]
        )
    }

    // MARK: - Nombres y textos del bundle

    /// Elige un nombre libre en la carpeta destino. Nunca pisa lo que ya hay: si el usuario
    /// traslada dos veces, se queda con las dos y decide él cuál borra.
    public static func destinationURL(
        for game: GodotGame,
        in folder: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let base = game.suggestedAppName
        var candidate = folder.appendingPathComponent("\(base).app")
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path), attempt < 100 {
            candidate = folder.appendingPathComponent("\(base) \(attempt).app")
            attempt += 1
        }
        return candidate
    }

    public static func infoPlist(for game: GodotGame, displayName: String) -> String {
        let identifier = "com.lever.godot." + game.bundleExecutableName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleDevelopmentRegion</key>
        \t<string>English</string>
        \t<key>CFBundleExecutable</key>
        \t<string>\(game.bundleExecutableName)</string>
        \t<key>CFBundleName</key>
        \t<string>\(escape(displayName))</string>
        \t<key>CFBundleDisplayName</key>
        \t<string>\(escape(displayName))</string>
        \t<key>CFBundleIconFile</key>
        \t<string>icon.icns</string>
        \t<key>CFBundleIdentifier</key>
        \t<string>\(identifier.isEmpty ? "com.lever.godot.game" : identifier)</string>
        \t<key>CFBundleInfoDictionaryVersion</key>
        \t<string>6.0</string>
        \t<key>CFBundlePackageType</key>
        \t<string>APPL</string>
        \t<key>CFBundleShortVersionString</key>
        \t<string>1.0</string>
        \t<key>CFBundleVersion</key>
        \t<string>1.0</string>
        \t<key>CFBundleSignature</key>
        \t<string>????</string>
        \t<key>CFBundleSupportedPlatforms</key>
        \t<array><string>MacOSX</string></array>
        \t<key>NSPrincipalClass</key>
        \t<string>NSApplication</string>
        \t<key>LSApplicationCategoryType</key>
        \t<string>public.app-category.games</string>
        \t<key>LSMinimumSystemVersion</key>
        \t<string>11.0</string>
        \t<key>NSHighResolutionCapable</key>
        \t<true/>
        </dict>
        </plist>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Espacio que hace falta antes de empezar. La plantilla del motor son unos 1,3 GB de
    /// descarga que luego se tiran; el `.pck` no cuenta porque se clona en vez de copiarse.
    public static func requiredBytes(
        for game: GodotGame,
        hasTemplate: Bool,
        buildingExtensions: Bool
    ) -> Int64 {
        let template: Int64 = hasTemplate ? 250_000_000 : 2_000_000_000
        // Compilar FFmpeg desde cero es lo que de verdad pesa, y solo ocurre si se pide.
        let buildable = buildingExtensions
            && game.unresolvedExtensions.contains { NativePartRecipe.recipe(forAddon: $0.addonName) != nil }
        return template + (buildable ? 8_000_000_000 : 0)
    }

    // MARK: - El traslado completo

    public static func makeApp(
        for game: GodotGame,
        into folder: URL,
        buildMissingExtensions: Bool,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        scriptProvider: @Sendable (String) -> URL? = { _ in nil },
        onStage: @Sendable @escaping (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> PortOutcome {
        guard game.isSupported else { throw PortFailure.unsupportedEngine(game.version.description) }

        let template = try await ensureTemplate(
            for: game.version,
            runner: runner,
            session: session,
            library: library,
            fileManager: fileManager,
            onStage: onStage,
            onLine: onLine
        )
        try checkCancelled(session)

        var unresolved: [String] = []
        for addon in game.unresolvedExtensions where addon.declaresMac {
            guard let fileName = addon.macLibraryFileName else { continue }
            if library.url(forLibraryNamed: fileName) != nil { continue }

            guard buildMissingExtensions,
                  let recipe = NativePartRecipe.recipe(forAddon: addon.addonName),
                  let script = scriptProvider(recipe.scriptName) else {
                unresolved.append(addon.addonName)
                continue
            }

            onStage(.buildingPart(recipe.displayName))
            let workshop = fileManager.temporaryDirectory
                .appendingPathComponent("Lever-gdextension-\(UUID().uuidString)", isDirectory: true)
            try? fileManager.createDirectory(at: workshop, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: workshop) }

            let result = try? await runner.run(
                buildExtensionCommand(script: script, output: workshop, architecture: GodotInspector.hostArch),
                session: session,
                onLine: onLine
            )
            try checkCancelled(session)

            let produced = ((try? fileManager.contentsOfDirectory(atPath: workshop.path)) ?? [])
                .filter { $0.hasSuffix(".dylib") }
            for name in produced {
                try? library.store(workshop.appendingPathComponent(name), as: name)
            }
            if result?.succeeded != true || library.url(forLibraryNamed: fileName) == nil {
                unresolved.append(addon.addonName)
            }
        }

        onStage(.assembling)
        let destination = destinationURL(for: game, in: folder, fileManager: fileManager)
        do {
            try assemble(
                game: game,
                template: template,
                at: destination,
                runner: runner,
                session: session,
                library: library,
                fileManager: fileManager,
                onLine: onLine
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw PortFailure.assemblyFailed(error.localizedDescription)
        }
        try checkCancelled(session)

        onStage(.signing)
        await PortSigning.sign(
            app: destination, mainExecutable: game.bundleExecutableName,
            runner: runner, session: session, fileManager: fileManager
        )

        return PortOutcome(app: destination, unresolvedParts: unresolved)
    }

    // MARK: - Plantilla del motor

    private static func ensureTemplate(
        for version: GodotVersion,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onStage: @Sendable (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let cached = library.templateURL(for: version)
        if library.hasTemplate(for: version) { return cached }

        let folder = cached.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        onStage(.downloadingRuntime(version.description))
        let archive = folder.appendingPathComponent("templates.tpz")
        let download = try await runner.run(
            downloadTemplatesCommand(version: version, into: archive),
            session: session,
            onLine: onLine
        )
        try checkCancelled(session)
        guard download.succeeded else {
            try? fileManager.removeItem(at: archive)
            throw PortFailure.downloadFailed(download.exitCode)
        }

        onStage(.unpackingRuntime)
        _ = try? await runner.run(extractMacArchiveCommand(from: archive, into: folder), session: session, onLine: onLine)
        // El `.tpz` trae todas las plataformas y pesa más de un giga. Fuera en cuanto se saca
        // la de macOS, que es lo único que se guarda.
        try? fileManager.removeItem(at: archive)

        let macArchive = folder.appendingPathComponent("macos.zip")
        guard fileManager.fileExists(atPath: macArchive.path) else { throw PortFailure.runtimeMissing }
        _ = try? await runner.run(unzipCommand(macArchive, into: folder), session: session, onLine: onLine)
        try? fileManager.removeItem(at: macArchive)

        guard library.hasTemplate(for: version) else { throw PortFailure.runtimeMissing }
        return cached
    }

    // MARK: - Montaje del bundle

    private static func assemble(
        game: GodotGame,
        template: URL,
        at destination: URL,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) throws {
        let contents = destination.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        // Motor.
        let source = template.appendingPathComponent("Contents/MacOS/godot_macos_release.universal")
        let binary = macOS.appendingPathComponent(game.bundleExecutableName)
        try runSynchronously(thinCommand(binary: source, architecture: GodotInspector.hostArch, output: binary))
        if !fileManager.fileExists(atPath: binary.path) {
            // Si la plantilla ya venía de una sola arquitectura, `lipo -thin` falla; copiarla vale.
            try fileManager.copyItem(at: source, to: binary)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // Datos del juego. Godot los busca por el nombre del ejecutable, no por el del bundle.
        let pack = resources.appendingPathComponent("\(game.bundleExecutableName).pck")
        switch game.pack {
        case .sibling(let url):
            try runSynchronously(cloneCommand(from: url, to: pack))
            if !fileManager.fileExists(atPath: pack.path) { try fileManager.copyItem(at: url, to: pack) }
        case .embedded(let url, let offset):
            try copyBytes(from: url, startingAt: offset, to: pack)
        }

        // Ficha del bundle e icono.
        let name = game.projectName.map { $0.isEmpty ? game.suggestedAppName : $0 } ?? game.suggestedAppName
        try Data(infoPlist(for: game, displayName: name).utf8)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        makeIcon(for: game, at: resources.appendingPathComponent("icon.icns"), fileManager: fileManager)

        // Complementos nativos. La ruta relativa se conserva entera: `dlopen` prueba
        // `Contents/Frameworks/` + la ruta que pide el `.gdextension`, no solo el nombre.
        for addon in game.extensions {
            guard let relative = addon.macLibraryPath?.replacingOccurrences(of: "res://", with: ""),
                  let fileName = addon.macLibraryFileName else { continue }
            let stored = library.url(forLibraryNamed: fileName)
                ?? besideExecutable(fileName, for: game, fileManager: fileManager)
            guard let stored else { continue }

            let target = contents.appendingPathComponent("Frameworks").appendingPathComponent(relative)
            try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: stored, to: target)
            onLine("+ \(fileName)")
        }
    }

    private static func besideExecutable(
        _ fileName: String,
        for game: GodotGame,
        fileManager: FileManager
    ) -> URL? {
        let candidate = game.executable.deletingLastPathComponent().appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Saca el paquete incrustado del `.exe` copiando el tramo de bytes, sin cargarlo entero:
    /// hay juegos de varios gigas en un solo archivo.
    private static func copyBytes(from source: URL, startingAt offset: UInt64, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let total = try input.seekToEnd()
        guard offset < total else { throw CocoaError(.fileReadCorruptFile) }
        // Los últimos doce bytes son el pie que marca dónde empieza el paquete, no datos.
        var remaining = total - offset - 12

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try input.seek(toOffset: offset)

        let chunk = 8 * 1024 * 1024
        while remaining > 0 {
            let size = Int(min(UInt64(chunk), remaining))
            guard let data = try input.read(upToCount: size), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    /// El icono es un detalle: si algo falla, el juego se abre igual con el icono genérico.
    private static func makeIcon(for game: GodotGame, at destination: URL, fileManager: FileManager) {
        guard let iconPath = game.iconPath?.replacingOccurrences(of: "res://", with: ""),
              iconPath.lowercased().hasSuffix(".png") else { return }

        let workshop = fileManager.temporaryDirectory
            .appendingPathComponent("Lever-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = workshop.appendingPathComponent("icon.iconset", isDirectory: true)
        try? fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workshop) }

        let original = workshop.appendingPathComponent("icon.png")
        guard GodotInspector.extract(path: iconPath, from: game, to: original) else { return }

        // `iconutil` solo acepta esta lista exacta de nombres: uno de más y falla el conjunto
        // entero. Los `@2x` son los mismos píxeles del tamaño doble, con otro nombre.
        let variants: [(pixels: Int, names: [String])] = [
            (16, ["icon_16x16"]),
            (32, ["icon_16x16@2x", "icon_32x32"]),
            (64, ["icon_32x32@2x"]),
            (128, ["icon_128x128"]),
            (256, ["icon_128x128@2x", "icon_256x256"]),
            (512, ["icon_256x256@2x", "icon_512x512"]),
            (1024, ["icon_512x512@2x"])
        ]
        for variant in variants {
            guard let first = variant.names.first else { continue }
            let single = iconset.appendingPathComponent("\(first).png")
            try? runSynchronously(ProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/sips"),
                arguments: ["-z", "\(variant.pixels)", "\(variant.pixels)", original.path, "--out", single.path],
                currentDirectoryURL: nil
            ))
            for extra in variant.names.dropFirst() {
                try? fileManager.copyItem(at: single, to: iconset.appendingPathComponent("\(extra).png"))
            }
        }
        try? runSynchronously(ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/iconutil"),
            arguments: ["-c", "icns", iconset.path, "-o", destination.path],
            currentDirectoryURL: nil
        ))
    }


    private static func checkCancelled(_ session: ProcessSession) throws {
        if session.isCancelled { throw PortFailure.cancelled }
    }

    /// Para las órdenes cortas del montaje, donde esperar es más simple que encadenar `await`.
    private static func runSynchronously(_ command: ProcessCommand) throws {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}
