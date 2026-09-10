import Foundation
import LeverCore

enum WindowsSteamTests {
    static func run() async throws {
        try testTheInstallationAndItsCommands()
        try testSteamAndTheGameShareTheEngineSynchronization()
        try testItReadsTheSyncOfAServerAlreadyRunning()
        try testTheProbeAsksTheSystemForTheEnvironments()
        try await testTheProbeReallyPrintsEnvironments()
    }

    private static func testTheInstallationAndItsCommands() throws {
        let fixture = try TemporaryFixture()
        let steam = WindowsSteam(root: fixture.directoryURL)
        try expect(!steam.isReady, "un entorno vacío no debe ofrecer abrir Steam")
        for url in [steam.wineURL, steam.steamURL, steam.frameworksURL.appendingPathComponent("libinotify.0.dylib"),
                    steam.prefixURL.appendingPathComponent("drive_c/windows/system32/kernel32.dll")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try expect(steam.isReady, "la instalación preparada debe poder abrirse")
        let command = steam.command()
        try expect(command.executableURL == steam.wineURL, "Steam debe usar su motor, no el Wine global")
        try expect(command.environment?["WINEPREFIX"] == steam.prefixURL.path,
                   "Steam debe conservar su biblioteca y registros en su propio entorno")
        try expect(command.environment?["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(steam.frameworksURL.path) == true,
                   "sin las bibliotecas del motor wineserver falla antes de abrir Steam")
        try expect(command.arguments == [steam.steamURL.path], "las rutas con espacios deben llegar en un solo argumento")
        try FileManager.default.removeItem(at: steam.frameworksURL.appendingPathComponent("libinotify.0.dylib"))
        try expect(!steam.isReady, "un motor sin sus bibliotecas no está preparado")

        let game = steam.superCastilloCommand(showHUD: true)
        try expect(game.executableURL.path.contains("sikarugir-10.0_6-d3dmetal"),
                   "Super Castillo no puede usar el renderizador de Wine que falló en el primer arranque")
        try expect(game.arguments.first?.hasSuffix("/Game/supercastillo.exe") == true,
                   "el modo sin conexión debe abrir el juego, no start_protected_game.exe")
        try expect(game.environment?["SteamAppId"] == "1234567", "el juego debe identificarse ante Steam")
        try expect(game.environment?["WINEPREFIX"] == steam.prefixURL.path,
                   "el juego necesita la sesión legítima y biblioteca de Steam")
        try expect(game.environment?["DYLD_FRAMEWORK_PATH"]?.hasSuffix("/lib/external") == true,
                   "D3DMetal necesita resolver su framework al crear el dispositivo")
        try expect(game.environment?["MTL_HUD_LOG_ENABLED"] == "1", "la medición debe registrar tiempos de cuadro")
        try expect(steam.superCastilloCommand().environment?["MTL_HUD_ENABLED"] == "0",
                   "el uso normal no debe mostrar el HUD de diagnóstico")
        try expect(game.environment?["WINEDLLOVERRIDES"]?.contains("d3d11,d3d12,dxgi=b") == true,
                   "el juego necesita las DLL de D3DMetal, no las de Wine")
    }

    /// Steam y el juego hablan con el mismo servidor de Wine. Si una de las dos órdenes pide
    /// msync y la otra no, el cliente que llega después se queda sin msync: el motor exige
    /// que servidor y clientes coincidan. Por eso la configuración vive en un solo sitio.
    private static func testSteamAndTheGameShareTheEngineSynchronization() throws {
        try expect(WindowsSteam.synchronization["WINEMSYNC"] == "1",
                   "MSync es lo que se midió cerca de 60 FPS; sin la variable no se activa")
        try expect(WindowsSteam.synchronization["WINEESYNC"] == "0",
                   "esync y msync no conviven: hay que apagar el que no se usa")

        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let forSteam = steam.command().environment
        let forGame = steam.superCastilloCommand().environment
        for (name, value) in WindowsSteam.synchronization {
            try expect(forSteam?[name] == value, "Steam debe pedir \(name)=\(value)")
            try expect(forGame?[name] == value, "Super Castillo debe pedir \(name)=\(value)")
        }

        // Lo que de verdad importa no es el valor, sino que nadie pueda cambiar uno y olvidar
        // el otro: las dos órdenes tienen que coincidir variable por variable.
        for name in WindowsSteam.synchronization.keys {
            try expect(forSteam?[name] == forGame?[name],
                       "Steam y el juego difieren en \(name) y comparten servidor")
        }

        // El cambio no debe tocar lo que ya funcionaba.
        try expect(forSteam?["WINEDLLOVERRIDES"] == "mscoree,mshtml=",
                   "Steam no necesita las DLL de D3DMetal")
        try expect(forSteam?["WINEDEBUG"] == "fixme-all,err-hid", "Steam conserva su nivel de registro")
        try expect(forGame?["WINEDEBUG"] == "fixme-all,err-hid", "el juego conserva su nivel de registro")
    }

    /// Un servidor ya en marcha con otra sincronización no se arregla desde Lever sin matarlo,
    /// y matarlo se llevaría la sesión de Steam y una partida sin guardar. Lever solo tiene que
    /// saber distinguir los casos para poder avisar.
    private static func testItReadsTheSyncOfAServerAlreadyRunning() throws {
        // Ruta con espacio, como la real: «Application Support» parte el entorno en varios
        // trozos cuando ps lo imprime, y el análisis tiene que aguantarlo.
        let steam = WindowsSteam(root: URL(fileURLWithPath: "/Users/quien/Library/Application Support/Lever"))
        let server = steam.wineURL.deletingLastPathComponent().appendingPathComponent("wineserver").path
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

    /// Una línea como la que imprime `ps axeww -o pid=,command=`: el PID alineado a la derecha,
    /// después el mandato y al final el entorno, todo separado por espacios.
    private static func psLine(_ pid: Int, _ command: String, _ environment: [(String, String)]) -> String {
        let assignments = environment.map { "\($0.0)=\($0.1)" }
        return ([String(format: "%5d", pid), command] + assignments).joined(separator: " ")
    }
}
