import Foundation

/// Convierte un juego de NW.js repartido para Windows en un `.app` de macOS.
///
/// El molde es el `nwjs.app` que publica NW.js. El juego entero va en
/// `Contents/Resources/app.nw/`, que es donde el motor lo busca sin que haya que decirle nada.
public enum NwjsPorter {
    // MARK: - Ficha del bundle

    /// Ajusta el `Info.plist` del motor para que sea el de este juego.
    public static func infoPlist(
        from original: Data,
        game: NwjsGame,
        displayName: String,
        hasCustomIcon: Bool
    ) -> Data? {
        guard var plist = (try? PropertyListSerialization.propertyList(from: original, format: nil))
            as? [String: Any] else { return nil }

        plist["CFBundleExecutable"] = game.bundleExecutableName
        plist["CFBundleIdentifier"] = identifier(for: game)
        plist["CFBundleName"] = displayName
        plist["CFBundleDisplayName"] = displayName

        // NW.js es un navegador, y su ficha lo declara: se ofrece a abrir GIF, HTML, XHTML y
        // JavaScript, y registra esquemas de URL. Un juego no abre nada de eso; dejarlo puesto lo
        // mete en el «Abrir con» de media biblioteca y le da un papel que no tiene.
        plist.removeValue(forKey: "CFBundleDocumentTypes")
        plist.removeValue(forKey: "CFBundleURLTypes")

        if hasCustomIcon {
            plist["CFBundleIconFile"] = "icon"
            plist.removeValue(forKey: "CFBundleIconName")
        }

        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func identifier(for game: NwjsGame) -> String {
        let slug = game.bundleExecutableName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "com.lever.nwjs.juego" : "com.lever.nwjs." + slug
    }

    // MARK: - El traslado completo

    public static func makeApp(
        for game: NwjsGame,
        into folder: URL,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        onStage: @Sendable @escaping (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> PortOutcome {
        guard game.isSupported else { throw PortFailure.unsupportedEngine(game.version) }

        let engine = try await ensureRuntime(
            for: game, runner: runner, session: session,
            library: library, fileManager: fileManager, onStage: onStage, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.assembling)
        let destination = PortPaths.freeAppURL(named: game.suggestedAppName, in: folder, fileManager: fileManager)
        do {
            try assemble(game: game, engine: engine, at: destination, fileManager: fileManager, onLine: onLine)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw PortFailure.assemblyFailed(error.localizedDescription)
        }
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.signing)
        await PortSigning.signNested(app: destination, runner: runner, session: session)

        return PortOutcome(app: destination, unresolvedParts: game.windowsModules)
    }

    /// Deja disponible el `nwjs.app` de esa versión y arquitectura.
    private static func ensureRuntime(
        for game: NwjsGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onStage: @Sendable (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let cached = library.nwjsRuntimeURL(version: game.runtimeVersionText)
        let engine = cached.appendingPathComponent("nwjs.app", isDirectory: true)
        if library.hasNwjsRuntime(version: game.runtimeVersionText) { return engine }

        try? fileManager.createDirectory(at: cached, withIntermediateDirectories: true)

        onStage(.downloadingRuntime(game.runtimeVersionText))
        let archive = cached.appendingPathComponent("nwjs.zip")
        let download = try await runner.run(
            PortCommands.download(game.macDownloadURL, into: archive), session: session, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }
        guard download.succeeded else {
            try? fileManager.removeItem(at: archive)
            throw PortFailure.downloadFailed(download.exitCode)
        }

        onStage(.unpackingRuntime)
        _ = try? await runner.run(PortCommands.unzip(archive, into: cached), session: session, onLine: onLine)
        try? fileManager.removeItem(at: archive)

        // El ZIP mete el `nwjs.app` dentro de una carpeta con el nombre de la versión: se aplana
        // para que la caché quede igual venga de donde venga.
        if !fileManager.fileExists(atPath: engine.path),
           let suelto = findApp(inside: cached, fileManager: fileManager) {
            try? fileManager.moveItem(at: suelto, to: engine)
            try? fileManager.removeItem(at: suelto.deletingLastPathComponent())
        }

        guard library.hasNwjsRuntime(version: game.runtimeVersionText) else { throw PortFailure.runtimeMissing }
        return engine
    }

    private static func findApp(inside folder: URL, fileManager: FileManager) -> URL? {
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let candidate = folder.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("nwjs.app", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Montaje

    private static func assemble(
        game: NwjsGame,
        engine: URL,
        at destination: URL,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) throws {
        try clone(from: engine, to: destination)
        guard fileManager.fileExists(atPath: destination.path) else { throw PortFailure.runtimeMissing }

        let contents = destination.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")

        // El binario se renombra al nombre del juego para que el Dock y el diálogo de forzar
        // salida no digan «nwjs». Chromium relanza sus procesos hijos por la ruta del ejecutable,
        // que sigue siendo válida.
        let launcher = contents.appendingPathComponent("MacOS/\(game.bundleExecutableName)")
        if launcher.lastPathComponent != "nwjs" {
            try? fileManager.removeItem(at: launcher)
            try fileManager.moveItem(at: contents.appendingPathComponent("MacOS/nwjs"), to: launcher)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        // El juego entero, sin los binarios de Windows.
        let payload = resources.appendingPathComponent("app.nw", isDirectory: true)
        try? fileManager.removeItem(at: payload)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        for entry in game.gameEntries {
            try clone(from: game.root.appendingPathComponent(entry), to: payload.appendingPathComponent(entry))
        }

        let iconMade = makeIcon(game: game, payload: payload,
                                at: resources.appendingPathComponent("icon.icns"), fileManager: fileManager)

        let plistURL = contents.appendingPathComponent("Info.plist")
        guard let original = try? Data(contentsOf: plistURL),
              let patched = infoPlist(from: original, game: game,
                                      displayName: game.suggestedAppName, hasCustomIcon: iconMade) else {
            throw PortFailure.assemblyFailed("Info.plist")
        }
        try patched.write(to: plistURL)

        if game.engineWasReplaced {
            onLine("+ \(game.bundleExecutableName) (NW.js \(game.runtimeVersion), no la \(game.version) que traía)")
        } else {
            onLine("+ \(game.bundleExecutableName) (NW.js \(game.version))")
        }
        for module in game.windowsModules {
            onLine("· \(module): solo existe para Windows")
        }
    }

    /// El icono del `.app` sale del que el juego declara para su ventana en `package.json`.
    private static func makeIcon(
        game: NwjsGame,
        payload: URL,
        at destination: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let relative = game.manifest.icon, !relative.isEmpty else { return false }
        let image = payload.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: image.path) else { return false }
        PortPaths.makeIcon(from: image, at: destination, fileManager: fileManager)
        return fileManager.fileExists(atPath: destination.path)
    }

    /// Copia clonando en APFS: un juego de RPG Maker son cientos de megas en miles de archivos y
    /// duplicarlos en disco no aporta nada.
    private static func clone(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-Rc", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }
}
