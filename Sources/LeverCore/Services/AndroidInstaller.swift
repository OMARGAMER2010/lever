import Foundation

/// En qué va la instalación. Cada paso se dice porque cada uno puede tardar y porque, cuando algo
/// falla, saber en cuál iba es la mitad del diagnóstico.
public enum AndroidInstallStage: Equatable, Sendable {
    /// Falta una herramienta y se está bajando.
    case gettingTool(AndroidToolNeed)
    /// Sacando del envoltorio los trozos que le tocan a este aparato.
    case unpacking
    /// Firmando un `.apk` que venía sin firma.
    case signing
    /// `bundletool` generando los `.apk` de este aparato a partir del `.aab`.
    case buildingApks
    case installing(parts: Int)
    case pushingExpansion(name: String, index: Int, total: Int)
}

public struct AndroidInstallOutcome: Equatable, Sendable {
    public let packageName: String?
    public let installedParts: Int
    public let pushedExpansions: Int
    public let wasSigned: Bool
}

public enum AndroidInstallFailure: Error, Equatable {
    case cancelled
    /// Hace falta una herramienta que no está y no se ha podido conseguir.
    case missingTool(AndroidToolNeed.Tool)
    /// Android dijo que no, y dijo por qué.
    case rejected(AndroidLauncher.InstallFailure)
    /// Un paso terminó mal sin más explicación que su código.
    case failed(Int32)
    /// El envoltorio no se dejó abrir.
    case unreadable
}

/// Lleva un paquete de Android hasta el aparato, sea del formato que sea.
///
/// Un `.apk` se empuja tal cual y ya está. Los otros tres formatos no: dentro hay varios `.apk`
/// que solo valen juntos, y hay que decidir cuáles. Ese reparto lo hacía Play; fuera de Play lo
/// hace o esto —cuando los trozos vienen planos, como en un `.xapk`— o `bundletool`, que es el
/// único que sabe leer la tabla de un `.apks`.
public enum AndroidInstaller {
    public static func install(
        package: AndroidPackage,
        at url: URL,
        adb: URL,
        device: AndroidDevice,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        onStage: @Sendable @escaping (AndroidInstallStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> AndroidInstallOutcome {
        var toolkit = AndroidTools.locate(library: library, fileManager: fileManager)
        let needs = AndroidTools.needs(for: package, having: toolkit)
        if !needs.isEmpty {
            toolkit = try await AndroidTools.prepare(
                needs: needs, runner: runner, session: session,
                library: library, fileManager: fileManager,
                onNeed: { onStage(.gettingTool($0)) }, onLine: onLine
            )
        }

        let taller = fileManager.temporaryDirectory
            .appendingPathComponent("Lever-android-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: taller, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: taller) }

        switch package.kind {
        case .apk:
            return try await installSingle(
                package: package, at: url, adb: adb, device: device, toolkit: toolkit,
                runner: runner, session: session, library: library, fileManager: fileManager,
                workshop: taller, onStage: onStage, onLine: onLine
            )
        case .xapk:
            return try await installSplitSet(
                package: package, at: url, adb: adb, device: device,
                runner: runner, session: session, fileManager: fileManager,
                workshop: taller, onStage: onStage, onLine: onLine
            )
        case .apks, .aab:
            return try await installWithBundletool(
                package: package, at: url, adb: adb, device: device, toolkit: toolkit,
                runner: runner, session: session, library: library,
                workshop: taller, onStage: onStage, onLine: onLine
            )
        }
    }

    // MARK: - Un `.apk` suelto

    private static func installSingle(
        package: AndroidPackage, at url: URL, adb: URL, device: AndroidDevice,
        toolkit: AndroidToolkit, runner: ProcessRunner, session: ProcessSession,
        library: PortLibrary, fileManager: FileManager, workshop: URL,
        onStage: @Sendable @escaping (AndroidInstallStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> AndroidInstallOutcome {
        var aInstalar = url
        var firmado = false

        if package.needsSigning {
            guard toolkit.canSign else { throw AndroidInstallFailure.missingTool(.buildTools) }
            onStage(.signing)
            aInstalar = try await sign(
                url, toolkit: toolkit, runner: runner, session: session,
                library: library, fileManager: fileManager, workshop: workshop
            )
            firmado = true
        }

        onStage(.installing(parts: 1))
        try await run(
            AndroidLauncher.installCommand(adb: adb, serial: device.serial, apk: aInstalar),
            runner: runner, session: session, onLine: onLine
        )
        return AndroidInstallOutcome(
            packageName: package.facts.packageName, installedParts: 1,
            pushedExpansions: 0, wasSigned: firmado
        )
    }

    /// Firma una copia, nunca el archivo del usuario.
    ///
    /// `zipalign` va antes que la firma y no después: alinear mueve bytes dentro del ZIP, y
    /// moverlos después dejaría la firma apuntando a un archivo que ya no es el mismo.
    private static func sign(
        _ url: URL, toolkit: AndroidToolkit, runner: ProcessRunner, session: ProcessSession,
        library: PortLibrary, fileManager: FileManager, workshop: URL
    ) async throws -> URL {
        guard let java = toolkit.java, let apksigner = toolkit.apksigner else {
            throw AndroidInstallFailure.missingTool(.buildTools)
        }
        let clave = try await AndroidTools.signingKey(
            runner: runner, session: session, library: library, fileManager: fileManager
        )

        let copia = workshop.appendingPathComponent("sin-firmar.apk")
        try fileManager.copyItem(at: url, to: copia)
        var destino = copia

        if let zipalign = toolkit.zipalign {
            let alineado = workshop.appendingPathComponent("firmada.apk")
            let resultado = try await runner.run(
                AndroidTools.alignCommand(zipalign: zipalign, from: copia, to: alineado),
                session: session
            )
            // Si alinear falla no se abandona: es una mejora de rendimiento del aparato, no un
            // requisito para instalar. Lo que sí es requisito es la firma.
            if resultado.succeeded { destino = alineado }
        }

        let firma = try await runner.run(
            AndroidTools.signCommand(java: java, apksigner: apksigner, key: clave, apk: destino),
            session: session
        )
        guard firma.succeeded else { throw AndroidInstallFailure.failed(firma.exitCode) }
        return destino
    }

    // MARK: - Envoltorios con los trozos planos

    private static func installSplitSet(
        package: AndroidPackage, at url: URL, adb: URL, device: AndroidDevice,
        runner: ProcessRunner, session: ProcessSession, fileManager: FileManager, workshop: URL,
        onStage: @Sendable @escaping (AndroidInstallStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> AndroidInstallOutcome {
        let densidad = try? await runner.run(
            AndroidLauncher.densityCommand(adb: adb, serial: device.serial), session: session
        )
        let elegidos = AndroidSplitChooser.choose(
            parts: package.parts,
            deviceAbis: device.abis,
            densityDpi: densidad.flatMap { AndroidLauncher.density(fromOutput: $0.output) }
        )
        guard !elegidos.isEmpty else { throw AndroidInstallFailure.unreadable }

        onStage(.unpacking)
        // La base va delante: `adb` acepta cualquier orden, pero si algo se lee a medias el
        // mensaje de error señala al trozo que importa.
        let ordenados = elegidos.sorted { ($0.isBase ? 0 : 1) < ($1.isBase ? 0 : 1) }
        let archivos = try AndroidBundleInspector.extract(
            entryNames: ordenados.map(\.entryName), of: url, into: workshop, fileManager: fileManager
        )

        onStage(.installing(parts: archivos.count))
        try await run(
            AndroidLauncher.installMultipleCommand(adb: adb, serial: device.serial, apks: archivos),
            runner: runner, session: session, onLine: onLine
        )

        let empujados = try await push(
            expansions: package.expansions, from: url, adb: adb, serial: device.serial,
            runner: runner, session: session, fileManager: fileManager, workshop: workshop,
            onStage: onStage, onLine: onLine
        )

        return AndroidInstallOutcome(
            packageName: package.facts.packageName, installedParts: archivos.count,
            pushedExpansions: empujados, wasSigned: false
        )
    }

    /// Coloca los archivos de expansión donde el juego los va a buscar.
    ///
    /// Se sacan y se empujan de uno en uno: un `.obb` pasa de los dos gigas y tener dos a la vez
    /// en el disco, para nada, es la diferencia entre que quepa y que no.
    private static func push(
        expansions: [AndroidExpansion], from url: URL, adb: URL, serial: String,
        runner: ProcessRunner, session: ProcessSession, fileManager: FileManager, workshop: URL,
        onStage: @Sendable @escaping (AndroidInstallStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> Int {
        guard !expansions.isEmpty else { return 0 }
        var hechos = 0

        for (índice, expansión) in expansions.enumerated() {
            guard !session.isCancelled else { throw AndroidInstallFailure.cancelled }
            onStage(.pushingExpansion(name: expansión.fileName, index: índice + 1, total: expansions.count))

            let sacados = try AndroidBundleInspector.extract(
                entryNames: [expansión.entryName], of: url, into: workshop, fileManager: fileManager
            )
            guard let archivo = sacados.first else { continue }
            defer { try? fileManager.removeItem(at: archivo) }

            _ = try? await runner.run(
                AndroidLauncher.makeExpansionFolderCommand(
                    adb: adb, serial: serial, package: expansión.packageName
                ),
                session: session
            )
            let empuje = try await runner.run(
                AndroidLauncher.pushExpansionCommand(
                    adb: adb, serial: serial, file: archivo, expansion: expansión
                ),
                session: session, onLine: onLine
            )
            guard empuje.succeeded else { throw AndroidInstallFailure.failed(empuje.exitCode) }
            hechos += 1
        }
        return hechos
    }

    // MARK: - Lo que solo sabe hacer bundletool

    private static func installWithBundletool(
        package: AndroidPackage, at url: URL, adb: URL, device: AndroidDevice,
        toolkit: AndroidToolkit, runner: ProcessRunner, session: ProcessSession,
        library: PortLibrary, workshop: URL,
        onStage: @Sendable @escaping (AndroidInstallStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> AndroidInstallOutcome {
        guard let java = toolkit.java, let bundletool = toolkit.bundletool else {
            throw AndroidInstallFailure.missingTool(toolkit.java == nil ? .java : .bundletool)
        }

        var apks = url
        if package.kind == .aab {
            onStage(.buildingApks)
            let clave = try await AndroidTools.signingKey(
                runner: runner, session: session, library: library
            )
            apks = workshop.appendingPathComponent("generado.apks")
            let construir = try await runner.run(
                AndroidTools.buildApksCommand(
                    java: java, bundletool: bundletool, adb: adb, serial: device.serial,
                    bundle: url, output: apks, key: clave
                ),
                session: session, onLine: onLine
            )
            guard !construir.wasCancelled else { throw AndroidInstallFailure.cancelled }
            guard construir.succeeded else { throw AndroidInstallFailure.failed(construir.exitCode) }
        }

        // Cuántos trozos van a entrar no se sabe: eso lo decide `bundletool` leyendo su tabla, y
        // decir un número aquí sería inventárselo. Se cuenta como una sola instalación.
        onStage(.installing(parts: 1))
        try await run(
            AndroidTools.installApksCommand(
                java: java, bundletool: bundletool, adb: adb, serial: device.serial, apks: apks
            ),
            runner: runner, session: session, onLine: onLine
        )
        return AndroidInstallOutcome(
            packageName: package.facts.packageName,
            installedParts: 1, pushedExpansions: 0, wasSigned: false
        )
    }

    // MARK: - Común

    /// Lanza una orden que instala y traduce lo que conteste.
    ///
    /// `adb install` no siempre devuelve un código distinto de cero al fallar: hay versiones que
    /// terminan en 0 y escriben «Failure [...]» por la salida. Manda el texto.
    private static func run(
        _ command: ProcessCommand, runner: ProcessRunner, session: ProcessSession,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws {
        let resultado = try await runner.run(command, session: session, onLine: onLine)
        if resultado.wasCancelled { throw AndroidInstallFailure.cancelled }
        if let motivo = AndroidLauncher.installFailure(inOutput: resultado.output) {
            throw AndroidInstallFailure.rejected(motivo)
        }
        guard resultado.succeeded else { throw AndroidInstallFailure.failed(resultado.exitCode) }
    }
}
