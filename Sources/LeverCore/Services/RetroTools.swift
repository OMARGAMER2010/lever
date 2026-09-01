import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Consigue lo que hace falta para emular: el programa que ejecuta los núcleos y el núcleo de
/// cada máquina.
///
/// La misma idea que con los motores de escritorio: Lever no reimplementa nada. RetroArch es a
/// una ROM lo que Wine es a un `.exe` —el que sabe ejecutarla— y los núcleos de libretro son las
/// piezas que le faltan, publicadas por el propio proyecto. Lever reconoce el archivo, consigue
/// el núcleo que le toca, escribe la configuración y lanza.
public enum RetroTools {
    /// Donde libretro publica los núcleos ya compilados, uno por arquitectura.
    public static func coreURL(core: String, architecture: String) -> URL {
        URL(string: "https://buildbot.libretro.com/nightly/apple/osx/\(architecture)/latest/"
            + "\(core)_libretro.dylib.zip")!
    }

    /// Los sitios donde acaba RetroArch en un Mac, de más probable a menos.
    public static var applicationCandidates: [URL] {
        [
            "/Applications/RetroArch.app",
            NSHomeDirectory() + "/Applications/RetroArch.app",
            "/Applications/RetroArch_Metal.app",
            NSHomeDirectory() + "/Applications/RetroArch_Metal.app"
        ].map { URL(fileURLWithPath: $0) }
    }

    /// El binario de RetroArch, si está instalado.
    public static func locate(fileManager: FileManager = .default) -> URL? {
        applicationCandidates
            .map { $0.appendingPathComponent("Contents/MacOS/RetroArch") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// **La arquitectura que importa es la de RetroArch, no la del Mac.**
    ///
    /// Un núcleo es una librería que RetroArch carga con `dlopen` dentro de su propio proceso, así
    /// que tiene que ser de su misma arquitectura. Y no coinciden por defecto: el RetroArch que
    /// instala Homebrew es de Intel, así que en un Mac con chip Apple pide núcleos de Intel y
    /// rechaza los de ARM con «incompatible architecture». Bajar el del Mac es el error natural y
    /// no da la cara hasta el momento de cargar.
    public static func architecture(of retroarch: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: retroarch) else { return nil }
        defer { try? handle.close() }
        guard let cabecera = try? handle.read(upToCount: 4096), cabecera.count >= 8 else { return nil }
        let bytes = [UInt8](cabecera)

        let magia = readUInt32(bytes, 0)
        // Un binario universal empieza por su índice de arquitecturas, en orden de red.
        if magia == 0xBEBA_FECA || magia == 0xCAFE_BABE {
            let cuantas = Int(bigEndian(bytes, 4))
            guard cuantas > 0, cuantas < 32 else { return nil }
            var tipos: [UInt32] = []
            for índice in 0..<cuantas {
                let entrada = 8 + índice * 20
                guard entrada + 4 <= bytes.count else { break }
                tipos.append(bigEndian(bytes, entrada))
            }
            // Si trae las dos, en un Mac de Apple silicon manda la nativa.
            if tipos.contains(cpuArm64) { return "arm64" }
            if tipos.contains(cpuIntel64) { return "x86_64" }
            return nil
        }

        // Y uno de una sola arquitectura lo dice justo detrás de la marca.
        guard magia == 0xFEED_FACF || magia == 0xFEED_FACE else { return nil }
        switch readUInt32(bytes, 4) {
        case cpuArm64: return "arm64"
        case cpuIntel64: return "x86_64"
        default: return nil
        }
    }

    private static let cpuArm64: UInt32 = 0x0100_000C
    private static let cpuIntel64: UInt32 = 0x0100_0007

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        var valor: UInt32 = 0
        for índice in 0..<4 { valor = (valor << 8) | UInt32(bytes[offset + índice]) }
        return valor
    }

    // MARK: - Conseguir el núcleo

    /// Baja el núcleo si no estaba, y devuelve dónde quedó.
    ///
    /// Se guarda por (núcleo, arquitectura): un Mac puede acabar con las dos si el usuario cambia
    /// de RetroArch, y mezclarlas es justo lo que no se puede hacer.
    public static func ensureCore(
        _ core: String,
        architecture: String,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        onLine: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> URL {
        let carpeta = library.retroCoreURL(architecture: architecture)
        let destino = carpeta.appendingPathComponent("\(core)_libretro.dylib")
        if fileManager.isReadableFile(atPath: destino.path) { return destino }

        try fileManager.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let comprimido = carpeta.appendingPathComponent("\(core).zip")
        defer { try? fileManager.removeItem(at: comprimido) }

        let descarga = try await runner.run(
            PortCommands.download(coreURL(core: core, architecture: architecture), into: comprimido),
            session: session, onLine: onLine
        )
        guard descarga.succeeded else { throw PortFailure.downloadFailed(descarga.exitCode) }
        _ = try? await runner.run(PortCommands.unzip(comprimido, into: carpeta), session: session)

        guard fileManager.isReadableFile(atPath: destino.path) else {
            throw PortFailure.downloadFailed(0)
        }
        // Una librería bajada de internet queda en cuarentena y `dlopen` la rechaza sin decir por
        // qué: parece que el núcleo está roto cuando lo que pasa es que macOS no lo deja abrir.
        _ = try? await runner.run(PortCommands.clearQuarantine(destino), session: session)
        return destino
    }

    // MARK: - Lanzar

    /// Lanza un juego con su núcleo y con la configuración que Lever ha escrito.
    ///
    /// `-c` es la pieza que hace que esto no sea invasivo: RetroArch usa **esa** configuración y no
    /// la del usuario, así que lo que Lever decida sobre controles o ventana no le toca a nadie su
    /// RetroArch de siempre.
    /// Abre RetroArch como app, no como proceso hijo.
    ///
    /// **Y esto no es un detalle de estilo.** Lanzado con `Process` desde dentro de otra app,
    /// RetroArch se queda colgado antes de crear su ventana: el registro se corta después de
    /// cargar el núcleo y el contenido, no da ningún error, y el proceso se queda vivo al 0% de
    /// procesador. Lo mismo lanzado desde una terminal abre el juego. Un programa con ventana hay
    /// que arrancarlo por donde macOS arranca las apps, que es esto, y así además recibe el foco
    /// y sale en el Dock como lo que es.
    ///
    /// A cambio no se sabe cuándo termina la partida: quien la cierra es el usuario, cerrando esa
    /// ventana. Es lo mismo que pasa con el emulador de Android, y es honesto: el juego no es un
    /// paso de Lever, es otro programa.
    @MainActor
    public static func open(
        retroarch: URL, core: URL, rom: URL?, config: URL, log: URL? = nil
    ) throws {
        #if canImport(AppKit)
        // El binario está dentro del `.app`; a LaunchServices hay que darle el bundle.
        let app = retroarch.deletingLastPathComponent()   // …/Contents/MacOS
            .deletingLastPathComponent()                  // …/Contents
            .deletingLastPathComponent()                  // …/RetroArch.app
        let configuración = NSWorkspace.OpenConfiguration()
        configuración.arguments = playCommand(
            retroarch: retroarch, core: core, rom: rom, config: config, log: log
        ).arguments
        configuración.activates = true
        // Sin esto, abrir un segundo juego reutiliza la ventana del primero sin cargar nada.
        configuración.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuración)
        #endif
    }

    public static func playCommand(
        retroarch: URL, core: URL, rom: URL?, config: URL, log: URL? = nil
    ) -> ProcessCommand {
        var argumentos = ["-c", config.path, "-L", core.path]
        // Su registro va a un archivo y no por la salida estándar: lanzado desde una app, RetroArch
        // escribe por una tubería que queda a medio llenar y no se vacía hasta que termina, así
        // que cuando algo falla no se ve **nada**. Con el archivo, el motivo está siempre escrito.
        if let log { argumentos += ["-v", "--log-file", log.path] }
        if let rom { argumentos.append(rom.path) }
        return ProcessCommand(
            executableURL: retroarch,
            arguments: argumentos,
            currentDirectoryURL: rom?.deletingLastPathComponent(),
            environment: ["PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":"),
                          "HOME": NSHomeDirectory()]
        )
    }
}
