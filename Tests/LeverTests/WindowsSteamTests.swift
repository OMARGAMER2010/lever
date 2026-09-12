import Foundation
import LeverCore

enum WindowsSteamTests {
    static func run() async throws {
        try testTheInstallationAndHowSteamOpens()
        try testSteamAndTheGamesShareTheEngineSynchronization()
        try testItReadsTheLibraryAndRanksTheExecutables()
        try testTheTwoWaysIntoAGame()
        try testItReadsTheSyncOfAServerAlreadyRunning()
        try testItFindsTheClientAlreadyOpen()
        try testItOffersEveryProcessThatCouldHoldTheWindow()
        try testTheProbeAsksTheSystemForTheEnvironments()
        try testTheWayToAskSteamToQuit()
        try await testTheProbeReallyPrintsEnvironments()
        try await testTheCheapProbeAlsoFindsTheClient()
    }

    /// Crea una instalación de mentira con todas las piezas que `isReady` exige.
    private static func prepared(_ fixture: TemporaryFixture) throws -> WindowsSteam {
        let steam = WindowsSteam(root: fixture.directoryURL)
        let pieces = [steam.engineURL, steam.steamURL,
                      steam.frameworksURL.appendingPathComponent("libinotify.0.dylib"),
                      steam.prefixURL.appendingPathComponent("drive_c/windows/system32/kernel32.dll"),
                      steam.engineURL.deletingLastPathComponent().deletingLastPathComponent()
                          .appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal")]
        for url in pieces {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return steam
    }

    private static func testTheInstallationAndHowSteamOpens() throws {
        let fixture = try TemporaryFixture()
        let empty = WindowsSteam(root: fixture.directoryURL)
        try expect(!empty.isReady, "un entorno vacío no debe ofrecer abrir Steam")

        let steam = try prepared(fixture)
        try expect(steam.isReady, "la instalación preparada debe poder abrirse")
        try expect(steam.engineURL.path.contains("sikarugir-10.0_6-d3dmetal"),
                   "el motor tiene que ser el que lleva D3DMetal dentro")

        let command = steam.command()
        try expect(command.executableURL == steam.engineURL, "Steam debe usar su motor, no el Wine global")
        try expect(command.arguments == [steam.steamURL.path],
                   "las rutas con espacios deben llegar en un solo argumento")
        try expect(command.environment?["WINEPREFIX"] == steam.prefixURL.path,
                   "Steam debe conservar su biblioteca y registros en su propio entorno")
        try expect(command.environment?["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(steam.frameworksURL.path) == true,
                   "sin las bibliotecas del motor wineserver falla antes de abrir Steam")
        try expect(command.environment?["DYLD_FRAMEWORK_PATH"]?.hasSuffix("/lib/external") == true,
                   "D3DMetal necesita resolver su framework al crear el dispositivo")
        try expect(command.environment?["MTL_HUD_ENABLED"] == "0",
                   "el uso normal no debe mostrar el HUD de diagnóstico")
        try expect(steam.command(showHUD: true).environment?["MTL_HUD_LOG_ENABLED"] == "1",
                   "la medición debe registrar tiempos de cuadro")

        try FileManager.default.removeItem(at: steam.frameworksURL.appendingPathComponent("libinotify.0.dylib"))
        try expect(!steam.isReady, "un motor sin sus bibliotecas no está preparado")
    }

    /// Steam y los juegos hablan con el mismo servidor de Wine. Si una orden pide msync y otra
    /// no, el cliente que llega después se queda sin msync: el motor exige que servidor y
    /// clientes coincidan. Por eso la configuración vive en un solo sitio.
    private static func testSteamAndTheGamesShareTheEngineSynchronization() throws {
        try expect(WindowsSteam.synchronization["WINEMSYNC"] == "1",
                   "MSync es lo que se midió cerca de 60 FPS; sin la variable no se activa")
        try expect(WindowsSteam.synchronization["WINEESYNC"] == "0",
                   "esync y msync no conviven: hay que apagar el que no se usa")

        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let game = SteamGame(appID: "42", name: "Un juego",
                             installDirectory: URL(fileURLWithPath: "/tmp/Un juego"))
        let forSteam = steam.command().environment
        let viaSteam = steam.gameCommand(game, launch: .throughSteam).environment
        let viaExecutable = steam.gameCommand(
            game, launch: .executable(URL(fileURLWithPath: "/tmp/Un juego/juego.exe"))).environment

        for (name, value) in WindowsSteam.synchronization {
            for (quién, entorno) in [("Steam", forSteam), ("el juego por Steam", viaSteam),
                                     ("el juego por ejecutable", viaExecutable)] {
                try expect(entorno?[name] == value, "\(quién) debe pedir \(name)=\(value)")
            }
        }
        // Lo que importa no es el valor, sino que nadie pueda cambiar uno y olvidar los otros.
        for name in WindowsSteam.synchronization.keys {
            try expect(forSteam?[name] == viaSteam?[name] && forSteam?[name] == viaExecutable?[name],
                       "Steam y los juegos difieren en \(name) y comparten servidor")
        }
        // Un juego que arranca por Steam hereda su entorno: el motor tiene que ser el mismo.
        try expect(steam.command().executableURL == steam.gameCommand(game, launch: .throughSteam).executableURL,
                   "si Steam corre con otro motor, el juego que lanza se queda sin D3DMetal")
    }

    private static func testItReadsTheLibraryAndRanksTheExecutables() throws {
        let fixture = try TemporaryFixture()
        let steam = try prepared(fixture)
        let fm = FileManager.default

        // Manifiestos como los que escribe Steam: pares de valores entre comillas y tabuladores.
        try write("""
        "AppState"
        {
        \t"appid"\t\t"1234567"
        \t"name"\t\t"SUPER CASTILLO"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"SUPER CASTILLO"
        }
        """, to: steam.steamappsURL.appendingPathComponent("appmanifest_1234567.acf"))
        try write("""
        "AppState"
        {
        \t"appid"\t\t"228980"
        \t"name"\t\t"Steamworks Common Redistributables"
        \t"installdir"\t\t"Steamworks Shared"
        }
        """, to: steam.steamappsURL.appendingPathComponent("appmanifest_228980.acf"))

        let games = steam.installedGames()
        try expect(games.count == 1, "la fontanería de Steam no es un juego que se pueda jugar")
        let game = try unwrap(games.first)
        try expect(game.appID == "1234567" && game.name == "SUPER CASTILLO",
                   "el manifiesto da el identificador y el nombre")
        try expect(game.installDirectory.lastPathComponent == "SUPER CASTILLO",
                   "la carpeta del juego sale de installdir, dentro de common")

        for relative in ["Game/supercastillo.exe", "Game/start_protected_game.exe",
                         "Game/oalinst.exe", "vcredist_x64.exe"] {
            try write("exe", to: game.installDirectory.appendingPathComponent(relative))
        }
        let candidates = steam.executableCandidates(for: game)
        try expect(candidates.count == 4, "se ofrecen todos: esconder uno sería decidir por la persona")
        try expect(candidates.first?.lastPathComponent == "supercastillo.exe",
                   "el que se llama como el juego es el candidato más probable")
        let last = try unwrap(candidates.last?.lastPathComponent)
        try expect(["vcredist_x64.exe", "oalinst.exe"].contains(last),
                   "un instalador de bibliotecas va al final, no arriba")
        let plumbing = candidates.suffix(2).map(\.lastPathComponent).sorted()
        try expect(plumbing == ["oalinst.exe", "vcredist_x64.exe"],
                   "los dos instaladores son los dos últimos")

        try fm.removeItem(at: steam.steamappsURL.appendingPathComponent("appmanifest_1234567.acf"))
        try expect(steam.installedGames().isEmpty, "sin manifiestos no hay juegos")
    }

    private static func testTheTwoWaysIntoAGame() throws {
        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let game = SteamGame(appID: "1234567", name: "SUPER CASTILLO",
                             installDirectory: URL(fileURLWithPath: "/tmp/SUPER CASTILLO"))

        let viaSteam = steam.gameCommand(game, launch: .throughSteam)
        try expect(viaSteam.arguments == [steam.steamURL.path, "-applaunch", "1234567"],
                   "por Steam se le pide el juego por su identificador: Steam sabe cómo arranca")
        try expect(viaSteam.environment?["SteamAppId"] == nil,
                   "si lo lanza Steam, Steam se identifica solo; fingirlo sería mentira")

        let executable = URL(fileURLWithPath: "/tmp/SUPER CASTILLO/Game/supercastillo.exe")
        let direct = steam.gameCommand(game, launch: .executable(executable))
        try expect(direct.arguments == [executable.path],
                   "al saltarse el lanzador se abre el ejecutable elegido, y nada más")
        try expect(direct.currentDirectoryURL == executable.deletingLastPathComponent(),
                   "un juego busca sus datos al lado de su ejecutable")
        try expect(direct.environment?["SteamAppId"] == "1234567"
                   && direct.environment?["SteamGameId"] == "1234567",
                   "sin el lanzador nadie le dice al juego quién es: hay que decírselo")
    }

    /// Un servidor ya en marcha con otra sincronización no se arregla desde Lever sin matarlo,
    /// y matarlo se llevaría la sesión de Steam y una partida sin guardar. Lever solo tiene que
    /// saber distinguir los casos para poder avisar.
    private static func testItReadsTheSyncOfAServerAlreadyRunning() throws {
        // Ruta con espacio, como la real: «Application Support» parte el entorno en varios
        // trozos cuando ps lo imprime, y el análisis tiene que aguantarlo.
        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let server = steam.engineURL.deletingLastPathComponent()
            .appendingPathComponent("wineserver").path
        let prefix = steam.prefixURL.path

        try expect(steam.syncState(processListing: "") == .noServer,
                   "sin servidor, el siguiente arranque fija la sincronización")

        let matching = psLine(72496, server, [("WINEPREFIX", prefix), ("WINEMSYNC", "1"), ("WINEESYNC", "0")])
        try expect(steam.syncState(processListing: matching) == .matching,
                   "un servidor con msync ya sirve para el juego")

        let esync = psLine(72496, server, [("WINEPREFIX", prefix), ("WINEESYNC", "1")])
        try expect(steam.syncState(processListing: esync) == .different,
                   "un servidor con esync no da msync al cliente")

        let msyncOff = psLine(72496, server, [("WINEPREFIX", prefix), ("WINEMSYNC", "0"), ("WINEESYNC", "0")])
        try expect(steam.syncState(processListing: msyncOff) == .different,
                   "msync apagado en el servidor es otra configuración")

        let withoutSync = psLine(72496, server, [("WINEPREFIX", prefix), ("WINEDEBUG", "fixme-all")])
        try expect(steam.syncState(processListing: withoutSync) == .different,
                   "un servidor anterior a este cambio no trae msync")

        // Ausente y «0» significan lo mismo para el motor: no hay que pedir cerrar Steam por eso.
        let onlyMsync = psLine(72496, server, [("WINEPREFIX", prefix), ("WINEMSYNC", "1")])
        try expect(steam.syncState(processListing: onlyMsync) == .matching,
                   "no declarar esync es tenerlo apagado")

        let otherPrefix = psLine(18221, server,
                                 [("WINEPREFIX", "/Users/quien/Library/Application Support/Lever/windows"),
                                  ("WINEMSYNC", "1")])
        try expect(steam.syncState(processListing: otherPrefix) == .noServer,
                   "el servidor de los demás programas de Windows no es el de Steam")

        let lookalike = psLine(18221, server, [("WINEPREFIX", prefix + "lab"), ("WINEMSYNC", "1")])
        try expect(steam.syncState(processListing: lookalike) == .noServer,
                   "«steamlab» no es «steam»: el nombre tiene que acabar donde acaba el prefijo")

        let client = psLine(72494, "C:\\Program Files (x86)\\Steam\\steam.exe",
                            [("WINEPREFIX", prefix), ("WINEMSYNC", "1")])
        try expect(steam.syncState(processListing: client) == .noServer,
                   "un cliente no dice con qué sincronización arrancó el servidor")

        // Una orden que solo menciona la ruta no es el servidor. Pasa de verdad: buscar
        // «wineserver» con grep deja el término en la línea de mandato del propio grep.
        let decoy = psLine(77102, "ugrep -G bin/wineserver /tmp", [("WINEPREFIX", prefix)])
        try expect(steam.syncState(processListing: decoy) == .noServer,
                   "nombrar el servidor no es serlo")

        let withoutEnvironment = "72496 \(server)"
        try expect(steam.syncState(processListing: withoutEnvironment) == .unreadable,
                   "si el sistema no deja leer el entorno hay que decirlo, no inventar")

        // El listado real trae cientos de líneas: la del servidor tiene que encontrarse entre ellas.
        let listing = ["    1 /sbin/launchd", client, otherPrefix, matching, "  302 /usr/libexec/logd"]
            .joined(separator: "\n")
        try expect(steam.syncState(processListing: listing) == .matching,
                   "el servidor del prefijo de Steam debe encontrarse en un listado completo")
    }

    /// Saber si Steam ya está abierto es la diferencia entre abrirlo y no hacer nada: un
    /// segundo `steam.exe` solo le pasa el recado al que ya corre y se va sin error, así que
    /// sin esta comprobación el botón dice que abrió Steam y no aparece ninguna ventana.
    private static func testItFindsTheClientAlreadyOpen() throws {
        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let cliente = steam.steamURL.path
        let server = steam.engineURL.deletingLastPathComponent()
            .appendingPathComponent("wineserver").path
        let prefix = steam.prefixURL.path

        try expect(steam.runningClient(processListing: "") == nil,
                   "sin procesos no hay Steam abierto")

        let abierto = psLine(72494, cliente, [("WINEPREFIX", prefix), ("WINEMSYNC", "1")])
        try expect(steam.runningClient(processListing: abierto) == 72494,
                   "el cliente de este prefijo es el que hay que traer al frente")

        // El mandato llega sin entorno cuando la comprobación es la barata: la ruta del
        // ejecutable ya vive dentro del prefijo, así que por sí sola dice de quién es.
        try expect(steam.runningClient(processListing: psLine(72494, cliente, [])) == 72494,
                   "la ruta del cliente basta: no hace falta leer el entorno de nadie")

        // Steam se queda corriendo con los argumentos con que lo abrieron. `-silent` es el que
        // importa: arranca sin ventana, que es el caso que hay que saber reconocer.
        try expect(steam.runningClient(processListing: psLine(72494, cliente + " -silent", [])) == 72494,
                   "el cliente con argumentos sigue siendo el cliente")

        try expect(steam.runningClient(processListing: psLine(72494, cliente + "tra", [])) == nil,
                   "«steam.exetra» no es «steam.exe»: la ruta tiene que acabar donde acaba")

        try expect(steam.runningClient(processListing: psLine(72496, server, [("WINEPREFIX", prefix)])) == nil,
                   "el servidor de Wine no es el cliente de Steam")

        // El Steam de Game Porting Toolkit aparece con la ruta de Windows detrás de su
        // cargador, no con la del prefijo de Lever: no es este Steam.
        let ajeno = psLine(17259, "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/"
                           + "wine64-preloader C:\\Program Files (x86)\\Steam\\steam.exe", [])
        try expect(steam.runningClient(processListing: ajeno) == nil,
                   "el Steam de otro entorno no es el de Lever")

        let otroPrefijo = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Otro"))
        try expect(steam.runningClient(processListing: psLine(72494, otroPrefijo.steamURL.path, [])) == nil,
                   "el Steam de otra instalación no es el de este prefijo")

        // Nombrar el archivo no es serlo: buscarlo con grep deja la ruta en la línea del grep.
        let señuelo = psLine(77102, "ugrep -G \(cliente) /tmp", [])
        try expect(steam.runningClient(processListing: señuelo) == nil,
                   "mencionar la ruta del cliente no es estar ejecutándolo")

        let listado = ["    1 /sbin/launchd", señuelo, abierto, "  302 /usr/libexec/logd"]
            .joined(separator: "\n")
        try expect(steam.runningClient(processListing: listado) == 72494,
                   "el cliente debe encontrarse entre cientos de líneas")
    }

    /// La ventana de Steam no es siempre del mismo proceso: su interfaz la dibuja el navegador
    /// que lleva dentro, y mirando solo `steam.exe` se concluiría que Steam no tiene ventana
    /// justo cuando está abierto y visible —y entonces se le pediría cerrarse sin motivo—.
    private static func testItOffersEveryProcessThatCouldHoldTheWindow() throws {
        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let cliente = psLine(72494, steam.steamURL.path, [])
        let navegador = psLine(72530, "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\"
                               + "steamwebhelper.exe -nocrashdialog -lang=en_US", [])
        let pestaña = psLine(72561, "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\"
                             + "steamwebhelper.exe --type=renderer", [])

        try expect(steam.windowOwners(processListing: "").isEmpty,
                   "sin procesos no hay ninguna ventana que traer")

        let listado = ["    1 /sbin/launchd", navegador, cliente, pestaña].joined(separator: "\n")
        let dueños = steam.windowOwners(processListing: listado)
        try expect(dueños == [72494, 72530, 72561],
                   "el cliente va primero y detrás los procesos de la interfaz; salió \(dueños)")

        // Solo con el navegador también hay a quién preguntar: es el caso normal con Steam
        // abierto, cuando el cliente se ha quedado sin ventana propia.
        try expect(steam.windowOwners(processListing: navegador) == [72530],
                   "el navegador por sí solo puede ser el que tiene la ventana")

        let servidor = psLine(72496, steam.engineURL.deletingLastPathComponent()
                              .appendingPathComponent("wineserver").path, [])
        try expect(steam.windowOwners(processListing: servidor).isEmpty,
                   "el servidor de Wine no dibuja ventanas")
    }

    /// Un Steam que sigue en marcha sin ventana no se puede traer al frente, y matarlo a
    /// señales sería cortarle la escritura. Steam trae su propia orden de cierre ordenado.
    private static func testTheWayToAskSteamToQuit() throws {
        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let cierre = steam.shutdownCommand()
        try expect(cierre.executableURL == steam.engineURL,
                   "la orden de cierre va por el mismo motor que lo abrió")
        try expect(cierre.arguments == [steam.steamURL.path, "-shutdown"],
                   "«-shutdown» es la forma que tiene Steam de pedirse el cierre a sí mismo")
        try expect(cierre.environment?["WINEPREFIX"] == steam.prefixURL.path,
                   "hay que hablar con el Steam de este prefijo, no con otro")
    }

    private static func testTheProbeAsksTheSystemForTheEnvironments() throws {
        let probe = WindowsSteam(root: URL(fileURLWithPath: "/tmp/lever")).syncProbeCommand()
        try expect(probe.executableURL.path == "/bin/ps", "la comprobación usa la herramienta del sistema")
        try expect(probe.arguments.contains("axeww"),
                   "sin «e» ps no imprime el entorno y sin «ax» solo ve los procesos del terminal")
        try expect(probe.arguments.contains("pid=,command="),
                   "hay que pedir el mandato completo, que es donde ps añade el entorno")
    }

    /// Las líneas inventadas no prueban que ps acepte esa combinación de opciones, y una
    /// letra de más o de menos deja a Lever sin ver el entorno de nadie: eso se comprueba
    /// contra el sistema de verdad. No se afirma nada sobre lo que haya abierto la máquina;
    /// el estado real del prefijo se imprime como dato, no como condición.
    private static func testTheProbeReallyPrintsEnvironments() async throws {
        let steam = WindowsSteam()
        let result = try await ProcessRunner().run(steam.syncProbeCommand())
        try expect(result.succeeded, "ps rechazó las opciones de la comprobación")
        let lines = result.output.split(separator: "\n").count
        try expect(lines > 20, "con solo \(lines) líneas ps no está mirando más allá del terminal")
        try expect(result.output.contains("PATH="), "ps no está imprimiendo el entorno de los procesos")
        print("INFO WindowsSteam: servidor de Wine del prefijo de Steam = \(steam.syncState(processListing: result.output))")
    }

    /// La comprobación barata pide los procesos sin su entorno: el entorno de todos los
    /// procesos del usuario son cientos de miles de bytes que no hacen falta para saber si
    /// Steam está abierto. Que ps acepte esas opciones se comprueba contra el sistema.
    private static func testTheCheapProbeAlsoFindsTheClient() async throws {
        let steam = WindowsSteam()
        let probe = steam.clientProbeCommand()
        try expect(probe.arguments.contains("axww"),
                   "sin «ax» ps solo ve los procesos del terminal y sin «ww» recorta la línea")
        try expect(!probe.arguments.contains("axeww"),
                   "esta comprobación no necesita el entorno de nadie")

        let result = try await ProcessRunner().run(probe)
        try expect(result.succeeded, "ps rechazó las opciones de la comprobación barata")
        let lines = result.output.split(separator: "\n").count
        try expect(lines > 20, "con solo \(lines) líneas ps no está mirando más allá del terminal")
        try expect(!result.output.contains("PATH="),
                   "esta comprobación no debería imprimir el entorno de los procesos")
        print("INFO WindowsSteam: cliente de Steam ya abierto = "
              + (steam.runningClient(processListing: result.output).map(String.init) ?? "ninguno"))
    }

    // MARK: - Ayudas

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        try expect(value != nil, "se esperaba un valor y llegó nada")
        return value!
    }

    /// Una línea como la que imprime `ps axeww -o pid=,command=`: el PID alineado a la derecha,
    /// después el mandato y al final el entorno, todo separado por espacios.
    private static func psLine(_ pid: Int, _ command: String, _ environment: [(String, String)]) -> String {
        let assignments = environment.map { "\($0.0)=\($0.1)" }
        return ([String(format: "%5d", pid), command] + assignments).joined(separator: " ")
    }
}
