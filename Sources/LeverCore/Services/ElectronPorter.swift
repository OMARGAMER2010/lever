import Foundation

/// Convierte un juego de Electron repartido para Windows en un `.app` de macOS.
///
/// El molde no está adivinado: se comparó con el que produce `electron-packager` para el mismo
/// juego. Lo que hace es copiar el `Electron.app` del motor, renombrar el ejecutable, **renombrar
/// también los cuatro ayudantes anidados**, reescribir las fichas y poner el `app.asar` del juego
/// donde estaba el de bienvenida.
public enum ElectronPorter {
    // MARK: - Fichas

    public static func infoPlist(
        from original: Data,
        game: ElectronGame,
        displayName: String,
        hasCustomIcon: Bool
    ) -> Data? {
        guard var plist = (try? PropertyListSerialization.propertyList(from: original, format: nil))
            as? [String: Any] else { return nil }

        plist["CFBundleExecutable"] = displayName
        plist["CFBundleIdentifier"] = identifier(for: game)
        plist["CFBundleName"] = displayName
        plist["CFBundleDisplayName"] = displayName

        // `NSPrincipalClass` se queda como está. En un `.app` de Chromium no es `NSApplication`
        // sino una clase suya —aquí `AtomApplication`—, y quitarla deja la app sin nada que
        // arrancar. Es la misma trampa que en NW.js.

        if hasCustomIcon {
            plist["CFBundleIconFile"] = "icon"
            plist.removeValue(forKey: "CFBundleIconName")
        }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// La ficha de un ayudante: el mismo cambio de nombre, y el identificador colgando del de la
    /// app para que no haya dos procesos distintos diciendo llamarse igual.
    public static func helperPlist(from original: Data, helperName: String, appIdentifier: String) -> Data? {
        guard var plist = (try? PropertyListSerialization.propertyList(from: original, format: nil))
            as? [String: Any] else { return nil }
        plist["CFBundleExecutable"] = helperName
        plist["CFBundleName"] = helperName
        plist["CFBundleDisplayName"] = helperName
        plist["CFBundleIdentifier"] = appIdentifier + ".helper"
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func identifier(for game: ElectronGame) -> String {
        let slug = game.suggestedAppName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "com.lever.electron.juego" : "com.lever.electron." + slug
    }

    /// Nombre nuevo de un ayudante: se le cambia el «Electron» de delante y se le deja el resto,
    /// que es lo que distingue al de la GPU del de dibujo.
    public static func renamedHelper(_ original: String, to appName: String) -> String? {
        guard original.hasPrefix("Electron") else { return nil }
        return appName + original.dropFirst("Electron".count)
    }

    // MARK: - El traslado completo

    public static func makeApp(
        for game: ElectronGame,
        into folder: URL,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        onStage: @Sendable @escaping (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> PortOutcome {
        let engine = try await ensureRuntime(
            for: game, runner: runner, session: session,
            library: library, fileManager: fileManager, onStage: onStage, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }

        let (resueltos, sinResolver) = try await ensureNativeModules(
            for: game, runner: runner, session: session,
            library: library, fileManager: fileManager, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.assembling)
        let destination = PortPaths.freeAppURL(named: game.suggestedAppName, in: folder, fileManager: fileManager)
        do {
            try assemble(game: game, engine: engine, modules: resueltos, unresolved: sinResolver,
                         at: destination, fileManager: fileManager, onLine: onLine)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw PortFailure.assemblyFailed(error.localizedDescription)
        }
        if session.isCancelled { throw PortFailure.cancelled }

        onStage(.signing)
        await PortSigning.signNested(app: destination, runner: runner, session: session)

        return PortOutcome(app: destination, unresolvedParts: sinResolver)
    }

    /// Los sitios donde puede estar el binario de macOS de un módulo, por orden de probabilidad.
    ///
    /// Son varios porque el nombre del archivo depende de contra qué se compilara el módulo, y eso
    /// no se sabe hasta mirarlo: los de N-API publican un solo binario por plataforma —vale para
    /// cualquier Electron— y los demás uno por cada ABI.
    static func parts(for modulo: NodeNativeModule, abi: Int, appleSilicon: Bool) -> [NativePart] {
        guard let version = modulo.version else { return [] }
        let plataforma = appleSilicon ? "macos-arm64" : "macos-x64"
        let nombres = modulo.prebuildAssetNames(abi: abi, appleSilicon: appleSilicon)
        let direcciones = modulo.prebuildURLs(abi: abi, appleSilicon: appleSilicon)
        let napi = modulo.napiVersions.sorted(by: >)

        return nombres.enumerated().map { índice, archivo in
            // Las primeras son las de N-API, en el mismo orden que las versiones que declara el
            // módulo; la última siempre es la del ABI.
            let esNapi = índice < napi.count
            return NativePart(
                name: modulo.name, version: version, platform: plataforma,
                abi: esNapi ? nil : abi,
                download: índice < direcciones.count ? direcciones[índice] : nil,
                fileName: archivo,
                runtime: esNapi ? "napi\(napi[índice])" : nil
            )
        }
    }

    /// Consigue la versión de macOS de cada módulo nativo que trae el juego.
    ///
    /// Lo que hace falta saber antes de nada es el ABI, porque un `.node` compilado para otro no
    /// carga: sale del registro de `node-abi` a partir del número mayor de Electron. Si no se puede
    /// averiguar, no se inventa: los módulos se quedan sin resolver y se dicen.
    private static func ensureNativeModules(
        for game: ElectronGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> (resueltos: [(modulo: NodeNativeModule, contenido: URL)], sinResolver: [String]) {
        guard !game.nativeModules.isEmpty else { return ([], []) }

        guard let abi = try await nodeAbi(for: game, runner: runner, session: session,
                                          library: library, fileManager: fileManager, onLine: onLine) else {
            return ([], game.nativeModules.map(\.label))
        }

        var resueltos: [(modulo: NodeNativeModule, contenido: URL)] = []
        var sinResolver: [String] = []
        for modulo in game.nativeModules {
            let candidatas = parts(for: modulo, abi: abi, appleSilicon: game.appleSilicon)
            guard !candidatas.isEmpty else {
                sinResolver.append(modulo.label)
                continue
            }

            // Se prueban por orden hasta que una traiga archivo. Un 404 no es un fallo: es que
            // ese módulo no publica con ese nombre, y el siguiente nombre puede ser el bueno.
            var encontrado: URL?
            for parte in candidatas {
                let resultado = try await NativeParts.obtain(
                    parte, runner: runner, session: session, library: library,
                    fileManager: fileManager, onLine: onLine
                )
                if let archivo = resultado.file { encontrado = archivo; break }
            }
            guard let tar = encontrado else { sinResolver.append(modulo.label); continue }

            // El prebuild viene en `.tar.gz` con un `build/Release/<algo>.node` dentro. Se despliega
            // una vez y se deja desplegado en la caché: así el siguiente juego que use el mismo
            // módulo, versión y ABI no vuelve ni a bajarlo ni a desempaquetarlo.
            let contenido = tar.deletingLastPathComponent().appendingPathComponent("contenido", isDirectory: true)
            if !fileManager.fileExists(atPath: contenido.path) {
                try? fileManager.createDirectory(at: contenido, withIntermediateDirectories: true)
                _ = try? await runner.run(PortCommands.untar(tar, into: contenido),
                                          session: session, onLine: onLine)
            }
            resueltos.append((modulo, contenido))
        }
        return (resueltos, sinResolver)
    }

    /// El ABI de Node de esta versión de Electron.
    ///
    /// El registro se vuelve a bajar cada vez porque pesa ocho kilobytes y porque tenerlo escrito
    /// a mano envejece: una versión de Electron nueva no estaría. Si no hay red se usa la copia
    /// guardada, y si tampoco la hay se devuelve `nil` en vez de adivinar.
    private static func nodeAbi(
        for game: ElectronGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> Int? {
        let carpeta = library.nativePartURL(key: "node-abi")
        let archivo = carpeta.appendingPathComponent("abi_registry.json")
        try? fileManager.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let descarga = try? await runner.run(
            PortCommands.download(NodeAbi.registryURL, into: archivo), session: session, onLine: onLine
        )
        if descarga?.succeeded != true, !fileManager.fileExists(atPath: archivo.path) { return nil }
        guard let datos = try? Data(contentsOf: archivo) else { return nil }
        return NodeAbi.forElectron(major: game.engineVersion.major, registry: datos)
    }

    private static func ensureRuntime(
        for game: ElectronGame,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager,
        onStage: @Sendable (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let cache = library.electronRuntimeURL(version: game.version)
        let engine = cache.appendingPathComponent("Electron.app", isDirectory: true)
        if library.hasElectronRuntime(version: game.version) { return engine }

        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        onStage(.downloadingRuntime(game.version))
        let archive = cache.appendingPathComponent("electron.zip")
        let download = try await runner.run(
            PortCommands.download(game.macDownloadURL, into: archive), session: session, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }
        guard download.succeeded else {
            try? fileManager.removeItem(at: archive)
            throw PortFailure.downloadFailed(download.exitCode)
        }

        onStage(.unpackingRuntime)
        _ = try? await runner.run(PortCommands.unzip(archive, into: cache), session: session, onLine: onLine)
        try? fileManager.removeItem(at: archive)

        guard library.hasElectronRuntime(version: game.version) else { throw PortFailure.runtimeMissing }
        return engine
    }

    // MARK: - Montaje

    private static func assemble(
        game: ElectronGame,
        engine: URL,
        modules: [(modulo: NodeNativeModule, contenido: URL)],
        unresolved: [String],
        at destination: URL,
        fileManager: FileManager,
        onLine: @Sendable @escaping (String) -> Void
    ) throws {
        try clone(from: engine, to: destination)
        guard fileManager.fileExists(atPath: destination.path) else { throw PortFailure.runtimeMissing }

        let nombre = game.suggestedAppName
        let contents = destination.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")

        // El ejecutable, para que el Dock y el diálogo de forzar salida no digan «Electron».
        let lanzador = contents.appendingPathComponent("MacOS/\(nombre)")
        if lanzador.lastPathComponent != "Electron" {
            try? fileManager.removeItem(at: lanzador)
            try fileManager.moveItem(at: contents.appendingPathComponent("MacOS/Electron"), to: lanzador)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lanzador.path)

        try renameHelpers(in: contents, to: nombre, identifier: identifier(for: game), fileManager: fileManager)

        // El `default_app.asar` es la pantalla de bienvenida de Electron: sobra en cuanto hay juego.
        try? fileManager.removeItem(at: resources.appendingPathComponent("default_app.asar"))
        for entrada in game.resourceEntries {
            let destino = resources.appendingPathComponent(entrada)
            try? fileManager.removeItem(at: destino)
            try clone(from: game.root.appendingPathComponent("resources/\(entrada)"), to: destino)
        }
        guard fileManager.fileExists(atPath: resources.appendingPathComponent("app.asar").path) else {
            throw PortFailure.assemblyFailed("app.asar")
        }

        let icono = makeIcon(game: game, at: resources.appendingPathComponent("icon.icns"),
                             fileManager: fileManager)
        let plistURL = contents.appendingPathComponent("Info.plist")
        guard let original = try? Data(contentsOf: plistURL),
              let parcheado = infoPlist(from: original, game: game,
                                        displayName: nombre, hasCustomIcon: icono) else {
            throw PortFailure.assemblyFailed("Info.plist")
        }
        try parcheado.write(to: plistURL)

        // El binario de Windows se sustituye en su sitio: el prebuild trae `build/Release/…node`
        // con la misma forma que el que ya está, así que desplegarlo encima del módulo lo cambia.
        let desempaquetado = resources.appendingPathComponent("app.asar.unpacked/node_modules",
                                                              isDirectory: true)
        for (modulo, contenido) in modules {
            let destino = desempaquetado.appendingPathComponent(modulo.name, isDirectory: true)
            try? fileManager.createDirectory(at: destino, withIntermediateDirectories: true)
            for pieza in (try? fileManager.contentsOfDirectory(atPath: contenido.path)) ?? [] {
                let dentro = destino.appendingPathComponent(pieza)
                try? fileManager.removeItem(at: dentro)
                try clone(from: contenido.appendingPathComponent(pieza), to: dentro)
            }
        }

        onLine("+ \(nombre) (Electron \(game.version))")
        for (modulo, _) in modules {
            onLine("· \(modulo.label): cambiado por el de macOS")
        }
        for etiqueta in unresolved {
            onLine("· \(etiqueta): módulo nativo sin binario de macOS publicado para este ABI")
        }
    }

    /// Renombra los cuatro `.app` de ayuda que Chromium esconde dentro del framework.
    ///
    /// No es cosmético. En Chromium los procesos que dibujan son estos, y el principal los busca
    /// por un nombre derivado del suyo: si la app se llama distinto que sus ayudantes, la ventana
    /// abre y se queda en negro. `electron-packager` los renombra, y por eso se renombran aquí.
    private static func renameHelpers(
        in contents: URL,
        to appName: String,
        identifier: String,
        fileManager: FileManager
    ) throws {
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        for entrada in (try? fileManager.contentsOfDirectory(atPath: frameworks.path))?.sorted() ?? [] {
            guard entrada.hasSuffix(".app") else { continue }
            let base = String(entrada.dropLast(4))
            guard let nuevoBase = renamedHelper(base, to: appName), nuevoBase != base else { continue }

            let viejo = frameworks.appendingPathComponent(entrada, isDirectory: true)
            let nuevo = frameworks.appendingPathComponent(nuevoBase + ".app", isDirectory: true)
            try? fileManager.removeItem(at: nuevo)
            try fileManager.moveItem(at: viejo, to: nuevo)

            let macOS = nuevo.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try? fileManager.moveItem(at: macOS.appendingPathComponent(base),
                                      to: macOS.appendingPathComponent(nuevoBase))

            let ficha = nuevo.appendingPathComponent("Contents/Info.plist")
            if let original = try? Data(contentsOf: ficha),
               let parcheado = helperPlist(from: original, helperName: nuevoBase, appIdentifier: identifier) {
                try parcheado.write(to: ficha)
            }
        }
    }

    /// Un icono, si el reparto dejó uno reconocible. Si no, se queda el de Electron, que es lo
    /// mismo que hace `electron-packager` cuando no se le da ninguno.
    private static func makeIcon(game: ElectronGame, at destination: URL, fileManager: FileManager) -> Bool {
        let base = game.executable.deletingPathExtension().lastPathComponent
        let sitios = ["resources/\(base).png", "resources/icon.png", "\(base).png", "icon.png"]
        for relativa in sitios {
            let imagen = game.root.appendingPathComponent(relativa)
            guard fileManager.fileExists(atPath: imagen.path) else { continue }
            PortPaths.makeIcon(from: imagen, at: destination, fileManager: fileManager)
            if fileManager.fileExists(atPath: destination.path) { return true }
        }
        return false
    }

    /// Copia clonando en APFS: un Electron desplegado son doscientos cincuenta megas.
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
