import Foundation

/// Convierte un juego de LÖVE repartido para Windows en un `.app` de macOS.
///
/// El molde no está inventado: es el `love.app` que publica el propio LÖVE, con el `.love` dentro
/// de `Contents/Resources/`. Ahí lo encuentra solo —`getLoveInResources()` pide al bundle
/// cualquier archivo con extensión `.love` y lo mete como primer argumento junto a `--fused`—,
/// así que el nombre del archivo da igual y no hace falta tocar ni una línea del motor.
public enum LovePorter {
    // MARK: - Órdenes sueltas

    public static func downloadEngineCommand(for game: LoveGame, into file: URL) -> ProcessCommand {
        PortCommands.download(game.engineVersion.macDownloadURL, into: file)
    }

    // MARK: - Ficha del bundle

    /// Ajusta el `Info.plist` del motor para que sea el de este juego.
    ///
    /// Se parte del que trae LÖVE en vez de escribir uno nuevo: lleva claves que importan y que
    /// no se ven —la firma `LoVe`, el nombre del icono dentro del catálogo, el mínimo de macOS—
    /// y reescribirlas de memoria es la forma segura de olvidarse de una.
    public static func infoPlist(
        from original: Data,
        game: LoveGame,
        displayName: String,
        hasCustomIcon: Bool
    ) -> Data? {
        guard var plist = (try? PropertyListSerialization.propertyList(from: original, format: nil))
            as? [String: Any] else { return nil }

        plist["CFBundleExecutable"] = game.bundleExecutableName
        plist["CFBundleIdentifier"] = identifier(for: game)
        plist["CFBundleName"] = displayName
        plist["CFBundleDisplayName"] = displayName

        // El motor viene preparado para ser el LÖVE de escritorio: se declara dueño del tipo
        // `.love` y editor de cualquier documento, que es lo que le hace salir en «Abrir con» de
        // todo. Un juego trasladado no puede abrir nada de eso —`get_app_arguments` solo mira los
        // archivos soltados encima *cuando no hay* un `.love` dentro del bundle, y aquí siempre lo
        // hay—, así que declararlo sería mentir y además pelearse con los demás juegos por el tipo.
        plist.removeValue(forKey: "UTExportedTypeDeclarations")
        plist.removeValue(forKey: "CFBundleDocumentTypes")

        if hasCustomIcon {
            plist["CFBundleIconFile"] = "icon"
            // `CFBundleIconName` resuelve contra el catálogo compilado y gana al `.icns`: si se
            // queda, el icono del juego no se llega a ver nunca.
            plist.removeValue(forKey: "CFBundleIconName")
        }

        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func identifier(for game: LoveGame) -> String {
        let slug = game.bundleExecutableName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "com.lever.love.juego" : "com.lever.love." + slug
    }

    /// Ruta del icono de ventana dentro del `.love`, tal como la declara `conf.lua`.
    ///
    /// LÖVE no tiene icono de aplicación: el que pone el desarrollador es el de la ventana, un
    /// PNG dentro del propio juego. Sirve igual para el `.app`, y si no lo hay queda el corazón
    /// de LÖVE, que ya viene en el catálogo del motor.
    public static func windowIconPath(inConf text: String) -> String? {
        // Fuera los comentarios de Lua: un `-- t.window.icon = "viejo.png"` no cuenta.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "--") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")

        let pattern = #"\bicon\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let range = Range(match.range(at: 1), in: code) else { return nil }
        return String(code[range])
    }

    // MARK: - El traslado completo

    public static func makeApp(
        for game: LoveGame,
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
        await PortSigning.sign(
            app: destination, mainExecutable: game.bundleExecutableName,
            runner: runner, session: session, fileManager: fileManager
        )

        return PortOutcome(app: destination, unresolvedParts: game.windowsLibraries)
    }

    /// Deja disponible el `love.app` de esa versión exacta.
    private static func ensureRuntime(
        for game: LoveGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onStage: @Sendable (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let cached = library.loveRuntimeURL(version: game.version)
        let engine = cached.appendingPathComponent("love.app", isDirectory: true)
        if library.hasLoveRuntime(version: game.version) { return engine }

        try? fileManager.createDirectory(at: cached, withIntermediateDirectories: true)

        onStage(.downloadingRuntime(game.version))
        let archive = cached.appendingPathComponent("love.zip")
        let download = try await runner.run(downloadEngineCommand(for: game, into: archive), session: session, onLine: onLine)
        if session.isCancelled { throw PortFailure.cancelled }
        guard download.succeeded else {
            try? fileManager.removeItem(at: archive)
            throw PortFailure.downloadFailed(download.exitCode)
        }

        onStage(.unpackingRuntime)
        _ = try? await runner.run(PortCommands.unzip(archive, into: cached), session: session, onLine: onLine)
        try? fileManager.removeItem(at: archive)

        guard library.hasLoveRuntime(version: game.version) else { throw PortFailure.runtimeMissing }
        return engine
    }

    // MARK: - Montaje

    private static func assemble(
        game: LoveGame,
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
        // salida digan cómo se llama y no «love». Los `rpath` del motor apuntan al bundle, no al
        // nombre del archivo, así que renombrarlo no rompe nada.
        let launcher = contents.appendingPathComponent("MacOS/\(game.bundleExecutableName)")
        if launcher.lastPathComponent != "love" {
            try? fileManager.removeItem(at: launcher)
            try fileManager.moveItem(at: contents.appendingPathComponent("MacOS/love"), to: launcher)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let payload = resources.appendingPathComponent("\(game.bundleExecutableName).love")
        try write(payload: game.payload, to: payload, fileManager: fileManager)

        let iconMade = makeIcon(from: payload, at: resources.appendingPathComponent("icon.icns"),
                                fileManager: fileManager)

        let plistURL = contents.appendingPathComponent("Info.plist")
        guard let original = try? Data(contentsOf: plistURL),
              let patched = infoPlist(from: original, game: game,
                                      displayName: game.suggestedAppName, hasCustomIcon: iconMade) else {
            throw PortFailure.assemblyFailed("Info.plist")
        }
        try patched.write(to: plistURL)

        onLine("+ \(game.bundleExecutableName) (LÖVE \(game.version))")
        for library in game.windowsLibraries {
            onLine("· \(library): solo existe para Windows")
        }
    }

    /// Saca el `.love` de donde esté y lo deja como archivo suelto.
    private static func write(payload: LovePayload, to destination: URL, fileManager: FileManager) throws {
        switch payload {
        case .sibling(let file):
            try? fileManager.removeItem(at: destination)
            try clone(from: file, to: destination)

        case .fused(let executable, let offset):
            // Se copia por trozos: el `.love` de un juego grande son cientos de megas y no tiene
            // sentido tenerlos todos en memoria a la vez.
            guard let reader = try? FileHandle(forReadingFrom: executable) else {
                throw PortFailure.assemblyFailed("no se pudo leer el .exe")
            }
            defer { try? reader.close() }
            fileManager.createFile(atPath: destination.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: destination) else {
                throw PortFailure.assemblyFailed("no se pudo escribir el .love")
            }
            defer { try? writer.close() }

            try reader.seek(toOffset: offset)
            while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
        }
    }

    /// Saca el icono de ventana del `.love` y lo convierte en el del bundle. Devuelve `false` si
    /// el juego no declara ninguno, que es lo normal: entonces se queda el corazón de LÖVE.
    private static func makeIcon(from payload: URL, at destination: URL, fileManager: FileManager) -> Bool {
        let workshop = fileManager.temporaryDirectory
            .appendingPathComponent("Lever-love-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: workshop, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workshop) }

        let conf = workshop.appendingPathComponent("conf.lua")
        PortPaths.run("/usr/bin/unzip", ["-q", "-o", "-j", payload.path, "conf.lua", "-d", workshop.path])
        guard let text = try? String(contentsOf: conf, encoding: .utf8),
              let iconPath = windowIconPath(inConf: text) else { return false }

        PortPaths.run("/usr/bin/unzip", ["-q", "-o", "-j", payload.path, iconPath, "-d", workshop.path])
        let image = workshop.appendingPathComponent((iconPath as NSString).lastPathComponent)
        guard fileManager.fileExists(atPath: image.path) else { return false }

        PortPaths.makeIcon(from: image, at: destination, fileManager: fileManager)
        return fileManager.fileExists(atPath: destination.path)
    }

    /// Copia clonando en APFS: el motor son veinticinco megas y el juego puede ser mucho más.
    private static func clone(from source: URL, to destination: URL) throws {
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
