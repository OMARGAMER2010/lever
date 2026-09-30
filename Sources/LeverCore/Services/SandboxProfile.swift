import Darwin
import Foundation

public enum SandboxError: Error, Equatable, LocalizedError {
    /// No hay aislamiento que aplicar en este Mac. Safe Mode no sigue sin él: nunca.
    case unavailable
    /// Una ruta que no se puede escribir en un perfil sin riesgo de que diga otra cosa.
    case unusablePath(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "sandbox-exec no está disponible"
        case .unusablePath(let path): return "ruta no válida para el aislamiento: \(path)"
        }
    }
}

/// Las rutas tal y como las compara Seatbelt.
///
/// El kernel mira la ruta **real**: `/opt/homebrew/bin/7zz` es un enlace a la carpeta `Cellar`, y
/// `/tmp` es `/private/tmp`. Una regla escrita con la ruta de siempre no coincide con nada y el
/// aislamiento lo deniega todo, o peor, deja fuera justo lo que se quería permitir. Por eso todo lo
/// que entra en un perfil pasa por `realpath(3)`. No vale `URL.resolvingSymlinksInPath()`: quita el
/// prefijo `/private` de las rutas de `/var` y `/tmp`, que es justo el que hace falta.
public enum SandboxPath {
    public static func canonical(_ url: URL) throws -> String {
        let path = url.standardizedFileURL.path
        guard !path.isEmpty, path.hasPrefix("/") else { throw SandboxError.unusablePath(path) }
        // Comillas y caracteres de control podrían cerrar la cadena del perfil y colar reglas.
        let unsafe = path.unicodeScalars.contains { $0 == "\"" || $0.value < 0x20 || $0.value == 0x7F }
        guard !unsafe else { throw SandboxError.unusablePath(path) }

        // La ruta puede no existir todavía (el destino de una extracción): se resuelve el trozo que
        // sí existe y se le vuelve a pegar el resto.
        var existing = path
        var missing: [String] = []
        while existing != "/" {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                guard !missing.isEmpty else { return base }
                return (base == "/" ? "" : base) + "/" + missing.reversed().joined(separator: "/")
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return "/" + missing.reversed().joined(separator: "/")
    }

    /// Cadena de SBPL entre comillas.
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\") + "\""
    }

    /// Una ruta como literal dentro de una expresión regular de SBPL.
    static func regexLiteral(_ path: String) -> String {
        let special = Set("\\^$.|?*+()[]{}")
        return path.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    /// Qué hay que dejar leer para que arranque una herramienta.
    ///
    /// Las de Homebrew cargan librerías de otras fórmulas por `opt/`, que son enlaces a `Cellar/`:
    /// se permiten las dos carpetas enteras, que solo contienen software instalado. Una herramienta
    /// suelta solo necesita su carpeta.
    public static func readableRoots(forTool tool: URL) throws -> [String] {
        let real = try canonical(tool)
        for prefix in ["/opt/homebrew", "/usr/local"] where real.hasPrefix(prefix + "/Cellar/") {
            return [prefix + "/Cellar", prefix + "/opt"]
        }
        return [(real as NSString).deletingLastPathComponent]
    }
}

/// Lo que necesita el perfil de una sesión de Windows. Las rutas ya vienen del espacio aislado.
public struct WindowsSandboxSpec: Equatable, Sendable {
    public let engine: URL
    public let workspaceRoot: URL
    public let writableDirectories: [URL]
    /// `/private/tmp/.wine-<uid>/server-<dev>-<ino>`: donde su `wineserver` deja el socket.
    public let serverDirectory: String
    /// El mismo nombre sin `/private`, que es con el que se registra en launchd.
    public let serverName: String
    public let userID: uid_t
    public let allowsNetwork: Bool

    public init(
        engine: URL,
        workspaceRoot: URL,
        writableDirectories: [URL],
        serverDirectory: String,
        serverName: String,
        userID: uid_t,
        allowsNetwork: Bool
    ) {
        self.engine = engine
        self.workspaceRoot = workspaceRoot
        self.writableDirectories = writableDirectories
        self.serverDirectory = serverDirectory
        self.serverName = serverName
        self.userID = userID
        self.allowsNetwork = allowsNetwork
    }
}

/// Un perfil de Seatbelt listo para `sandbox-exec -f`.
///
/// Todos parten de `(deny default)`: lo que no se nombra no se puede hacer. La base es el
/// `system.sb` del propio macOS, que es lo que usan sus demonios para arrancar, pero **no es seguro
/// tal cual para código hostil**: permite RunningBoard y la base de datos de LaunchServices, y con
/// eso un proceso aislado abre aplicaciones fuera del aislamiento. Por eso cada perfil termina con
/// el endurecimiento: en SBPL gana la última regla que coincide.
public struct SandboxProfile: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    // MARK: - Piezas comunes

    static let preamble = """
    (version 1)
    (deny default)
    (import "system.sb")
    """

    /// Servicios con los que un proceso aislado podría actuar fuera: lanzar apps (RunningBoard y la
    /// base de datos de LaunchServices), mandar Apple Events, leer el portapapeles, tocar discos,
    /// pedir permisos, llegar al llavero o registrar ítems de inicio.
    static let outsideReachDenials = """
    (deny mach-lookup
      (global-name "com.apple.runningboard")
      (global-name "com.apple.lsd.mapdb")
      (global-name "com.apple.lsd.modifydb")
      (global-name "com.apple.lsd.open")
      (global-name "com.apple.lsd.openurl")
      (global-name "com.apple.coreservices.appleevents")
      (global-name "com.apple.coreservices.quarantine-resolver")
      (global-name "com.apple.CoreServices.coreservicesd")
      (global-name "com.apple.coreservices.sharedfilelistd.xpc")
      (global-name "com.apple.xpc.activity.unmanaged")
      (global-name "com.apple.pasteboard.1")
      (global-name "com.apple.pbs.fetch_services")
      (global-name "com.apple.DiskArbitration.diskarbitrationd")
      (global-name "com.apple.SecurityServer")
      (global-name "com.apple.securityd.xpc")
      (global-name "com.apple.tccd")
      (global-name "com.apple.tccd.system")
      (global-name "com.apple.xpc.loginitemregisterd")
      (global-name "com.apple.xpc.smd")
      (global-name "com.apple.backgroundtaskmanagement.agent"))
    """

    /// Sin ventanas no hace falta ni el registro en LaunchServices.
    static let launchServicesDenial = """
    (deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))
    """

    /// Nombres que macOS sabe abrir por su cuenta: aplicaciones, órdenes de Terminal, instaladores.
    /// Un proceso aislado no puede crearlos ni renombrar nada a ellos, así que tampoco puede dejar
    /// preparado algo que otro programa ejecute fuera.
    static let launchableNames = #"\.(app|command|terminal|tool|workflow|scpt|scptd|applescript|webloc|fileloc|inetloc|pkg|mpkg|dmg|prefpane|saver|kext|action|definition|shortcut)(/|$)"#

    static let fileHardening = """
    (deny file-link)
    (deny file-write-xattr (xattr "com.apple.quarantine"))
    (deny file-write-create (regex #"\(launchableNames)"))
    """

    // MARK: - Perfiles

    /// Leer la lista de un comprimido: solo lectura del archivo, nada que escribir, sin red.
    public static func archiveListing(tool: URL, archive: URL) throws -> SandboxProfile {
        SandboxProfile(text: [
            preamble,
            try toolRules(tool),
            try archiveRules(archive),
            "(deny network*)",
            outsideReachDenials,
            launchServicesDenial,
            fileHardening
        ].joined(separator: "\n"))
    }

    /// Extraer: se lee el comprimido y solo se escribe en el destino. Los enlaces no se pueden crear:
    /// son la herramienta de los ataques que escriben fuera a través de un enlace.
    public static func archiveExtraction(tool: URL, archive: URL, destination: URL, temporary: URL) throws -> SandboxProfile {
        let dest = try SandboxPath.canonical(destination)
        let tmp = try SandboxPath.canonical(temporary)
        return SandboxProfile(text: [
            preamble,
            try toolRules(tool),
            try archiveRules(archive),
            "(allow file-read* file-write* (subpath \(SandboxPath.quoted(dest))))",
            "(allow file-read* file-write* (subpath \(SandboxPath.quoted(tmp))))",
            "(allow file-read-metadata (path-ancestors \(SandboxPath.quoted(dest))))",
            "(deny network*)",
            outsideReachDenials,
            launchServicesDenial,
            "(deny file-write-create (vnode-type SYMLINK))",
            fileHardening
        ].joined(separator: "\n"))
    }

    /// El escáner de firmas: lee sus firmas y lo que analiza, escribe solo en su carpeta temporal.
    public static func signatureScan(scanner: URL, databases: URL, readable: [URL], temporary: URL) throws -> SandboxProfile {
        let tmp = try SandboxPath.canonical(temporary)
        var lines = [preamble, try toolRules(scanner)]
        for url in [databases] + readable {
            let path = SandboxPath.quoted(try SandboxPath.canonical(url))
            lines.append("(allow file-read* (subpath \(path)))")
            lines.append("(allow file-read-metadata (path-ancestors \(path)))")
        }
        lines.append("(allow file-read* file-write* (subpath \(SandboxPath.quoted(tmp))))")
        lines += ["(deny network*)", outsideReachDenials, launchServicesDenial, fileHardening]
        return SandboxProfile(text: lines.joined(separator: "\n"))
    }

    /// Una sesión de Windows. Es el perfil más amplio porque hay que dibujar ventanas, sonar y usar
    /// la GPU, y aun así el programa solo ve su motor, su espacio y su propio `wineserver`.
    public static func windowsSession(_ spec: WindowsSandboxSpec) throws -> SandboxProfile {
        let engine = try SandboxPath.canonical(spec.engine)
        let root = try SandboxPath.canonical(spec.workspaceRoot)
        let writable = try spec.writableDirectories.map { try SandboxPath.canonical($0) }
        let wineTemp = "/private/tmp/.wine-\(spec.userID)"
        guard spec.serverDirectory.hasPrefix(wineTemp + "/server-"),
              spec.serverName.hasPrefix("/tmp/.wine-\(spec.userID)/server-") else {
            throw SandboxError.unusablePath(spec.serverDirectory)
        }
        // `/private/tmp` lo puede escribir cualquiera —tiene el bit pegajoso, pero crear ahí lo
        // puede hacer todo el mundo—, así que `.wine-<uid>` podría ser un enlace puesto por otro.
        // El kernel compara la ruta **resuelta**: si no coincide con la que se escribe aquí, la
        // regla no habla de la carpeta que se cree. Se exige que la ruta sea ella misma.
        guard try SandboxPath.canonical(URL(fileURLWithPath: spec.serverDirectory)) == spec.serverDirectory else {
            throw SandboxError.unusablePath(spec.serverDirectory)
        }

        var lines = [preamble]
        lines.append("""
        ;; Procesos: solo el motor clonado, y señales solo dentro del propio aislamiento.
        (allow process-fork)
        (allow process-exec (subpath \(SandboxPath.quoted(engine))))
        ;; env repone las rutas DYLD después de los ejecutables protegidos de macOS.
        ;; Lo que env intente ejecutar sigue limitado al motor por las reglas de process-exec.
        (allow process-exec file-read* file-map-executable (literal "/usr/bin/env"))
        (allow signal (target same-sandbox))
        (allow process-info* (target same-sandbox))
        (allow dynamic-code-generation)
        (allow sysctl-write (sysctl-name "kern.procname"))

        ;; Motor: leer y mapear, nunca escribir. Rosetta traduce el motor, que es de Intel.
        (allow file-read* file-map-executable (subpath \(SandboxPath.quoted(engine))))
        (allow file-read* file-map-executable (subpath "/usr/libexec/rosetta"))
        (allow file-read-metadata (path-ancestors \(SandboxPath.quoted(engine))))
        (allow file-read-metadata (path-ancestors \(SandboxPath.quoted(root))))
        (allow file-read* (subpath "/Library/Fonts"))
        """)
        lines.append(";; Espacio aislado: lo único que se puede escribir.")
        for dir in writable {
            lines.append("(allow file-read* file-write* file-map-executable (subpath \(SandboxPath.quoted(dir))))")
        }
        lines.append("""
        ;; Su propio wineserver y ningún otro: hablar con el del modo normal o con el de Steam
        ;; permitiría tocar la memoria de procesos que no están aislados.
        (allow file-read-metadata (literal \(SandboxPath.quoted(wineTemp))))
        (allow file-read* file-write* (subpath \(SandboxPath.quoted(spec.serverDirectory))))
        (allow network-bind network-outbound network-inbound (subpath \(SandboxPath.quoted(spec.serverDirectory))))
        (allow mach-register (global-name \(SandboxPath.quoted(spec.serverName))))
        (allow mach-lookup (global-name \(SandboxPath.quoted(spec.serverName))))

        ;; Ventanas, GPU, audio y fuentes. LaunchServices solo para registrarse como aplicación:
        ;; sin eso macOS nunca pone sus ventanas en pantalla.
        (system-graphics)
        (allow iokit-open)
        (allow mach-lookup
          (global-name "com.apple.windowserver.active")
          (global-name "com.apple.windowmanager.server")
          (global-name "com.apple.dock.server")
          (global-name "com.apple.coreservices.launchservicesd")
          (global-name "com.apple.fonts")
          (global-name "com.apple.FontObjectsServer")
          (global-name "com.apple.audio.coreaudiod")
          (global-name "com.apple.audio.audiohald")
          (global-name "com.apple.tsm.uiserver")
          (global-name "com.apple.oahd"))
        (allow file-read* file-write-data file-ioctl (literal "/dev/tty"))
        """)
        if spec.allowsNetwork {
            lines.append("""
            ;; Red permitida solo para esta ejecución, porque así lo pidió la persona.
            (system-network)
            (allow network*)
            (allow mach-lookup
              (global-name "com.apple.dnssd.service")
              (global-name "com.apple.SystemConfiguration.configd")
              (global-name "com.apple.SystemConfiguration.DNSConfiguration"))
            (allow file-read*
              (literal "/private/etc/hosts")
              (literal "/private/etc/resolv.conf")
              (subpath "/private/var/run/resolv.conf")
              (subpath "/private/etc/ssl"))
            """)
        }
        lines += [outsideReachDenials, fileHardening]
        return SandboxProfile(text: lines.joined(separator: "\n"))
    }

    // MARK: - Reglas repetidas

    private static func toolRules(_ tool: URL) throws -> String {
        let real = try SandboxPath.canonical(tool)
        var rules = ["(allow process-exec (literal \(SandboxPath.quoted(real))))"]
        for root in try SandboxPath.readableRoots(forTool: tool) {
            rules.append("(allow file-read* file-map-executable (subpath \(SandboxPath.quoted(root))))")
            rules.append("(allow file-read-metadata (path-ancestors \(SandboxPath.quoted(root))))")
        }
        return rules.joined(separator: "\n")
    }

    /// El comprimido y, si es un volumen de varios, sus hermanos: `juego.part2.rar`, `juego.r01`,
    /// `juego.z01`, `juego.7z.002`. Nada más de la carpeta, que puede ser las Descargas enteras.
    private static func archiveRules(_ archive: URL) throws -> String {
        let real = try SandboxPath.canonical(archive)
        let directory = (real as NSString).deletingLastPathComponent
        var rules = [
            "(allow file-read* (literal \(SandboxPath.quoted(real))))",
            "(allow file-read-metadata (path-ancestors \(SandboxPath.quoted(real))))"
        ]
        if let stem = volumeStem(of: (real as NSString).lastPathComponent) {
            let pattern = "^" + SandboxPath.regexLiteral(directory + "/" + stem)
                + #"\.(part[0-9]+\.rar|rar|r[0-9][0-9]|zip|z[0-9][0-9]|7z|7z\.[0-9][0-9][0-9]|[0-9][0-9][0-9])$"#
            rules.append("(allow file-read* (regex #\"\(pattern)\"))")
        }
        return rules.joined(separator: "\n")
    }

    /// La parte común del nombre de un comprimido por volúmenes, o `nil` si no lo es.
    static func volumeStem(of name: String) -> String? {
        let patterns = [#"^(.+)\.part[0-9]+\.rar$"#, #"^(.+)\.r[0-9]{2}$"#, #"^(.+)\.z[0-9]{2}$"#,
                        #"^(.+)\.7z\.[0-9]{3}$"#, #"^(.+)\.[0-9]{3}$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range(at: 1), in: name) else { continue }
            return String(name[range])
        }
        // El primer volumen de un RAR antiguo o de un ZIP partido lleva la extensión normal.
        let lower = name.lowercased()
        if lower.hasSuffix(".rar") || lower.hasSuffix(".zip") {
            return String(name.dropLast(4))
        }
        return nil
    }
}

/// Lanzar algo dentro del aislamiento.
public enum Sandbox {
    public static let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// Escribe el perfil donde el proceso aislado no puede leerlo ni cambiarlo.
    public static func write(_ profile: SandboxProfile, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(profile.text.utf8).write(to: url, options: .atomic)
    }

    /// Convierte una orden en la misma orden, aislada.
    ///
    /// Pasa por `/bin/sh` solo para fijar límites que se heredan (`ulimit`) y hace `exec`: el PID
    /// no cambia, así que la vigilancia de recursos sigue al proceso de verdad. El entorno no se
    /// hereda de Lever; es exactamente `environment`.
    ///
    /// - Parameter fileSizeLimit: tamaño máximo de **cada** archivo que escriba, en bytes. El kernel
    ///   manda `SIGXFSZ` al que lo pase. `ulimit -f` cuenta en bloques de 1024 bytes.
    public static func command(
        _ command: ProcessCommand,
        profileURL: URL,
        environment: [String: String],
        fileSizeLimit: Int64? = nil
    ) -> ProcessCommand {
        var limits = ["ulimit -c 0"]
        if let fileSizeLimit {
            limits.append("ulimit -f \(max(1, fileSizeLimit / 1024))")
        }
        let script = limits.joined(separator: " && ") + " && exec \"$0\" \"$@\""
        // /bin/sh y sandbox-exec están protegidos por SIP: eliminan DYLD_* del entorno.
        // env las fija una vez dentro del aislamiento, justo antes de exec del motor.
        let libraryPaths = environment.keys.filter { $0.hasPrefix("DYLD_") }.sorted()
            .map { "\($0)=\(environment[$0]!)" }
        let invocation = libraryPaths.isEmpty
            ? [command.executableURL.path]
            : ["/usr/bin/env"] + libraryPaths + [command.executableURL.path]
        return ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, executableURL.path, "-f", profileURL.path] + invocation + command.arguments,
            currentDirectoryURL: command.currentDirectoryURL,
            environment: environment,
            inheritsEnvironment: false
        )
    }

    /// Entorno mínimo para herramientas que no necesitan nada del usuario.
    public static func minimalEnvironment(temporary: URL?) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
        if let temporary { environment["TMPDIR"] = temporary.path + "/" }
        return environment
    }

    /// Comprueba que el aislamiento **se aplica**, no solo que la herramienta existe: un proceso con
    /// un perfil que deniega escribir intenta crear un archivo, y ese archivo no debe aparecer.
    public static func checkAvailability(
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) async -> SandboxAvailability {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else { return .unavailable }
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lever-sandbox-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            let canary = scratch.appendingPathComponent("no-deberia-existir")
            let profileURL = scratch.appendingPathComponent("check.sb")
            let profile = SandboxProfile(text: """
            \(SandboxProfile.preamble)
            (allow process-exec (literal "/usr/bin/touch") (literal "/usr/bin/true"))
            (allow file-read* file-map-executable (literal "/usr/bin/touch") (literal "/usr/bin/true"))
            """)
            try write(profile, to: profileURL, fileManager: fileManager)

            let blocked = try await runner.run(Sandbox.command(
                ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                               arguments: [canary.path], currentDirectoryURL: nil),
                profileURL: profileURL,
                environment: minimalEnvironment(temporary: nil)
            ))
            let enforced = !blocked.succeeded && !fileManager.fileExists(atPath: canary.path)

            // Y que un proceso permitido sí arranca: un perfil roto también «bloquea» todo.
            let allowed = try await runner.run(Sandbox.command(
                ProcessCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                               arguments: [], currentDirectoryURL: nil),
                profileURL: profileURL,
                environment: minimalEnvironment(temporary: nil)
            ))
            return enforced && allowed.succeeded ? .available : .unavailable
        } catch {
            return .unavailable
        }
    }
}
