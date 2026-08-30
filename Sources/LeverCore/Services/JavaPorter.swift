import Foundation

/// Convierte un juego de Java repartido para Windows en un `.app` de macOS.
///
/// Es el único de los cinco motores sin un `.app` de plantilla que copiar: Java no reparte uno, así
/// que el bundle se arma entero. A cambio es el traslado más limpio, porque el bytecode ya es
/// portable y no hay que tocar ni una clase del juego. Lo de Windows son tres cosas: el lanzador
/// nativo —que se tira—, el `jre/` —que se sustituye por uno de Mac— y los binarios de las
/// librerías nativas —que se cambian uno a uno por los que el propio proyecto publica—.
public enum JavaPorter {
    // MARK: - Ficha del bundle

    public static func infoPlist(for game: JavaGame, displayName: String, hasCustomIcon: Bool) -> Data? {
        var plist: [String: Any] = [
            "CFBundleExecutable": displayName,
            "CFBundleIdentifier": identifier(for: game),
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            // Sin esto la ventana sale escalada y borrosa en una pantalla Retina.
            "NSHighResolutionCapable": true
        ]
        if hasCustomIcon { plist["CFBundleIconFile"] = "icon" }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func identifier(for game: JavaGame) -> String {
        let slug = game.suggestedAppName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "com.lever.java.juego" : "com.lever.java." + slug
    }

    /// El guion que arranca el juego, que es lo que macOS ejecuta al abrir el `.app`.
    ///
    /// Un guion puede ser el ejecutable de un bundle y aguanta la firma: comprobado con
    /// `codesign --deep` y abriéndolo desde el Finder. Lo que no es opcional es el `exec`:
    /// `-XstartOnFirstThread` exige que la máquina virtual sea el primer hilo del proceso, y eso
    /// solo se cumple si sustituye al shell en vez de colgar de él.
    public static func launcherScript(for game: JavaGame, classPath: [String]) -> String {
        let banderas = game.needsMainThreadFlag ? " -XstartOnFirstThread" : ""
        let ruta = classPath.map { "$aqui/\($0)" }.joined(separator: ":")
        return """
        #!/bin/sh
        aqui="$(cd "$(dirname "$0")/../Resources" && pwd)"
        # El juego busca sus datos por rutas relativas, como cuando lo lanzaba su .exe desde la
        # carpeta del juego. Sin esto no encuentra ni sus texturas ni su configuración.
        cd "$aqui" || exit 1
        exec "$aqui/jre/Contents/Home/bin/java"\(banderas) \\
            -cp "\(ruta)" \\
            \(game.mainClass) "$@"

        """
    }

    // MARK: - El traslado completo

    public static func makeApp(
        for game: JavaGame,
        into folder: URL,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        onStage: @Sendable @escaping (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> PortOutcome {
        guard let runtime = game.runtime else { throw PortFailure.unsupportedEngine(game.version) }

        let jre = try await ensureRuntime(
            for: game, feature: runtime, runner: runner, session: session,
            library: library, fileManager: fileManager, onStage: onStage, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }

        let natives = try await ensureNatives(
            for: game, runner: runner, session: session,
            library: library, fileManager: fileManager, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.assembling)
        let destination = PortPaths.freeAppURL(named: game.suggestedAppName, in: folder, fileManager: fileManager)
        do {
            try assemble(game: game, jre: jre, natives: natives,
                         at: destination, fileManager: fileManager, onLine: onLine)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw PortFailure.assemblyFailed(error.localizedDescription)
        }
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.signing)
        await PortSigning.signNested(app: destination, runner: runner, session: session)

        return PortOutcome(app: destination, unresolvedParts: game.windowsLibraries)
    }

    /// Deja disponible el JRE de Temurin de esa versión y arquitectura.
    private static func ensureRuntime(
        for game: JavaGame,
        feature: JavaFeature,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onStage: @Sendable (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let arquitectura = game.architecture
        let destino = library.javaRuntimeURL(feature: feature.description, architecture: arquitectura)
        if library.hasJavaRuntime(feature: feature.description, architecture: arquitectura) { return destino }

        try? fileManager.createDirectory(at: destino, withIntermediateDirectories: true)
        onStage(.downloadingRuntime(feature.description))
        let archivo = destino.appendingPathComponent("jre.tar.gz")
        let descarga = try await runner.run(
            PortCommands.download(feature.macDownloadURL(appleSilicon: game.appleSilicon), into: archivo),
            session: session, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }
        guard descarga.succeeded else {
            try? fileManager.removeItem(at: archivo)
            throw PortFailure.downloadFailed(descarga.exitCode)
        }

        onStage(.unpackingRuntime)
        _ = try? await runner.run(PortCommands.untar(archivo, into: destino), session: session, onLine: onLine)
        try? fileManager.removeItem(at: archivo)

        // El tar trae una carpeta con el nombre completo de la versión —`jdk-17.0.20.1+1-jre`—
        // dentro de la cual está el bundle. Se aplana para que la caché quede igual venga de donde
        // venga y no haya que adivinar ese nombre después.
        if !fileManager.fileExists(atPath: destino.appendingPathComponent("Contents/Home/bin/java").path) {
            for nombre in (try? fileManager.contentsOfDirectory(atPath: destino.path)) ?? [] {
                let dentro = destino.appendingPathComponent(nombre, isDirectory: true)
                guard fileManager.fileExists(atPath: dentro.appendingPathComponent("Contents/Home/bin/java").path)
                else { continue }
                for pieza in (try? fileManager.contentsOfDirectory(atPath: dentro.path)) ?? [] {
                    try? fileManager.moveItem(at: dentro.appendingPathComponent(pieza),
                                              to: destino.appendingPathComponent(pieza))
                }
                try? fileManager.removeItem(at: dentro)
                break
            }
        }

        guard library.hasJavaRuntime(feature: feature.description, architecture: arquitectura) else {
            throw PortFailure.runtimeMissing
        }
        return destino
    }

    /// Deja bajados los jars de nativos de macOS, uno por cada jar de Windows que trae el juego.
    ///
    /// El trabajo de mirar la caché y bajar lo que falte lo hace `NativeParts`, que es común a
    /// todos los motores. Lo único de aquí es armar la identidad de la parte: para LWJGL no entra
    /// ABI ninguno —eso es cosa de Node—, pero sí la versión, que tiene que ser exacta porque
    /// LWJGL comprueba que los bindings y los binarios coincidan.
    private static func ensureNatives(
        for game: JavaGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> [(natives: LwjglNatives, jar: URL)] {
        var listos: [(natives: LwjglNatives, jar: URL)] = []
        for nativo in game.lwjgl {
            let parte = NativePart(
                name: nativo.module,
                version: nativo.version,
                platform: game.appleSilicon ? "macos-arm64" : "macos",
                abi: nil,
                download: nativo.macDownloadURL(appleSilicon: game.appleSilicon),
                fileName: nativo.macAssetName(appleSilicon: game.appleSilicon)
            )
            let resultado = try await NativeParts.obtain(
                parte, runner: runner, session: session, library: library,
                fileManager: fileManager, onLine: onLine
            )
            if let jar = resultado.file {
                listos.append((nativo, jar))
            } else {
                onLine("· \(parte.label): no hay binarios de macOS publicados")
            }
        }
        return listos
    }

    // MARK: - Montaje

    private static func assemble(
        game: JavaGame,
        jre: URL,
        natives: [(natives: LwjglNatives, jar: URL)],
        at destination: URL,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) throws {
        let contents = destination.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        // El juego entero, menos el `.exe` y el `jre/` de Windows.
        for entry in game.gameEntries {
            try clone(from: game.root.appendingPathComponent(entry),
                      to: resources.appendingPathComponent(entry))
        }

        // El jar que arranca. Si venía pegado detrás del lanzador de Launch4j hay que sacarlo: el
        // lanzador es de Windows y no viaja, pero el jar empieza en un desplazamiento conocido y
        // sus índices internos son relativos a ese principio, así que recortarlo da un jar válido.
        let launchJarName: String
        switch game.launchJar {
        case .fused(let exe, let offset):
            launchJarName = game.suggestedAppName + ".jar"
            try extractJar(from: exe, offset: offset, to: resources.appendingPathComponent(launchJarName))
        case .sibling(let jar):
            launchJarName = jar.lastPathComponent
        }

        // Los nativos: fuera el de Windows, dentro el de macOS con su nombre de verdad. El
        // classpath del guion los nombra uno a uno, así que la entrada que queda colgando en el
        // `Class-Path` del manifiesto da igual: una entrada que no existe se ignora sin ruido.
        var cambiados: [LwjglNatives] = []
        var sinCambiar: [LwjglNatives] = []
        for (nativo, jar) in natives {
            let viejo = resources.appendingPathComponent(nativo.relativePath)
            guard fileManager.fileExists(atPath: viejo.path) else { sinCambiar.append(nativo); continue }
            try fileManager.removeItem(at: viejo)
            let nuevo = viejo.deletingLastPathComponent()
                .appendingPathComponent(nativo.macAssetName(appleSilicon: game.appleSilicon))
            try fileManager.copyItem(at: jar, to: nuevo)
            cambiados.append(nativo)
        }

        try clone(from: jre, to: resources.appendingPathComponent("jre"))
        guard fileManager.fileExists(atPath: resources.appendingPathComponent("jre/Contents/Home/bin/java").path)
        else { throw PortFailure.runtimeMissing }

        let classPath = [launchJarName] + otherJars(in: resources, except: launchJarName, fileManager: fileManager)
        let guion = macOS.appendingPathComponent(game.suggestedAppName)
        try launcherScript(for: game, classPath: classPath).write(to: guion, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guion.path)

        let icono = makeIcon(game: game, at: resources.appendingPathComponent("icon.icns"),
                             fileManager: fileManager)
        guard let plist = infoPlist(for: game, displayName: game.suggestedAppName, hasCustomIcon: icono) else {
            throw PortFailure.assemblyFailed("Info.plist")
        }
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        onLine("+ \(game.suggestedAppName) (Java \(game.runtimeVersionText), \(game.architecture))")
        for nativo in cambiados {
            onLine("· \(nativo.module) \(nativo.version): cambiado por el de macOS")
        }
        // Se dice, no se calla: si el jar de Windows no aparece donde el inspector lo vio, el
        // juego arrancará y morirá en el primer `UnsatisfiedLinkError`.
        for nativo in sinCambiar {
            onLine("· \(nativo.module): no se encontró su jar de Windows en el reparto")
        }
        for libreria in game.windowsLibraries {
            onLine("· \(libreria): solo existe para Windows")
        }
    }

    /// Todos los demás jars del bundle, para nombrarlos en el classpath.
    ///
    /// Se nombran uno a uno en vez de fiarse del `Class-Path` del manifiesto porque no todos los
    /// juegos lo traen: muchos repartos dejan esa lista en el `.bat` o en la configuración de
    /// Launch4j, que son de Windows y no viajan.
    private static func otherJars(in resources: URL, except launcher: String,
                                  fileManager: FileManager) -> [String] {
        guard let walker = fileManager.enumerator(
            at: resources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            // El JRE trae sus propios jars dentro y no pintan nada en el classpath del juego.
            if url.lastPathComponent == "jre", url.hasDirectoryPath { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "jar",
                  let relativa = PortPaths.relativePath(of: url, from: resources) else { continue }
            if relativa != launcher { found.append(relativa) }
        }
        return found.sorted()
    }

    private static func extractJar(from exe: URL, offset: UInt64, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: exe)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try (handle.readToEnd() ?? Data()).write(to: destination)
    }

    /// Un icono, si el juego dejó uno reconocible al lado. El de verdad va dentro del `.exe`, en
    /// los recursos del PE, y sacarlo de ahí es otro trabajo: mejor sin icono que con uno inventado.
    private static func makeIcon(game: JavaGame, at destination: URL, fileManager: FileManager) -> Bool {
        let base = game.executable.deletingPathExtension().lastPathComponent
        for nombre in ["\(base).png", "icon.png", "icono.png", "logo.png"] {
            let imagen = game.root.appendingPathComponent(nombre)
            guard fileManager.fileExists(atPath: imagen.path) else { continue }
            PortPaths.makeIcon(from: imagen, at: destination, fileManager: fileManager)
            if fileManager.fileExists(atPath: destination.path) { return true }
        }
        return false
    }

    /// Copia clonando en APFS: un JRE son ciento treinta megas en miles de archivos.
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
