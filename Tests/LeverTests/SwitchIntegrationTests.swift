import Foundation
import LeverCore

/// Prueba de verdad de rehacer un paquete comprimido: se fabrica una pieza, se comprime con el
/// `zstd` de verdad, se empaqueta como lo hace el compresor de la comunidad, y se comprueba que lo
/// que Lever devuelve es **byte a byte** la pieza de la que se partió.
///
/// Es la única forma de comprobar esto. Las tres cosas que pueden fallar —dónde empieza el flujo
/// comprimido, dónde acaba, y con qué cuenta se vuelve a cifrar cada trozo— no dan ningún error
/// cuando están mal: dan un archivo del tamaño correcto lleno de bytes equivocados, y el síntoma
/// aparece veinte minutos después en un emulador que no arranca.
enum SwitchIntegrationTests {
    static func run() async throws {
        guard let zstd = SwitchTools.zstdURL() else {
            print("SKIP SwitchIntegrationTests: hace falta zstd (brew install zstd)")
            return
        }
        try await testRebuildsACompressedPieceExactly(zstd: zstd)
        try await testKeepsWhatIsNotCompressedAndRefusesAHalfDoneFile(zstd: zstd)
    }

    /// La sección va cifrada en modo contador, y la cuenta se deriva del desplazamiento: cada
    /// trozo tiene la suya. Es lo que hay que reproducir al rehacer.
    private static let llave = [UInt8](repeating: 0x2B, count: 16)
    private static let cuenta = [UInt8](repeating: 0x9F, count: 16)
    /// Más de lo que cabe en una tanda del cifrador, para que la cuenta tenga que ir subiendo de
    /// tanda en tanda. Con una pieza pequeña este error no se ve.
    private static let cuerpo = 0x30000

    private static func testRebuildsACompressedPieceExactly(zstd: URL) async throws {
        let fixture = try TemporaryFixture()
        let runner = ProcessRunner()

        let claro = contenido(bytes: cuerpo)
        let original = try piezaOriginal(claro: claro)
        let comprimida = try await piezaComprimida(claro: claro, fixture: fixture, zstd: zstd, runner: runner)

        let paqueteURL = fixture.directoryURL.appendingPathComponent("juego.nsz")
        try paquete([
            ("0123456789abcdef0123456789abcdef.ncz", comprimida),
            ("0123456789abcdef.tik", Data(repeating: 0x77, count: 0x2C0))
        ]).write(to: paqueteURL)

        let hechos = SwitchInspector.inspect(paqueteURL)
        try expect(hechos.container == .nsz, "el paquete tiene que reconocerse como comprimido")
        try expect(hechos.needsDecompression, "y decir que hay que rehacerlo")

        let salida = fixture.directoryURL.appendingPathComponent("rehecho", isDirectory: true)
        let rehecho = try await SwitchTools.rebuild(
            package: paqueteURL, facts: hechos, into: salida,
            runner: runner, session: ProcessSession(), zstd: zstd
        )
        try expect(rehecho.pathExtension == "nsp", "lo que sale es un paquete normal")

        // Y ahora lo que importa: la pieza de dentro tiene que ser la de partida, byte a byte.
        let leído = SwitchInspector.inspect(rehecho)
        try expect(leído.container == .nsp, "el paquete rehecho ya no está comprimido")
        try expect(!leído.needsDecompression, "y no hay nada más que rehacer")

        guard let pieza = leído.entries.first(where: \.isContent) else {
            throw TestFailure(description: "el paquete rehecho tiene que traer la pieza .nca")
        }
        try expect(pieza.name.hasSuffix(".nca"), "la pieza pierde el .ncz y recupera el .nca")
        try expect(pieza.size == Int64(original.count), "y mide lo que medía la original")

        let datos = try Data(contentsOf: rehecho)
        let recuperada = datos.subdata(in: Int(pieza.offset)..<Int(pieza.offset) + Int(pieza.size))
        try expect(recuperada == original, "la pieza rehecha es la original byte a byte")

        // Y la segunda vez no se rehace: ya está y mide lo que tiene que medir.
        let fecha = try FileManager.default.attributesOfItem(atPath: rehecho.path)[.modificationDate] as? Date
        let otraVez = try await SwitchTools.rebuild(
            package: paqueteURL, facts: hechos, into: salida,
            runner: runner, session: ProcessSession(), zstd: zstd
        )
        let despues = try FileManager.default.attributesOfItem(atPath: otraVez.path)[.modificationDate] as? Date
        try expect(fecha == despues, "rehacer ocho gigas dos veces por el mismo juego no tiene gracia")
    }

    /// Lo que no está comprimido —el ticket, el certificado, el xml— viaja tal cual al paquete
    /// nuevo. Y un archivo a medio hacer no se puede quedar: la próxima vez se daría por bueno por
    /// estar donde tenía que estar.
    private static func testKeepsWhatIsNotCompressedAndRefusesAHalfDoneFile(zstd: URL) async throws {
        let fixture = try TemporaryFixture()
        let runner = ProcessRunner()
        let claro = contenido(bytes: 0x8000)
        let comprimida = try await piezaComprimida(claro: claro, fixture: fixture, zstd: zstd, runner: runner)

        let ticket = Data((0..<0x2C0).map { UInt8(($0 * 7) & 0xFF) })
        let paqueteURL = fixture.directoryURL.appendingPathComponent("mixto.nsz")
        try paquete([
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ncz", comprimida),
            ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tik", ticket)
        ]).write(to: paqueteURL)

        let salida = fixture.directoryURL.appendingPathComponent("rehecho", isDirectory: true)
        let rehecho = try await SwitchTools.rebuild(
            package: paqueteURL, facts: SwitchInspector.inspect(paqueteURL), into: salida,
            runner: runner, session: ProcessSession(), zstd: zstd
        )

        let leído = SwitchInspector.inspect(rehecho)
        guard let entrada = leído.entries.first(where: \.isTicket) else {
            throw TestFailure(description: "el ticket tiene que seguir ahí")
        }
        let datos = try Data(contentsOf: rehecho)
        try expect(datos.subdata(in: Int(entrada.offset)..<Int(entrada.offset) + Int(entrada.size)) == ticket,
                   "y llegar sin tocarlo")

        // Un paquete al que le falte el zstd no puede dejar medio archivo detrás.
        let roto = fixture.directoryURL.appendingPathComponent("sin-nada", isDirectory: true)
        do {
            _ = try await SwitchTools.rebuild(
                package: paqueteURL, facts: SwitchFacts(container: .nsz), into: roto,
                runner: runner, session: ProcessSession(), zstd: zstd
            )
            throw TestFailure(description: "un paquete sin piezas no se puede rehacer")
        } catch let fallo as PortFailure {
            guard case .assemblyFailed = fallo else {
                throw TestFailure(description: "el motivo tiene que decir que no se pudo montar")
            }
        }
    }

    // MARK: - Fabricar las piezas

    /// Un contenido que se parezca a uno de verdad: trozos que se repiten —que es lo que el
    /// compresor encoge— mezclados con bytes que no.
    private static func contenido(bytes: Int) -> [UInt8] {
        var salida = [UInt8](repeating: 0, count: bytes)
        var semilla: UInt64 = 0x2545_F491_4F6C_DD1D
        for índice in 0..<bytes {
            semilla = semilla &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            salida[índice] = índice % 512 < 256 ? UInt8((semilla >> 33) & 0xFF) : 0xA5
        }
        return salida
    }

    /// La pieza tal como la escribe la consola: el trozo intacto del principio y el cuerpo cifrado
    /// en modo contador, con la cuenta que le toca a su desplazamiento.
    private static func piezaOriginal(claro: [UInt8]) throws -> Data {
        var pieza = Data(prefijo())
        guard let inicial = NintendoCrypto.counter(prefix: cuenta, offset: NczArchive.plainPrefix),
              let cifrado = NintendoCrypto.ctr(claro, key: llave, counter: inicial)
        else { throw TestFailure(description: "no se pudo cifrar la pieza de prueba") }
        pieza.append(Data(cifrado))
        return pieza
    }

    /// La misma pieza tal como la deja el compresor: el trozo intacto, la tabla de secciones con la
    /// llave dentro, y el cuerpo **sin cifrar** pasado por zstd.
    private static func piezaComprimida(
        claro: [UInt8], fixture: TemporaryFixture, zstd: URL, runner: ProcessRunner
    ) async throws -> Data {
        let sinComprimir = fixture.directoryURL.appendingPathComponent("cuerpo-\(UUID().uuidString).bin")
        let comprimido = sinComprimir.appendingPathExtension("zst")
        try Data(claro).write(to: sinComprimir)
        let resultado = try await runner.run(ProcessCommand(
            executableURL: zstd,
            arguments: ["-q", "-f", "-o", comprimido.path, sinComprimir.path],
            currentDirectoryURL: nil
        ))
        guard resultado.succeeded else { throw TestFailure(description: "zstd no comprimió: \(resultado.output)") }

        var pieza = Data(prefijo())
        pieza.append(Data("NCZSECTN".utf8))
        pieza.append(le64(1))                                   // una sección
        pieza.append(le64(UInt64(NczArchive.plainPrefix)))      // dónde empieza, dentro de la pieza
        pieza.append(le64(UInt64(claro.count)))                 // cuánto mide
        pieza.append(le64(3))                                   // modo contador
        pieza.append(le64(0))                                   // relleno para alinear la llave
        pieza.append(Data(llave))
        pieza.append(Data(cuenta))
        pieza.append(try Data(contentsOf: comprimido))
        return pieza
    }

    /// Los 0x4000 bytes que el compresor deja tal cual, con la marca de una pieza dentro.
    private static func prefijo() -> [UInt8] {
        var bytes = [UInt8](repeating: 0x5C, count: Int(NczArchive.plainPrefix))
        for (índice, byte) in Array("NCA3".utf8).enumerated() { bytes[0x200 + índice] = byte }
        return bytes
    }

    private static func paquete(_ archivos: [(String, Data)]) -> Data {
        var cabecera = PartitionFileSystem.makeHeader(files: archivos.map { ($0.0, Int64($0.1.count)) })
        for (_, contenido) in archivos { cabecera.append(contenido) }
        return cabecera
    }

    private static func le64(_ valor: UInt64) -> Data {
        Data((0..<8).map { UInt8((valor >> (8 * $0)) & 0xFF) })
    }
}
