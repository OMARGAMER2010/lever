import CryptoKit
import Darwin
import Foundation

public enum SafeRunStage: Equatable, Sendable {
    case importing
    case preparing
    case creatingWindows
    case running
    case cleaning
}

public enum SafeRunError: Error, Equatable, Sendable {
    case sandboxUnavailable
    case engine(String)
    case prefix
    case importFailed(String)
    case diskLow
}

public struct SafeRunOutcome: Sendable {
    public let exitCode: Int32
    public let wasStopped: Bool
    /// Procesos que seguían vivos al cerrar la sesión y hubo que terminar.
    public let terminatedProcesses: Int
}

/// Ejecuta un programa de Windows dentro de un espacio aislado.
///
/// Wine no aísla nada: el código de Windows puede hacer llamadas al sistema de macOS directamente.
/// La frontera es Seatbelt, que se hereda en cada proceso hijo. Todo lo demás —prefijo propio,
/// unidades limitadas, entorno limpio— sirve para que un programa honrado funcione dentro de esa
/// frontera sin chocar con ella a cada paso.
public final class SafeWindowsRunner: @unchecked Sendable {
    let runner: ProcessRunner
    let base: URL
    private let lock = NSLock()
    private var activeEngine: URL?

    public init(runner: ProcessRunner, base: URL = SafeWorkspace.defaultBase) {
        self.runner = runner
        self.base = base
    }

    // MARK: - Espacio para un programa

    /// Carpetas donde no se clona la carpeta del programa, solo el programa: son las que juntan
    /// cosas del usuario que no tienen nada que ver con él.
    public static func isPersonalRoot(_ directory: URL) -> Bool {
        guard let real = try? SandboxPath.canonical(directory) else { return true }
        let home = (try? SandboxPath.canonical(URL(fileURLWithPath: NSHomeDirectory()))) ?? NSHomeDirectory()
        let roots = ["", "/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents/com~apple~CloudDocs",
                     "/Movies", "/Music", "/Pictures"].map { home + $0 }
        let volumeRoot = real.split(separator: "/").count <= 2 && real.hasPrefix("/Volumes/")
        return roots.contains(real) || ["/", "/Applications", "/Users", "/Volumes"].contains(real) || volumeRoot
    }

    /// El espacio donde se ejecutará el programa: si ya vive en uno, ese; si no, uno nuevo con una
    /// copia clonada. El original no se toca y el programa aislado nunca lo ve.
    public func workspace(for program: URL, fileManager: FileManager = .default) throws -> (SafeWorkspace, URL) {
        if let existing = SafeWorkspace.containing(program, base: base) {
            return (existing, URL(fileURLWithPath: try SandboxPath.canonical(program)))
        }
        let source = program.deletingLastPathComponent()
        let originPath = program.path
        let workspace: SafeWorkspace
        if let previous = SafeWorkspace.existing(forProgramAt: originPath, base: base, fileManager: fileManager) {
            workspace = previous
        } else {
            workspace = try SafeWorkspace.create(origin: SafeWorkspaceOrigin(kind: .program, path: originPath),
                                                 base: base, fileManager: fileManager)
            do {
                if Self.isPersonalRoot(source) {
                    try Self.clone(program, to: workspace.files.appendingPathComponent(program.lastPathComponent))
                } else {
                    let target = workspace.files.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                    try Self.clone(source, to: target)
                    _ = SafeContentScanner.sweep(root: workspace.files, fileManager: fileManager)
                }
            } catch {
                try? workspace.delete(base: base, fileManager: fileManager)
                throw SafeRunError.importFailed(error.localizedDescription)
            }
        }
        let inside = Self.isPersonalRoot(source)
            ? workspace.files.appendingPathComponent(program.lastPathComponent)
            : workspace.files.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                .appendingPathComponent(program.lastPathComponent)
        return (workspace, URL(fileURLWithPath: try SandboxPath.canonical(inside)))
    }

    // MARK: - Ejecutar

    public func run(
        program: URL,
        in workspace: SafeWorkspace,
        wine: URL,
        allowsNetwork: Bool,
        session: ProcessSession,
        onStage: @escaping @Sendable (SafeRunStage) -> Void,
        onLine: @escaping @Sendable (String) -> Void,
        fileManager: FileManager = .default
    ) async throws -> SafeRunOutcome {
        onStage(.preparing)
        let wineReal = URL(fileURLWithPath: try SandboxPath.canonical(wine))
        let engineSource = wineReal.deletingLastPathComponent().deletingLastPathComponent()
        let wineName = wineReal.lastPathComponent
        try workspace.prepareRunDirectories(fileManager: fileManager)

        // 1. El prefijo: clonado de una plantilla limpia, creada una sola vez por motor.
        if !fileManager.fileExists(atPath: workspace.windows.appendingPathComponent("system.reg").path) {
            onStage(.creatingWindows)
            let template = try await ensureTemplate(engineSource: engineSource, wineName: wineName,
                                                    session: session, onLine: onLine, fileManager: fileManager)
            try? SafeWorkspace.removeTree(at: workspace.windows, confinedTo: base, fileManager: fileManager)
            try Self.clone(template, to: workspace.windows)
        }
        try Self.sanitizePrefix(workspace.windows, filesDrive: "../../files", fileManager: fileManager)

        // 2. El motor, clonado: así cada proceso de la sesión se reconoce por su ejecutable.
        try? SafeWorkspace.removeTree(at: workspace.engine, confinedTo: base, fileManager: fileManager)
        do {
            try Self.cloneEngine(engineSource, wineName: wineName, to: workspace.engine)
        } catch {
            throw SafeRunError.engine(error.localizedDescription)
        }
        setActiveEngine(workspace.engine)
        defer { setActiveEngine(nil) }

        let profileURL = workspace.control.appendingPathComponent("windows.sb")
        try writeProfile(for: workspace.windows, engine: workspace.engine, workspace: workspace,
                         allowsNetwork: allowsNetwork, to: profileURL)
        let environment = Self.environment(engine: workspace.engine, prefix: workspace.windows, workspace: workspace)
        let wine64 = workspace.engine.appendingPathComponent("bin/\(wineName)")
        let relative = program.path.dropFirst(try SandboxPath.canonical(workspace.files).count + 1)
        let dosPath = "D:\\" + relative.replacingOccurrences(of: "/", with: "\\")
        let arguments = program.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", dosPath] : [dosPath]

        onStage(.running)
        let watchdog = ResourceWatchdog(session: session, volume: workspace.root, maximumBytesWritten: nil,
                                        maximumFootprint: nil)
        watchdog.start(interval: .seconds(2))
        // La sesión dura lo que dure su wineserver, no lo que dure el primer proceso: muchos juegos
        // arrancan con un lanzador que abre el juego de verdad y se va. Cuando ya no queda ni el
        // lanzador ni el wineserver, lo que siga vivo del motor es un proceso desligado —lo que
        // dejaría un malware para seguir corriendo— y se cierra. Detener lo cierra todo al momento.
        let engine = workspace.engine
        let reaper = Task.detached {
            var quietSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if session.isCancelled {
                    await SafeProcessTracker.terminate(executableUnder: engine, grace: .seconds(2))
                    return
                }
                let serverAlive = SafeProcessTracker.executables(under: engine).contains { $0.path.hasSuffix("/bin/wineserver") }
                guard session.processIdentifier == nil, !serverAlive else {
                    quietSince = nil
                    continue
                }
                quietSince = quietSince ?? .now
                if ContinuousClock.now - quietSince! > .seconds(3) {
                    await SafeProcessTracker.terminate(executableUnder: engine)
                    return
                }
            }
        }
        let result = try await runner.run(
            Sandbox.command(ProcessCommand(executableURL: wine64, arguments: arguments,
                                           currentDirectoryURL: program.deletingLastPathComponent()),
                            profileURL: profileURL, environment: environment),
            session: session, onLine: onLine)
        reaper.cancel()
        watchdog.stop()

        onStage(.cleaning)
        let terminated = await closeSession(engine: workspace.engine, prefix: workspace.windows, workspace: workspace,
                                            wineName: wineName, profileURL: profileURL, environment: environment)
        try? SafeWorkspace.removeTree(at: workspace.engine, confinedTo: base, fileManager: fileManager)
        try? SafeWorkspace.removeTree(at: workspace.temporary, confinedTo: base, fileManager: fileManager)
        // La carpeta del espacio se puede abrir en el Finder al terminar, y allí sí se siguen los
        // enlaces: los que apunten fuera no se quedan.
        SafeContentScanner.removeEscapingLinks(under: workspace.files, fileManager: fileManager)
        if watchdog.tripped == .diskSpace { throw SafeRunError.diskLow }
        return SafeRunOutcome(exitCode: result.exitCode, wasStopped: result.wasCancelled, terminatedProcesses: terminated)
    }

    /// Detiene la sesión en marcha: el programa y todo lo que haya lanzado.
    public func stopActiveSession() async {
        guard let engine = currentEngine() else { return }
        await SafeProcessTracker.terminate(executableUnder: engine, grace: .seconds(2))
    }

    /// Sin espera, para cuando Lever se cierra.
    public func killActiveSessionNow() {
        guard let engine = currentEngine() else { return }
        SafeProcessTracker.killNow(executableUnder: engine)
    }

    /// Restos de una sesión que acabó con Lever cerrado de golpe: procesos que siguen corriendo
    /// desde un motor clonado y el propio clon.
    public static func recoverStaleSessions(base: URL = SafeWorkspace.defaultBase, fileManager: FileManager = .default) {
        let workspaces = SafeWorkspace.all(base: base, fileManager: fileManager)
        var engines = workspaces.map(\.engine)
        var prefixes = workspaces.map(\.windows)
        let templates = base.appendingPathComponent("plantillas", isDirectory: true)
        for template in (try? fileManager.contentsOfDirectory(at: templates, includingPropertiesForKeys: nil)) ?? [] {
            engines.append(template.appendingPathComponent("engine", isDirectory: true))
            prefixes.append(template.appendingPathComponent("prefix", isDirectory: true))
        }
        for engine in engines where fileManager.fileExists(atPath: engine.path) {
            SafeProcessTracker.killNow(executableUnder: engine)
            try? SafeWorkspace.removeTree(at: engine, confinedTo: base, fileManager: fileManager)
        }
        // Sockets que quedaron de una sesión que acabó mal. Solo los de prefijos de Safe Mode: en
        // la misma carpeta están los del modo normal y los de Steam, y esos no se tocan.
        for prefix in prefixes {
            guard let socket = serverDirectory(forPrefix: prefix) else { continue }
            try? fileManager.removeItem(at: socket)
        }
        // Y enlaces que un programa dejara apuntando fuera de su espacio. No sirven de puente
        // —el aislamiento los deniega igual—, pero la carpeta se abre en el Finder como tuya.
        for workspace in workspaces {
            _ = SafeContentScanner.removeEscapingLinks(under: workspace.files, fileManager: fileManager)
        }
    }

    // MARK: - Plantilla del prefijo

    private func ensureTemplate(
        engineSource: URL,
        wineName: String,
        session: ProcessSession,
        onLine: @escaping @Sendable (String) -> Void,
        fileManager: FileManager
    ) async throws -> URL {
        let key = Self.engineKey(engineSource, wineName: wineName)
        let root = base.appendingPathComponent("plantillas/\(key)", isDirectory: true)
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        if fileManager.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/kernel32.dll").path) {
            return prefix
        }
        // La plantilla la crea wineboot, dentro del mismo aislamiento, y nunca corre en ella nada
        // que no sea del propio Wine: por eso se puede clonar para cada espacio.
        try? SafeWorkspace.removeTree(at: root, confinedTo: base, fileManager: fileManager)
        let scratch = SafeWorkspace(root: root)
        try fileManager.createDirectory(at: scratch.control, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: scratch.files, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        try scratch.prepareRunDirectories(fileManager: fileManager)
        try Self.cloneEngine(engineSource, wineName: wineName, to: scratch.engine)
        defer { try? SafeWorkspace.removeTree(at: scratch.engine, confinedTo: base, fileManager: fileManager) }

        let profileURL = scratch.control.appendingPathComponent("wineboot.sb")
        try writeProfile(for: prefix, engine: scratch.engine, workspace: scratch, allowsNetwork: false, to: profileURL,
                         extraWritable: [prefix])
        let environment = Self.environment(engine: scratch.engine, prefix: prefix, workspace: scratch)
        let result = try await runner.run(
            Sandbox.command(ProcessCommand(executableURL: scratch.engine.appendingPathComponent("bin/\(wineName)"),
                                           arguments: ["wineboot", "--init"], currentDirectoryURL: scratch.files),
                            profileURL: profileURL, environment: environment),
            session: session, onLine: onLine)
        _ = await closeSession(engine: scratch.engine, prefix: prefix, workspace: scratch, wineName: wineName,
                               profileURL: profileURL, environment: environment)
        guard !result.wasCancelled,
              fileManager.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/kernel32.dll").path) else {
            try? SafeWorkspace.removeTree(at: root, confinedTo: base, fileManager: fileManager)
            throw SafeRunError.prefix
        }
        return prefix
    }

    // MARK: - Piezas

    private func writeProfile(
        for prefix: URL,
        engine: URL,
        workspace: SafeWorkspace,
        allowsNetwork: Bool,
        to url: URL,
        extraWritable: [URL] = []
    ) throws {
        let uid = getuid()
        let wineTemp = try Self.wineTemporaryDirectory(uid: uid)
        let realPrefix = try SandboxPath.canonical(prefix)
        var info = stat()
        guard stat(realPrefix, &info) == 0 else { throw SafeRunError.prefix }
        let server = String(format: "server-%llx-%llx", UInt64(info.st_dev), UInt64(info.st_ino))
        let spec = WindowsSandboxSpec(
            engine: engine,
            workspaceRoot: workspace.root,
            writableDirectories: [workspace.files, workspace.windows, workspace.home, workspace.temporary] + extraWritable,
            serverDirectory: "\(wineTemp)/\(server)",
            serverName: "/tmp/.wine-\(uid)/\(server)",
            userID: uid,
            allowsNetwork: allowsNetwork
        )
        try Sandbox.write(try SandboxProfile.windowsSession(spec), to: url)
    }

    /// La carpeta donde Wine deja los sockets de esta persona, comprobada antes de nombrarla en un
    /// perfil.
    ///
    /// `/private/tmp` lo puede escribir cualquiera, así que `.wine-<uid>` puede existir ya y no ser
    /// nuestra: un enlace, o una carpeta de otro usuario. Crearla y dar por hecho que salió bien
    /// dejaría una regla del aislamiento hablando de un sitio distinto del que se usa.
    public static func wineTemporaryDirectory(uid: uid_t = getuid()) throws -> String {
        let path = "/private/tmp/.wine-\(uid)"
        var info = stat()
        if lstat(path, &info) != 0 {
            guard mkdir(path, 0o700) == 0, lstat(path, &info) == 0 else {
                throw SandboxError.unusablePath(path)
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,      // ni un enlace ni un archivo
              info.st_uid == uid,                      // nuestra, no de otro
              info.st_mode & 0o077 == 0,               // y solo nuestra
              try SandboxPath.canonical(URL(fileURLWithPath: path)) == path else {
            throw SandboxError.unusablePath(path)
        }
        return path
    }

    /// El socket de Wine para un prefijo: `server-<dispositivo>-<inodo>`, el mismo nombre que
    /// calcula Wine. `nil` si el prefijo ya no está.
    public static func serverDirectory(forPrefix prefix: URL, uid: uid_t = getuid()) -> URL? {
        guard let temporary = try? wineTemporaryDirectory(uid: uid),
              let real = try? SandboxPath.canonical(prefix) else { return nil }
        var info = stat()
        guard stat(real, &info) == 0 else { return nil }
        let name = String(format: "server-%llx-%llx", UInt64(info.st_dev), UInt64(info.st_ino))
        return URL(fileURLWithPath: temporary).appendingPathComponent(name, isDirectory: true)
    }

    /// Cierra el `wineserver` de la sesión y lo que quede vivo del motor clonado.
    private func closeSession(engine: URL, prefix: URL, workspace: SafeWorkspace, wineName: String,
                              profileURL: URL, environment: [String: String]) async -> Int {
        let server = engine.appendingPathComponent("bin/wineserver")
        if FileManager.default.isExecutableFile(atPath: server.path) {
            _ = try? await runner.run(Sandbox.command(
                ProcessCommand(executableURL: server, arguments: ["-k"], currentDirectoryURL: nil),
                profileURL: profileURL, environment: environment))
        }
        let closed = await SafeProcessTracker.terminate(executableUnder: engine)
        // El socket de esta sesión ya no sirve a nadie: sin esto se van amontonando en /tmp una
        // carpeta por cada espacio que haya existido.
        if let socket = Self.serverDirectory(forPrefix: prefix) {
            try? FileManager.default.removeItem(at: socket)
        }
        return closed
    }

    static func environment(engine: URL, prefix: URL, workspace: SafeWorkspace) -> [String: String] {
        var environment = WineLauncher.environment(wine: engine.appendingPathComponent("bin/wine"), prefix: prefix)
        let isolated = [
            "HOME": workspace.home.path,
            "TMPDIR": workspace.temporary.path + "/",
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "LANG": Locale.current.identifier.contains("es") ? "es_ES.UTF-8" : "en_US.UTF-8",
            "PATH": engine.appendingPathComponent("bin").path + ":/usr/bin:/bin",
            "WINEPREFIX": prefix.path,
            // MSync/ESync usan memoria y puertos globales. En una sesión aislada se conserva
            // la sincronización estándar de Wine, sin abrir acceso a otras sesiones.
            "WINEMSYNC": "0",
            "WINEESYNC": "0",
            // Los errores de carga de DLL siguen visibles, igual que en el modo normal.
            "WINEDEBUG": ProcessInfo.processInfo.environment["LEVER_SAFE_WINEDEBUG"] ?? "fixme-all,err-hid",
            // Sin winemenubuilder no se crean accesos ni asociaciones de archivos en el Mac.
            "WINEDLLOVERRIDES": (environment["WINEDLLOVERRIDES"] ?? "mscoree,mshtml=") + ";winemenubuilder.exe=d"
        ]
        environment.merge(isolated) { _, isolatedValue in isolatedValue }
        return environment
    }

    /// Deja al prefijo con dos unidades: C: (su Windows) y D: (los archivos del espacio). Wine crea
    /// `Z:` apuntando a la raíz del disco y enlaza las carpetas del usuario a las de verdad; aquí se
    /// deshace antes de cada ejecución, porque una actualización del prefijo las vuelve a crear.
    public static func sanitizePrefix(_ prefix: URL, filesDrive: String, fileManager: FileManager = .default) throws {
        let devices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try fileManager.createDirectory(at: devices, withIntermediateDirectories: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: devices.path)) ?? [] where name != "c:" {
            unlink(devices.appendingPathComponent(name).path)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("c:").path)) == nil {
            try? fileManager.createSymbolicLink(atPath: devices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        }
        try fileManager.createSymbolicLink(atPath: devices.appendingPathComponent("d:").path, withDestinationPath: filesDrive)

        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        for user in (try? fileManager.contentsOfDirectory(atPath: users.path)) ?? [] {
            for folder in ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos", "Templates"] {
                let path = users.appendingPathComponent(user).appendingPathComponent(folder).path
                if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
                    unlink(path)
                    try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
                }
            }
        }
    }

    /// Clon APFS si se puede (instantáneo y sin ocupar), copia normal si no.
    static func clone(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw SafeRunError.importFailed(String(cString: strerror(errno)))
        }
    }

    private static func cloneEngine(_ source: URL, wineName: String, to destination: URL) throws {
        try clone(source, to: destination)
        // El paquete de Wine no trae libinotify y otras dependencias que usa su plantilla.
        // Se clonan las bibliotecas dentro del motor para que Seatbelt no necesite permitir
        // leer carpetas fuera del espacio. Los alias se resuelven al copiar, sin enlaces externos.
        let support = WineLauncher.libraryDirectories(wine: source.appendingPathComponent("bin/\(wineName)"))
        for directory in support.dropFirst() {
            let libraries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for library in libraries where library.pathExtension == "dylib" {
                let target = destination.appendingPathComponent("lib/external/\(library.lastPathComponent)")
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                try clone(library.resolvingSymlinksInPath(), to: target)
            }
        }
    }

    static func engineKey(_ engine: URL, wineName: String) -> String {
        let binary = engine.appendingPathComponent("bin/\(wineName)").path
        var info = stat()
        stat(binary, &info)
        let seed = "\(engine.path)|\(info.st_size)|\(info.st_mtimespec.tv_sec)"
        return SHA256.hash(data: Data(seed.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func setActiveEngine(_ engine: URL?) {
        lock.lock(); activeEngine = engine; lock.unlock()
    }

    private func currentEngine() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return activeEngine
    }
}
