import Foundation

/// Convierte un juego de Ren'Py exportado para Windows en un `.app` de macOS.
///
/// La estructura no está inventada: es la misma que produce el propio Ren'Py al exportar para
/// Mac. Los binarios van en `Contents/MacOS/` con el intérprete renombrado al nombre del juego,
/// la biblioteca de Python en `Contents/Resources/lib/` y todo lo demás en
/// `Contents/Resources/autorun/`, que es donde Ren'Py busca el juego cuando corre dentro de un
/// bundle. La carpeta `lib/py3-windows-x86_64` se queda fuera: son 48 MB que aquí no pintan nada.
public enum RenpyPorter {
    // MARK: - Órdenes sueltas

    public static func downloadSDKCommand(for game: RenpyGame, into file: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-L", "--fail", "--progress-bar", "-o", file.path, game.sdkURL.absoluteString],
            currentDirectoryURL: nil
        )
    }

    /// Del SDK entero solo hacen falta los binarios de macOS: unos 70 MB de los 600 que ocupa
    /// descomprimido. Se extrae solo esa carpeta.
    public static func extractMacLibraryCommand(sdk: URL, version: String, into folder: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", "-o", sdk.path, "renpy-\(version)-sdk/lib/*mac*/*", "-d", folder.path],
            currentDirectoryURL: nil
        )
    }

    // MARK: - Textos del bundle

    public static func infoPlist(for game: RenpyGame, displayName: String) -> String {
        let identifier = "com.lever.renpy." + game.bundleExecutableName
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
        \t<string>icon</string>
        \t<key>CFBundleIdentifier</key>
        \t<string>\(identifier.isEmpty ? "com.lever.renpy.game" : identifier)</string>
        \t<key>CFBundleInfoDictionaryVersion</key>
        \t<string>6.0</string>
        \t<key>CFBundlePackageType</key>
        \t<string>APPL</string>
        \t<key>CFBundleShortVersionString</key>
        \t<string>1.0</string>
        \t<key>CFBundleVersion</key>
        \t<string>1.0</string>
        \t<key>CFBundleSupportedPlatforms</key>
        \t<array><string>MacOSX</string></array>
        \t<key>NSPrincipalClass</key>
        \t<string>NSApplication</string>
        \t<key>LSApplicationCategoryType</key>
        \t<string>public.app-category.simulation-games</string>
        \t<key>NSHighResolutionCapable</key>
        \t<true/>
        \t<key>NSSupportsAutomaticGraphicsSwitching</key>
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

    // MARK: - El traslado completo

    public static func makeApp(
        for game: RenpyGame,
        into folder: URL,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        onStage: @Sendable @escaping (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> PortOutcome {
        guard game.isSupported else { throw PortFailure.unsupportedEngine(game.version) }

        let macLibrary = try await ensureRuntime(
            for: game, runner: runner, session: session,
            library: library, fileManager: fileManager, onStage: onStage, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.assembling)
        let destination = PortPaths.freeAppURL(named: game.suggestedAppName, in: folder, fileManager: fileManager)
        do {
            try assemble(game: game, macLibrary: macLibrary, at: destination, fileManager: fileManager, onLine: onLine)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw PortFailure.assemblyFailed(error.localizedDescription)
        }
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.signing)
        await PortSigning.sign(
            app: destination, mainExecutable: game.bundleExecutableName,
            runner: runner, session: session, fileManager: fileManager
        )

        return PortOutcome(app: destination, unresolvedParts: [])
    }

    /// Deja disponible la carpeta con los binarios de macOS de esa versión exacta.
    private static func ensureRuntime(
        for game: RenpyGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onStage: @Sendable (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        // Los paquetes «market» y «steam» traen las tres plataformas: si el juego ya los lleva,
        // no hay nada que descargar.
        if game.carriesMacRuntime,
           let existing = macLibraryFolder(inside: game.root.appendingPathComponent("lib"), fileManager: fileManager) {
            onLine("Los binarios de macOS ya venían en el juego.")
            return existing
        }

        let cached = library.renpyRuntimeURL(version: game.sdkVersion)
        if let existing = macLibraryFolder(inside: cached, fileManager: fileManager) { return existing }

        try? fileManager.createDirectory(at: cached, withIntermediateDirectories: true)

        onStage(.downloadingRuntime(game.sdkVersion))
        let archive = cached.appendingPathComponent("sdk.zip")
        let download = try await runner.run(downloadSDKCommand(for: game, into: archive), session: session, onLine: onLine)
        if session.isCancelled { throw PortFailure.cancelled }
        guard download.succeeded else {
            try? fileManager.removeItem(at: archive)
            throw PortFailure.downloadFailed(download.exitCode)
        }

        onStage(.unpackingRuntime)
        _ = try? await runner.run(
            extractMacLibraryCommand(sdk: archive, version: game.sdkVersion, into: cached),
            session: session, onLine: onLine
        )
        // El SDK entero pesa 160 MB comprimidos y solo se usan los binarios: fuera en cuanto
        // están extraídos.
        try? fileManager.removeItem(at: archive)

        // `unzip` conserva la ruta interna `renpy-X.Y.Z-sdk/lib/...`; se aplana para que la caché
        // quede igual venga de donde venga.
        let unpacked = cached.appendingPathComponent("renpy-\(game.sdkVersion)-sdk/lib")
        if let found = macLibraryFolder(inside: unpacked, fileManager: fileManager) {
            let flattened = cached.appendingPathComponent(found.lastPathComponent)
            try? fileManager.removeItem(at: flattened)
            try? fileManager.moveItem(at: found, to: flattened)
            try? fileManager.removeItem(at: cached.appendingPathComponent("renpy-\(game.sdkVersion)-sdk"))
        }

        guard let ready = macLibraryFolder(inside: cached, fileManager: fileManager) else {
            throw PortFailure.runtimeMissing
        }
        return ready
    }

    private static func macLibraryFolder(inside folder: URL, fileManager: FileManager) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }
        guard let name = names.first(where: { RenpyInspector.isMacLibraryFolder($0) }) else { return nil }
        let candidate = folder.appendingPathComponent(name, isDirectory: true)
        // Tiene que traer el intérprete: una carpeta vacía con el nombre correcto no vale.
        let hasInterpreter = ["renpy", "python", "pythonw"].contains {
            fileManager.fileExists(atPath: candidate.appendingPathComponent($0).path)
        }
        return hasInterpreter ? candidate : nil
    }

    // MARK: - Montaje

    private static func assemble(
        game: RenpyGame,
        macLibrary: URL,
        at destination: URL,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) throws {
        let contents = destination.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        let autorun = resources.appendingPathComponent("autorun")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: autorun, withIntermediateDirectories: true)

        // 1. Binarios del intérprete. El ejecutable `renpy` se renombra al nombre del juego,
        //    exactamente como hace Ren'Py: es lo que espera el `CFBundleExecutable`.
        for name in (try? fileManager.contentsOfDirectory(atPath: macLibrary.path)) ?? [] {
            let source = macLibrary.appendingPathComponent(name)
            let target = macOS.appendingPathComponent(name == "renpy" ? game.bundleExecutableName : name)
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: source, to: target)
        }
        let launcher = macOS.appendingPathComponent(game.bundleExecutableName)
        guard fileManager.fileExists(atPath: launcher.path) else {
            throw PortFailure.runtimeMissing
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        // 2. El juego. Todo menos `lib/`, que se reparte aparte.
        for name in (try? fileManager.contentsOfDirectory(atPath: game.root.path)) ?? [] {
            guard name != "lib", !name.hasPrefix("."), !name.hasSuffix(".app") else { continue }
            try cloneItem(at: game.root.appendingPathComponent(name),
                          to: autorun.appendingPathComponent(name),
                          fileManager: fileManager)
        }

        // 3. La biblioteca de Python compartida va fuera de `autorun`, como en el molde oficial.
        if let pythonLibrary = game.pythonLibraryName {
            let source = game.root.appendingPathComponent("lib/\(pythonLibrary)")
            let target = resources.appendingPathComponent("lib/\(pythonLibrary)")
            try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cloneItem(at: source, to: target, fileManager: fileManager)
        }

        // 4. Ficha e icono.
        try Data(infoPlist(for: game, displayName: game.suggestedAppName).utf8)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        if let icon = game.iconRelativePath {
            PortPaths.makeIcon(from: game.root.appendingPathComponent(icon),
                               at: resources.appendingPathComponent("icon.icns"),
                               fileManager: fileManager)
        }
        onLine("+ \(game.bundleExecutableName) (Ren'Py \(game.version))")
    }

    /// Copia clonando en APFS: un juego de Ren'Py son cientos de megas de `.rpa` y no tiene
    /// sentido duplicarlos en disco.
    private static func cloneItem(at source: URL, to target: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-Rc", source.path, target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.copyItem(at: source, to: target)
        }
    }
}
