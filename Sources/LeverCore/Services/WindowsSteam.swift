import Foundation

/// Instalación de Steam preparada para Lever. Su motor y prefijo son independientes
/// de los programas de Windows: cambiar o restablecer Wine no borra esta biblioteca.
public struct WindowsSteam: Sendable {
    public let root: URL

    /// Sincronización de hilos del motor. msync usa primitivas de macOS en lugar de los
    /// descriptores de esync, y en las pruebas de campaña subió las medias estimadas de
    /// 36–46 a 58–59 FPS; no es una garantía de 60 constantes.
    ///
    /// Steam y el juego comparten prefijo, así que comparten servidor de Wine, y el motor
    /// exige que servidor y clientes pidan lo mismo: el que no coincide se queda sin msync.
    /// Son interruptores, y no declarar uno equivale a apagarlo. Revertir el experimento es
    /// cambiar este diccionario, que es el único sitio donde se decide.
    public static let synchronization: [String: String] = [
        "WINEMSYNC": "1",
        "WINEESYNC": "0"
    ]

    public init(root: URL = WineLauncher.prefixURL.deletingLastPathComponent()) {
        self.root = root
    }

    public var prefixURL: URL { root.appendingPathComponent("steam") }
    public var steamURL: URL {
        prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }
    public var wineURL: URL {
        root.appendingPathComponent("runtimes/sikarugir-10.0_6/wswine.bundle/bin/wine")
    }
    public var frameworksURL: URL {
        root.appendingPathComponent("runtimes/template-1.0.15/Template-1.0.15.app/Contents/Frameworks")
    }

    public var isReady: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: wineURL.path)
            && fm.isReadableFile(atPath: steamURL.path)
            && fm.isReadableFile(atPath: frameworksURL.appendingPathComponent("libinotify.0.dylib").path)
            && fm.isReadableFile(atPath: prefixURL.appendingPathComponent("drive_c/windows/system32/kernel32.dll").path)
    }

    /// Lo que Steam y el juego tienen en común. Los dos abren el mismo prefijo, así que la
    /// sincronización se pone aquí una sola vez: si cada orden la copiara por su cuenta,
    /// cambiar una y olvidar la otra dejaría al segundo cliente sin msync y sin aviso.
    private func sharedEnvironment(wine: URL) -> [String: String] {
        var environment = WineLauncher.environment(wine: wine, prefix: prefixURL)
        environment["WINEDEBUG"] = "fixme-all,err-hid"
        environment["MVK_CONFIG_LOG_LEVEL"] = "1"
        for (name, value) in Self.synchronization { environment[name] = value }
        return environment
    }

    public func command() -> ProcessCommand {
        var environment = sharedEnvironment(wine: wineURL)
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = frameworksURL.path + ":/usr/lib"
        return ProcessCommand(executableURL: wineURL, arguments: [steamURL.path],
                              currentDirectoryURL: steamURL.deletingLastPathComponent(),
                              environment: environment)
    }

    public var superCastilloURL: URL {
        steamURL.deletingLastPathComponent()
            .appendingPathComponent("steamapps/common/SUPER CASTILLO/Game/supercastillo.exe")
    }

    private var metalRuntimeURL: URL {
        root.appendingPathComponent("runtimes/sikarugir-10.0_6-d3dmetal/wswine.bundle")
    }

    public var superCastilloIsReady: Bool {
        let fm = FileManager.default
        return isReady
            && fm.isReadableFile(atPath: superCastilloURL.path)
            && fm.isExecutableFile(atPath: metalRuntimeURL.appendingPathComponent("bin/wine").path)
            && fm.isReadableFile(atPath: metalRuntimeURL.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal").path)
    }

    /// Arranque directo sin el lanzador de EAC. Steam sigue autenticando la licencia.
    /// El motor dedicado contiene las DLL de D3DMetal: WINEDLLPATH solo no basta,
    /// porque Wine busca primero en su propio directorio de DLL incorporadas.
    ///
    /// El HUD de Metal queda apagado en el uso normal y se enciende solo para medir: es la
    /// única forma de ver tiempos de cuadro, pero se dibuja encima del juego.
    public func superCastilloCommand(showHUD: Bool = false) -> ProcessCommand {
        let wine = metalRuntimeURL.appendingPathComponent("bin/wine")
        let external = metalRuntimeURL.appendingPathComponent("lib/external").path
        var environment = sharedEnvironment(wine: wine)
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = external + ":" + frameworksURL.path + ":/usr/lib"
        environment["DYLD_FRAMEWORK_PATH"] = external
        environment["WINEDLLOVERRIDES"] = "mscoree,mshtml=;d3d11,d3d12,dxgi=b"
        environment["SteamAppId"] = "1234567"
        environment["SteamGameId"] = "1234567"
        environment["MTL_HUD_ENABLED"] = showHUD ? "1" : "0"
        environment["MTL_HUD_LOG_ENABLED"] = showHUD ? "1" : "0"
        return ProcessCommand(executableURL: wine, arguments: [superCastilloURL.path],
                              currentDirectoryURL: superCastilloURL.deletingLastPathComponent(),
                              environment: environment)
    }

    // MARK: - El servidor de Wine que ya está en marcha

    /// Cómo está sincronizado el servidor de Wine que atiende el prefijo de Steam.
    public enum SyncState: Equatable, Sendable {
        /// No hay servidor de este prefijo: el siguiente arranque fija la configuración.
        case noServer
        /// Ya hay servidor y pide la misma sincronización que Lever.
        case matching
        /// Ya hay servidor con otra sincronización. Cerrarlo es cosa del usuario desde el
        /// menú del juego o de Steam: terminarlo desde aquí se llevaría su sesión y, con
        /// ella, una partida sin guardar.
        case different
        /// Hay servidor, pero el sistema no dejó leer su entorno. No se afirma nada.
        case unreadable
    }

    /// Pregunta al sistema por los procesos y su entorno: `e` es lo que imprime el entorno,
    /// `ax` lo que mira más allá del terminal y `ww` lo que evita el recorte de la línea.
    ///
    /// La salida trae el entorno de todos los procesos del usuario, así que se analiza y se
    /// descarta; no se escribe en el registro de actividad ni en ningún archivo.
    public func syncProbeCommand() -> ProcessCommand {
        ProcessCommand(executableURL: URL(fileURLWithPath: "/bin/ps"),
                       arguments: ["axeww", "-o", "pid=,command="],
                       currentDirectoryURL: nil)
    }

    /// Interpreta la salida de `syncProbeCommand`. Va separada de la ejecución para poder
    /// probarla con listados reales en vez de depender de qué haya abierto la máquina.
    public func syncState(processListing: String) -> SyncState {
        var serverWithoutEnvironment = false
        var servers: [String] = []
        for line in processListing.split(separator: "\n") {
            guard let parts = Self.split(psLine: String(line)),
                  parts.command.hasSuffix("wineserver") else { continue }
            if parts.environment.contains("WINEPREFIX=") {
                if declaresSteamPrefix(parts.environment) { servers.append(parts.environment) }
            } else {
                serverWithoutEnvironment = true
            }
        }
        guard !servers.isEmpty else { return serverWithoutEnvironment ? .unreadable : .noServer }
        let everyServerAgrees = servers.allSatisfy { environment in
            Self.synchronization.allSatisfy { name, value in
                // Una variable ausente es una variable apagada, igual que «0».
                (Self.value(of: name, in: environment) ?? "0") == value
            }
        }
        return everyServerAgrees ? .matching : .different
    }

    /// El valor de WINEPREFIX lleva espacios en la ruta real («Application Support»), así que
    /// se busca el texto completo y se exige que acabe ahí: «…/steamlab» no es «…/steam».
    private func declaresSteamPrefix(_ environment: String) -> Bool {
        let marker = "WINEPREFIX=" + prefixURL.path
        guard let range = environment.range(of: marker) else { return false }
        return range.upperBound == environment.endIndex || environment[range.upperBound] == " "
    }

    /// Separa mandato y entorno en una línea de `ps`: delante va el PID, alineado a la derecha,
    /// y detrás del mandato las variables. El corte es el primer trozo con forma de
    /// `NOMBRE=valor`, porque ps no marca el límite. Es una heurística deliberadamente
    /// estrecha: solo reconoce el servidor cuando el mandato termina en «wineserver», y si se
    /// equivoca lo hace hacia no avisar, nunca hacia impedir que el usuario juegue.
    private static func split(psLine line: String) -> (command: String, environment: String)? {
        var pieces = line.split(separator: " ").map(String.init)
        guard pieces.count >= 2 else { return nil }
        pieces.removeFirst()
        guard let cut = pieces.firstIndex(where: isAssignment) else {
            return (pieces.joined(separator: " "), "")
        }
        return (pieces[..<cut].joined(separator: " "), pieces[cut...].joined(separator: " "))
    }

    private static func isAssignment(_ piece: String) -> Bool {
        guard let equals = piece.firstIndex(of: "="), equals > piece.startIndex,
              let first = piece.first, first == "_" || first.isLetter else { return false }
        return piece[piece.startIndex..<equals].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Lee una variable del entorno que imprime ps. Sirve para los interruptores de
    /// sincronización, cuyo valor no lleva espacios.
    private static func value(of name: String, in environment: String) -> String? {
        let start = name + "="
        for piece in environment.split(separator: " ") where piece.hasPrefix(start) {
            return String(piece.dropFirst(start.count))
        }
        return nil
    }
}
