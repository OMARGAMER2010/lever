import Foundation

/// Un juego instalado en la biblioteca de Steam de Lever.
public struct SteamGame: Equatable, Sendable, Identifiable {
    public let appID: String
    public let name: String
    public let installDirectory: URL

    public var id: String { appID }

    public init(appID: String, name: String, installDirectory: URL) {
        self.appID = appID
        self.name = name
        self.installDirectory = installDirectory
    }
}

/// Por dónde entrar a un juego.
public enum SteamLaunch: Equatable, Sendable {
    /// Por Steam, que es quien sabe cómo arranca cada juego. Lo normal.
    case throughSteam
    /// Directo a un ejecutable. Para los juegos que meten un lanzador por medio y no
    /// llegan a abrirse sin conexión.
    case executable(URL)
}

/// Instalación de Steam preparada para Lever. Su motor y prefijo son independientes
/// de los programas de Windows: cambiar o restablecer Wine no borra esta biblioteca.
public struct WindowsSteam: Sendable {
    public let root: URL

    /// Sincronización de hilos del motor. msync usa primitivas de macOS en lugar de los
    /// descriptores de esync, y en las pruebas de campaña subió las medias estimadas de
    /// 36–46 a 58–59 FPS; no es una garantía de 60 constantes.
    ///
    /// Steam y los juegos comparten prefijo, así que comparten servidor de Wine, y el motor
    /// exige que servidor y clientes pidan lo mismo: el que no coincide se queda sin msync.
    /// Son interruptores, y no declarar uno equivale a apagarlo. Revertirlo es cambiar este
    /// diccionario, que es el único sitio donde se decide.
    public static let synchronization: [String: String] = [
        "WINEMSYNC": "1",
        "WINEESYNC": "0"
    ]

    /// El navegador que Steam lleva dentro y con el que dibuja su interfaz. Su proceso es el
    /// que suele tener la ventana, así que sin él no se puede traer Steam al frente.
    static let userInterfaceExecutable = "steamwebhelper.exe"

    /// Entradas de la biblioteca que no son juegos, sino la fontanería de Steam. Se esconden
    /// para no ofrecer «jugar» a un paquete de bibliotecas de Microsoft.
    static let plumbingAppIDs: Set<String> = [
        "228980"  // Steamworks Common Redistributables
    ]

    /// Nombres que delatan un instalador o un informe de fallos, no el juego. No se ocultan
    /// —esconder el único ejecutable de un juego sería peor—, solo bajan al final de la lista.
    static let plumbingExecutables = [
        "vcredist", "vcredis", "dxsetup", "directx", "dotnet", "oalinst",
        "unins", "setup", "install", "redist", "crashhandler", "crashreport", "crashpad"
    ]

    public init(root: URL = WineLauncher.prefixURL.deletingLastPathComponent()) {
        self.root = root
    }

    public var prefixURL: URL { root.appendingPathComponent("steam") }
    public var steamURL: URL {
        prefixURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }
    public var steamappsURL: URL {
        steamURL.deletingLastPathComponent().appendingPathComponent("steamapps")
    }

    /// El motor que usan Steam y los juegos, con las DLL de D3DMetal incorporadas.
    ///
    /// Es el mismo para los dos a propósito. Un juego que arranca por Steam hereda el entorno
    /// de Steam, así que si Steam corriera con el motor pelado el juego se quedaría sin
    /// aceleración gráfica. Y WINEDLLPATH no basta: Wine busca primero en su propio directorio
    /// de DLL incorporadas, por eso el motor es una copia aparte y no un añadido.
    public var engineURL: URL {
        runtimeURL.appendingPathComponent("bin/wine")
    }
    private var runtimeURL: URL {
        root.appendingPathComponent("runtimes/sikarugir-10.0_6-d3dmetal/wswine.bundle")
    }
    private var externalLibrariesPath: String {
        runtimeURL.appendingPathComponent("lib/external").path
    }
    public var frameworksURL: URL {
        root.appendingPathComponent("runtimes/template-1.0.15/Template-1.0.15.app/Contents/Frameworks")
    }

    public var isReady: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: engineURL.path)
            && fm.isReadableFile(atPath: runtimeURL.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal").path)
            && fm.isReadableFile(atPath: steamURL.path)
            && fm.isReadableFile(atPath: frameworksURL.appendingPathComponent("libinotify.0.dylib").path)
            && fm.isReadableFile(atPath: prefixURL.appendingPathComponent("drive_c/windows/system32/kernel32.dll").path)
    }

    /// Lo que Steam y los juegos tienen en común. Comparten prefijo, así que comparten servidor
    /// de Wine, y un juego que lanza Steam hereda su entorno: por eso el motor, las bibliotecas
    /// y la sincronización se deciden aquí una sola vez, y no en cada orden por separado.
    private func sharedEnvironment() -> [String: String] {
        var environment = WineLauncher.environment(wine: engineURL, prefix: prefixURL)
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = externalLibrariesPath + ":" + frameworksURL.path + ":/usr/lib"
        environment["DYLD_FRAMEWORK_PATH"] = externalLibrariesPath
        environment["WINEDLLOVERRIDES"] = "mscoree,mshtml=;d3d11,d3d12,dxgi=b"
        environment["WINEDEBUG"] = "fixme-all,err-hid"
        environment["MVK_CONFIG_LOG_LEVEL"] = "1"
        for (name, value) in Self.synchronization { environment[name] = value }
        return environment
    }

    /// El HUD de Metal queda apagado en el uso normal y se enciende solo para medir: es la
    /// única forma de ver tiempos de cuadro, pero se dibuja encima de lo que haya.
    private func environment(showHUD: Bool) -> [String: String] {
        var environment = sharedEnvironment()
        environment["MTL_HUD_ENABLED"] = showHUD ? "1" : "0"
        environment["MTL_HUD_LOG_ENABLED"] = showHUD ? "1" : "0"
        return environment
    }

    public func command(showHUD: Bool = false) -> ProcessCommand {
        ProcessCommand(executableURL: engineURL, arguments: [steamURL.path],
                       currentDirectoryURL: steamURL.deletingLastPathComponent(),
                       environment: environment(showHUD: showHUD))
    }

    /// Le pide a Steam que se cierre solo.
    ///
    /// Hace falta para el Steam que sigue en marcha sin ventana: no se puede traer al frente lo
    /// que no tiene ventana, y volver a lanzarlo no sirve —el segundo `steam.exe` le pasa el
    /// recado al primero y se va—, así que la única salida es que el primero se vaya. `-shutdown`
    /// es la orden que Steam se da a sí mismo, la misma que su menú: termina de escribir lo que
    /// tenga a medias y cierra. No es una señal: a señales se le cortaría la escritura.
    public func shutdownCommand() -> ProcessCommand {
        ProcessCommand(executableURL: engineURL, arguments: [steamURL.path, "-shutdown"],
                       currentDirectoryURL: steamURL.deletingLastPathComponent(),
                       environment: sharedEnvironment())
    }

    public func gameCommand(_ game: SteamGame, launch: SteamLaunch,
                            showHUD: Bool = false) -> ProcessCommand {
        var environment = environment(showHUD: showHUD)
        switch launch {
        case .throughSteam:
            return ProcessCommand(executableURL: engineURL,
                                  arguments: [steamURL.path, "-applaunch", game.appID],
                                  currentDirectoryURL: steamURL.deletingLastPathComponent(),
                                  environment: environment)
        case .executable(let executable):
            // Al saltarse el lanzador, nadie le dice al juego quién es: estas dos variables son
            // lo que Steam pondría por él, y sin ellas no encuentra la licencia ni la partida.
            environment["SteamAppId"] = game.appID
            environment["SteamGameId"] = game.appID
            return ProcessCommand(executableURL: engineURL, arguments: [executable.path],
                                  currentDirectoryURL: executable.deletingLastPathComponent(),
                                  environment: environment)
        }
    }

    // MARK: - La biblioteca instalada

    /// Los juegos instalados, por orden alfabético.
    ///
    /// No se filtran por estado de descarga a propósito. Un juego a medias aparece y Steam se
    /// queja al abrirlo, que es un fallo visible; esconderlo dejaría a alguien buscando en la
    /// lista un juego que sabe que tiene.
    public func installedGames() -> [SteamGame] {
        let common = steamappsURL.appendingPathComponent("common")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: steamappsURL.path)) ?? []
        return names
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            .compactMap { name in
                guard let text = try? String(contentsOf: steamappsURL.appendingPathComponent(name),
                                             encoding: .utf8) else { return nil }
                return Self.game(fromManifest: text, common: common)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func game(fromManifest text: String, common: URL) -> SteamGame? {
        guard let appID = value("appid", in: text),
              let name = value("name", in: text),
              let directory = value("installdir", in: text),
              !plumbingAppIDs.contains(appID) else { return nil }
        return SteamGame(appID: appID, name: name,
                         installDirectory: common.appendingPathComponent(directory))
    }

    /// Lee un campo del manifiesto de Steam, que es texto con pares `"clave"  "valor"`.
    /// Vale para los campos que nos interesan; un valor con comillas dentro no se contempla.
    private static func value(_ key: String, in manifest: String) -> String? {
        for line in manifest.split(separator: "\n") {
            let pieces = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard pieces.count >= 4, pieces[1] == key else { continue }
            return String(pieces[3])
        }
        return nil
    }

    /// Los ejecutables del juego, el más probable primero.
    ///
    /// Steam no guarda en el manifiesto cuál es el de arranque: eso vive en su base de datos
    /// binaria. Así que se ordenan por parecido con el nombre del juego y decide la persona,
    /// que es lo honesto cuando el programa no puede saberlo.
    public func executableCandidates(for game: SteamGame) -> [URL] {
        let walker = FileManager.default.enumerator(
            at: game.installDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [URL] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "exe" else { continue }
            found.append(url)
            // Una biblioteca enorme o un enlace circular no pueden congelar la interfaz.
            if found.count >= 300 { break }
        }
        let wanted = Self.simplified(game.name)
        return found.sorted { first, second in
            let a = Self.likeness(of: first, to: wanted), b = Self.likeness(of: second, to: wanted)
            if a != b { return a > b }
            // A igual parecido, el que está menos enterrado.
            return first.pathComponents.count < second.pathComponents.count
        }
    }

    private static func likeness(of executable: URL, to wanted: String) -> Int {
        let plain = simplified(executable.deletingPathExtension().lastPathComponent)
        if plumbingExecutables.contains(where: { plain.contains($0) }) { return -1 }
        if plain == wanted { return 3 }
        if !wanted.isEmpty, plain.contains(wanted) || wanted.contains(plain) { return 2 }
        return 0
    }

    /// «SUPER CASTILLO» y «supercastillo.exe» son el mismo nombre escrito de dos maneras.
    private static func simplified(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
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

    /// Pregunta por los procesos sin su entorno, que para saber si Steam está abierto no hace
    /// falta: la ruta del ejecutable ya dice de qué prefijo es. Y el entorno de todos los
    /// procesos del usuario son cientos de miles de bytes que se leerían para nada, porque esta
    /// comprobación se repite mientras Steam arranca.
    public func clientProbeCommand() -> ProcessCommand {
        ProcessCommand(executableURL: URL(fileURLWithPath: "/bin/ps"),
                       arguments: ["axww", "-o", "pid=,command="],
                       currentDirectoryURL: nil)
    }

    /// El proceso de Steam que ya está en marcha en este prefijo, si lo hay.
    ///
    /// Es la diferencia entre abrir Steam y no hacer nada: cuando ya hay uno corriendo, el
    /// `steam.exe` que se lance después solo le pasa el recado y termina sin error, así que
    /// Lever creería haberlo abierto mientras no aparece ninguna ventana.
    ///
    /// La comparación es por igualdad con la ruta real de `steam.exe`, no por terminación: esa
    /// ruta vive dentro del prefijo, así que identifica a este Steam y solo a este. El de otra
    /// instalación tiene otra ruta, el de Game Porting Toolkit aparece con la ruta de Windows
    /// detrás de su cargador, y una orden que se limite a nombrar el archivo —un `grep`— no la
    /// tiene como mandato. Vale con la salida de las dos comprobaciones, con entorno o sin él.
    public func runningClient(processListing: String) -> Int32? {
        for line in processListing.split(separator: "\n") {
            guard let parts = Self.split(psLine: String(line)),
                  isClient(command: parts.command) else { continue }
            return parts.pid
        }
        return nil
    }

    /// Si este mandato es el cliente de Steam de este prefijo.
    ///
    /// La ruta tiene que abrir el mandato y acabar donde acaba, pero puede llevar argumentos
    /// detrás: Steam se queda corriendo con `-silent`, que es precisamente como se queda sin
    /// ventana, y exigir el mandato entero dejaría sin reconocer justo ese caso. Que la ruta
    /// esté al principio es lo que distingue ejecutarla de solo nombrarla.
    private func isClient(command: String) -> Bool {
        guard command.hasPrefix(steamURL.path) else { return false }
        let rest = command.dropFirst(steamURL.path.count)
        return rest.isEmpty || rest.hasPrefix(" ")
    }

    /// Los procesos de este Steam que pueden tener la ventana, el cliente primero.
    ///
    /// Hace falta porque no siempre la tiene el mismo: `steam.exe` es el cliente, pero su
    /// interfaz la dibuja el navegador que Steam lleva dentro, `steamwebhelper.exe`, y entonces
    /// la ventana es de ese —el cliente se queda sin ninguna—. Cuál de los dos la tiene depende
    /// del momento del arranque, así que se ofrecen los dos y decide quien mire las ventanas.
    ///
    /// Al cliente se le reconoce por su ruta real, que vive dentro del prefijo y por tanto solo
    /// puede ser este. El navegador aparece con su ruta de Windows, que no dice de qué
    /// instalación es: eso lo confirma después su ejecutable de macOS.
    public func windowOwners(processListing: String) -> [Int32] {
        var owners: [Int32] = []
        for line in processListing.split(separator: "\n") {
            guard let parts = Self.split(psLine: String(line)) else { continue }
            if isClient(command: parts.command) {
                owners.insert(parts.pid, at: 0)
            } else if parts.command.contains(Self.userInterfaceExecutable) {
                owners.append(parts.pid)
            }
        }
        return owners
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
    private static func split(psLine line: String) -> (pid: Int32, command: String,
                                                       environment: String)? {
        var pieces = line.split(separator: " ").map(String.init)
        guard pieces.count >= 2, let pid = Int32(pieces.removeFirst()) else { return nil }
        guard let cut = pieces.firstIndex(where: isAssignment) else {
            return (pid, pieces.joined(separator: " "), "")
        }
        return (pid, pieces[..<cut].joined(separator: " "), pieces[cut...].joined(separator: " "))
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
