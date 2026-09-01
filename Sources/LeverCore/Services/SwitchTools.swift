import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Un emulador de la consola híbrida instalado en el Mac.
///
/// Se describe por el nombre de su `.app` y por dónde guarda sus llaves. No hay ninguna dirección
/// de descarga, y eso es una decisión, no un olvido: los dos emuladores originales cerraron —uno en
/// marzo de 2024 y el otro en octubre— y lo que sigue vivo son bifurcaciones que aparecen, cambian
/// de nombre y desaparecen. Una dirección fija apuntaría a un enlace roto en unos meses. Lever
/// busca el que haya, como hace con RetroArch y con Wine.
public struct SwitchEmulator: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Nombres del `.app`, en orden de preferencia.
    public let bundleNames: [String]
    /// Carpeta de datos dentro de `Application Support`, que es donde espera el `prod.keys`.
    public let dataFolder: String

    public init(id: String, name: String, bundleNames: [String], dataFolder: String) {
        self.id = id
        self.name = name
        self.bundleNames = bundleNames
        self.dataFolder = dataFolder
    }

    /// Donde este emulador quiere las llaves.
    public func keysFolder(fileManager: FileManager = .default) -> URL {
        let soporte = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return soporte.appendingPathComponent(dataFolder, isDirectory: true)
    }
}

/// Conseguir lo que hace falta para jugar a un juego de la consola híbrida, y lanzarlo.
///
/// La diferencia con `RetroTools` es de fondo, no de detalle: esta consola **no la emula un núcleo
/// de libretro**. No existe. Hace falta un programa entero aparte, que el usuario instala por su
/// cuenta. Lever hace lo mismo que con Wine: lo encuentra, comprueba que está lo que hace falta, y
/// lanza. Lo que no hace es descargarlo ni traerlo dentro.
public enum SwitchTools {
    /// Los emuladores de esta consola que existen para Mac, de más probable a menos.
    ///
    /// Los dos últimos están muertos y se buscan igual: mucha gente los tiene instalados de antes y
    /// siguen abriendo los juegos que abrían. No reconocerlos sería mandar a instalar algo que ya
    /// está ahí.
    public static let known: [SwitchEmulator] = [
        SwitchEmulator(id: "ryujinx", name: "Ryujinx",
                       bundleNames: ["Ryujinx.app", "Ryubing.app"], dataFolder: "Ryujinx"),
        SwitchEmulator(id: "sudachi", name: "Sudachi",
                       bundleNames: ["Sudachi.app", "sudachi.app"], dataFolder: "sudachi"),
        SwitchEmulator(id: "citron", name: "Citron",
                       bundleNames: ["Citron.app", "citron.app"], dataFolder: "citron"),
        SwitchEmulator(id: "eden", name: "Eden",
                       bundleNames: ["Eden.app", "eden.app"], dataFolder: "eden"),
        SwitchEmulator(id: "yuzu", name: "yuzu",
                       bundleNames: ["yuzu.app"], dataFolder: "yuzu")
    ]

    /// Donde acaban las aplicaciones en un Mac.
    static var applicationFolders: [URL] {
        ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
    }

    /// El emulador instalado, si lo hay, con el `.app` donde está.
    public static func locate(
        preferring custom: URL? = nil, fileManager: FileManager = .default
    ) -> (emulator: SwitchEmulator, app: URL)? {
        if let custom, fileManager.fileExists(atPath: custom.path) {
            let nombre = custom.lastPathComponent
            let cuál = known.first { $0.bundleNames.contains { $0.caseInsensitiveCompare(nombre) == .orderedSame } }
            // Uno que el usuario haya señalado a mano vale aunque no esté en la lista: la lista es
            // para encontrarlo solo, no para decidir qué puede usar.
            return (cuál ?? SwitchEmulator(id: "custom", name: custom.deletingPathExtension().lastPathComponent,
                                           bundleNames: [nombre], dataFolder: "Ryujinx"), custom)
        }
        for emulador in known {
            for carpeta in applicationFolders {
                for nombre in emulador.bundleNames {
                    let app = carpeta.appendingPathComponent(nombre)
                    if fileManager.fileExists(atPath: app.path) { return (emulador, app) }
                }
            }
        }
        return nil
    }

    // MARK: - Descomprimir

    /// El `zstd` del sistema. Es el compresor con el que se hicieron los `.nsz`, y no lo trae
    /// macOS: viene con Homebrew. Sin él se puede leer el paquete pero no rehacerlo.
    public static func zstdURL(fileManager: FileManager = .default) -> URL? {
        RuntimeLocator.defaultExecutableCandidates(named: "zstd")
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Saca el flujo comprimido de una pieza y lo descomprime **añadiéndolo** al archivo que se
    /// está construyendo.
    ///
    /// Va por una tubería y no por archivos intermedios: un juego de ocho gigas descomprimido en
    /// un sitio para luego copiarlo a otro son dieciséis gigas de disco que mucha gente no tiene.
    /// Así solo existe el archivo final.
    ///
    /// Los dos recortes son necesarios y por motivos distintos. `tail` salta el trozo del principio
    /// que el compresor deja sin tocar y la tabla de secciones. Y `head` **corta al acabar la
    /// pieza**: sin él, `zstd` seguiría leyendo la pieza siguiente del paquete, la tomaría por otro
    /// flujo pegado detrás y fallaría al final de un trabajo de veinte minutos.
    public static func decompressCommand(
        package: URL, from payloadOffset: Int64, length: Int64, into output: URL, zstd: URL
    ) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            // Los argumentos van como parámetros posicionales y no metidos en el texto: así una
            // ruta con comillas o con espacios no puede cambiar lo que se ejecuta.
            arguments: [
                "-c",
                #"tail -c "+$1" "$2" | head -c "$3" | "$4" -d -c -q >> "$5""#,
                "lever",
                String(payloadOffset + 1),   // `tail -c +N` cuenta desde uno, no desde cero.
                package.path,
                String(length),
                zstd.path,
                output.path
            ],
            currentDirectoryURL: nil,
            environment: ["PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":")]
        )
    }

    // MARK: - Rehacer el paquete

    /// Cuánto va a ocupar el paquete rehecho, para poder avisar antes de empezar.
    public static func rebuiltSize(of facts: SwitchFacts, handle: FileHandle) -> Int64 {
        plan(for: facts, handle: handle).reduce(0) { $0 + $1.size }
            + Int64(PartitionFileSystem.makeHeader(
                files: plan(for: facts, handle: handle).map { ($0.name, $0.size) }
            ).count)
    }

    /// Qué va a llevar el paquete rehecho y cuánto va a medir cada cosa.
    ///
    /// Se sabe **antes** de descomprimir nada, porque la cabecera de cada pieza comprimida dice el
    /// tamaño de la original. Eso es lo que permite escribir la cabecera del paquete primero e ir
    /// añadiendo las piezas detrás, sin dejarlas antes en ningún sitio: el disco solo aguanta el
    /// archivo final, no el doble.
    public static func plan(
        for facts: SwitchFacts, handle: FileHandle
    ) -> [(name: String, size: Int64, source: SwitchEntry, compressed: NczArchive?)] {
        facts.entries.compactMap { entrada in
            guard entrada.isCompressedContent else {
                return (entrada.name, entrada.size, entrada, nil)
            }
            guard let comprimida = NczArchive.read(handle, at: entrada.offset) else { return nil }
            let nombre = String(entrada.name.dropLast(4)) + ".nca"
            return (nombre, comprimida.rebuiltSize, entrada, comprimida)
        }
    }

    /// Rehace un paquete comprimido dejándolo listo para el emulador.
    ///
    /// El resultado es un `.nsp` de verdad, idéntico byte a byte al que se comprimió: las piezas se
    /// descomprimen y se vuelven a cifrar con las llaves que el propio archivo lleva dentro, así
    /// que **no hacen falta las llaves del usuario para esto**.
    ///
    /// Y no se toca el archivo original. Va a una carpeta de Lever, y si ya estaba hecho de una vez
    /// anterior se reutiliza: rehacer ocho gigas dos veces por abrir el mismo juego dos días
    /// seguidos no tiene ninguna gracia.
    public static func rebuild(
        package: URL, facts: SwitchFacts, into folder: URL,
        runner: ProcessRunner, session: ProcessSession, zstd: URL,
        fileManager: FileManager = .default,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let lectura = try? FileHandle(forReadingFrom: package) else {
            throw PortFailure.assemblyFailed(package.lastPathComponent)
        }
        defer { try? lectura.close() }

        let piezas = plan(for: facts, handle: lectura)
        guard !piezas.isEmpty else { throw PortFailure.assemblyFailed(package.lastPathComponent) }

        let cabecera = PartitionFileSystem.makeHeader(files: piezas.map { ($0.name, $0.size) })
        let total = Int64(cabecera.count) + piezas.reduce(0) { $0 + $1.size }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destino = folder.appendingPathComponent(
            package.deletingPathExtension().lastPathComponent + ".nsp"
        )
        // Si ya está hecho y mide lo que tiene que medir, no se vuelve a hacer. El tamaño es la
        // comprobación buena: sale de las cabeceras, no de suponer nada.
        if destino.fileSizeInBytes == total { return destino }

        try? fileManager.removeItem(at: destino)
        try cabecera.write(to: destino)
        guard var escritura = try? FileHandle(forWritingTo: destino) else {
            throw PortFailure.assemblyFailed(destino.lastPathComponent)
        }
        try? escritura.seekToEnd()

        var escrito = Int64(cabecera.count)
        for pieza in piezas {
            let empiezaEn = escrito
            if let comprimida = pieza.compressed {
                // El trozo que el compresor dejó tal cual va primero, copiado tal cual.
                copy(from: lectura, at: pieza.source.offset, count: NczArchive.plainPrefix, to: escritura)
                try? escritura.close()

                let hasta = pieza.source.offset + pieza.source.size
                let orden = decompressCommand(
                    package: package, from: comprimida.payloadOffset,
                    length: hasta - comprimida.payloadOffset, into: destino, zstd: zstd
                )
                let resultado = try await runner.run(orden, session: session)
                guard resultado.succeeded else { throw PortFailure.assemblyFailed(pieza.name) }

                // Y ahora se vuelve a cifrar en el sitio, que es lo que hace que la pieza sea
                // idéntica a la original. Se hace después y no al vuelo porque quien escribe
                // durante la descompresión es `zstd`, no Lever.
                try reencrypt(destino, piece: comprimida, startingAt: empiezaEn)
                guard let reabierta = try? FileHandle(forWritingTo: destino) else {
                    throw PortFailure.assemblyFailed(destino.lastPathComponent)
                }
                escritura = reabierta
                try? escritura.seekToEnd()
            } else {
                copy(from: lectura, at: pieza.source.offset, count: pieza.size, to: escritura)
            }

            escrito += pieza.size
            let hecho = escrito
            onProgress(Double(hecho) / Double(max(total, 1)))
            try Task.checkCancellation()
        }
        try? escritura.close()

        // Si no mide lo previsto, algo salió mal a mitad y el archivo no sirve: mejor no dejarlo,
        // porque la próxima vez se daría por bueno por estar donde tenía que estar.
        guard destino.fileSizeInBytes == total else {
            try? fileManager.removeItem(at: destino)
            throw PortFailure.assemblyFailed(destino.lastPathComponent)
        }
        return destino
    }

    /// Vuelve a cifrar una pieza recién descomprimida, en el sitio y por trozos.
    ///
    /// Por trozos porque una pieza puede pesar varios gigas y no cabe en memoria. Y con el
    /// desplazamiento **dentro de la pieza**, no dentro del archivo: la cuenta del cifrado se
    /// deriva de ahí, y usar el del archivo descifra desde el sitio equivocado sin dar ningún error.
    static func reencrypt(_ file: URL, piece: NczArchive, startingAt pieceStart: Int64) throws {
        guard piece.sections.contains(where: \.isEncrypted) else { return }
        guard let handle = try? FileHandle(forUpdating: file) else {
            throw PortFailure.assemblyFailed(file.lastPathComponent)
        }
        defer { try? handle.close() }

        let porTanda = 4 * 1024 * 1024
        var dentroDeLaPieza = NczArchive.plainPrefix
        let final = piece.rebuiltSize
        while dentroDeLaPieza < final {
            let cuántos = Int(min(Int64(porTanda), final - dentroDeLaPieza))
            guard (try? handle.seek(toOffset: UInt64(pieceStart + dentroDeLaPieza))) != nil,
                  let leído = try? handle.read(upToCount: cuántos), !leído.isEmpty
            else { break }

            let cifrado = piece.encrypt([UInt8](leído), at: dentroDeLaPieza)
            try? handle.seek(toOffset: UInt64(pieceStart + dentroDeLaPieza))
            try? handle.write(contentsOf: Data(cifrado))
            dentroDeLaPieza += Int64(leído.count)
        }
    }

    /// Copia bytes de un archivo a otro sin cargarlos enteros en memoria.
    static func copy(from source: FileHandle, at offset: Int64, count: Int64, to destination: FileHandle) {
        guard count > 0, (try? source.seek(toOffset: UInt64(offset))) != nil else { return }
        let porTanda = 4 * 1024 * 1024
        var quedan = count
        while quedan > 0 {
            let cuántos = Int(min(Int64(porTanda), quedan))
            guard let trozo = try? source.read(upToCount: cuántos), !trozo.isEmpty else { return }
            try? destination.write(contentsOf: trozo)
            quedan -= Int64(trozo.count)
        }
    }

    // MARK: - Lanzar

    /// Abre el juego con el emulador que haya.
    ///
    /// Como app y no como proceso hijo, por lo mismo que RetroArch: un programa con ventana
    /// arrancado con `Process` desde dentro de otra app se queda colgado antes de dibujar nada, sin
    /// dar ningún error. Y así además sale en el Dock y recibe el foco, que es lo que la gente
    /// espera de un juego.
    @MainActor
    public static func open(emulator app: URL, game: URL) throws {
        #if canImport(AppKit)
        let configuración = NSWorkspace.OpenConfiguration()
        configuración.arguments = [game.path]
        configuración.activates = true
        configuración.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuración)
        #endif
    }
}
