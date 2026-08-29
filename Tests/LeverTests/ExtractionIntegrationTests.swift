import Foundation
import LeverCore

/// Pruebas que usan las herramientas reales del sistema.
/// Si no están instaladas, se saltan en vez de fallar: la máquina de otro no tiene por qué tenerlas.
enum ExtractionIntegrationTests {
    static func run() async throws {
        let locator = RuntimeLocator()
        guard let tool = locator.locate().archiveTool else {
            print("SKIP ExtractionIntegrationTests (no hay extractor instalado)")
            return
        }

        try await testRoundTripExtraction(tool: tool, locator: locator)
        try await testSkipPolicyKeepsExistingFile(tool: tool)
        try await testWrongPasswordFailsInsteadOfHanging(tool: tool)
        try await testChosenToolExtractsRarWithoutEmptyFiles(locator: locator)
    }

    /// Comprueba, con un .rar de verdad, que la herramienta elegida por la app saca contenido
    /// real y no archivos de 0 bytes. Es la regresión que motivó preferir `unar` para .rar.
    private static func testChosenToolExtractsRarWithoutEmptyFiles(locator: RuntimeLocator) async throws {
        let status = locator.locate()
        guard status.archiveTools.contains(where: { if case .unar = $0 { return true }; return false }) else {
            print("SKIP prueba de .rar (falta unar)")
            return
        }

        // Busca cualquier .rar del sistema para probar de verdad. Si no hay, se salta.
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/low-poly-trees/source/tree X12 X1 Rock Pack bonus_.rar")
        ]
        guard let sample = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            print("SKIP prueba de .rar (no hay ningún .rar de muestra)")
            return
        }

        let fixture = try TemporaryFixture()
        let destination = fixture.directoryURL.appendingPathComponent("salida", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let tool = status.tool(for: sample) else {
            throw TestFailure(description: "no se eligió herramienta para un .rar")
        }

        let command = ArchiveCommandBuilder.command(for: tool, archive: sample, destination: destination)
        let result = try await ProcessRunner().run(command)
        try expect(result.succeeded, "la herramienta elegida (\(tool.displayName)) debe extraer el .rar")

        let files = FileManager.default
            .enumerator(at: destination, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []

        try expect(!files.isEmpty, "debe extraerse al menos un archivo")
        let empty = files.filter { ($0.fileSizeInBytes ?? 0) == 0 }
        try expect(empty.isEmpty, "ningún archivo debe salir vacío, salieron \(empty.count) de \(files.count)")
    }

    /// Comprime, extrae y comprueba que el contenido llega intacto.
    private static func testRoundTripExtraction(tool: ArchiveTool, locator: RuntimeLocator) async throws {
        let fixture = try TemporaryFixture()
        let source = fixture.directoryURL.appendingPathComponent("origen", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("contenido de prueba".utf8).write(to: source.appendingPathComponent("uno.txt"))

        let archive = fixture.directoryURL.appendingPathComponent("Mi Paquete.zip")
        try await compress(source: source, into: archive)

        let destination = fixture.directoryURL.appendingPathComponent("salida", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)
        let result = try await ProcessRunner().run(command)
        try expect(result.succeeded, "la extracción debe terminar bien: \(result.output)")

        let extracted = destination.appendingPathComponent("uno.txt")
        try expect(
            FileManager.default.fileExists(atPath: extracted.path),
            "el archivo debe aparecer en el destino"
        )
        try expect(
            (try? String(contentsOf: extracted, encoding: .utf8)) == "contenido de prueba",
            "el contenido debe llegar intacto"
        )
        try expect(
            FileManager.default.fileExists(atPath: archive.path),
            "el comprimido original no debe borrarse nunca"
        )

        // Y el listado debe leer los mismos nombres sin extraer nada.
        let lister = locator.listerURL(for: tool)
        if let listCommand = ArchiveCommandBuilder.listCommand(for: tool, lister: lister, archive: archive) {
            let listing = try await ProcessRunner().run(listCommand)
            let names = ArchiveCommandBuilder.names(fromListing: listing.output, usedLister: lister != nil)
            try expect(names.contains { $0.hasSuffix("uno.txt") }, "el listado debe incluir uno.txt, obtuvo \(names)")
        }
    }

    /// Con la política por defecto, un archivo que ya existe no se pisa.
    private static func testSkipPolicyKeepsExistingFile(tool: ArchiveTool) async throws {
        let fixture = try TemporaryFixture()
        let source = fixture.directoryURL.appendingPathComponent("origen", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("del comprimido".utf8).write(to: source.appendingPathComponent("uno.txt"))

        let archive = fixture.directoryURL.appendingPathComponent("paquete.zip")
        try await compress(source: source, into: archive)

        let destination = fixture.directoryURL.appendingPathComponent("salida", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("uno.txt")
        try Data("mío, no tocar".utf8).write(to: existing)

        let command = ArchiveCommandBuilder.command(
            for: tool, archive: archive, destination: destination, policy: .skip
        )
        _ = try await ProcessRunner().run(command)

        try expect(
            (try? String(contentsOf: existing, encoding: .utf8)) == "mío, no tocar",
            "con la política «conservar», el archivo existente no debe cambiar"
        )
    }

    /// Un comprimido con contraseña debe fallar con un error, nunca quedarse esperando entrada.
    private static func testWrongPasswordFailsInsteadOfHanging(tool: ArchiveTool) async throws {
        guard case .sevenZip(let sevenZip) = tool else { return }

        let fixture = try TemporaryFixture()
        let source = fixture.directoryURL.appendingPathComponent("origen", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("secreto".utf8).write(to: source.appendingPathComponent("uno.txt"))

        let archive = fixture.directoryURL.appendingPathComponent("cerrado.7z")
        let pack = ProcessCommand(
            executableURL: sevenZip,
            arguments: ["a", "-p1234", "-mhe=on", archive.path, source.path + "/."],
            currentDirectoryURL: fixture.directoryURL
        )
        _ = try await ProcessRunner().run(pack)

        let destination = fixture.directoryURL.appendingPathComponent("salida", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Sin contraseña: debe terminar con error, y sobre todo debe TERMINAR.
        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)
        let result = try await withTimeout(seconds: 20) {
            try await ProcessRunner().run(command)
        }
        try expect(!result.succeeded, "sin la contraseña correcta la extracción debe fallar")

        // Con la contraseña correcta: debe salir el archivo.
        let good = ArchiveCommandBuilder.command(
            for: tool, archive: archive, destination: destination, password: "1234"
        )
        let ok = try await ProcessRunner().run(good)
        try expect(ok.succeeded, "con la contraseña correcta debe extraer: \(ok.output)")
    }

    // MARK: - Utilidades

    private static func compress(source: URL, into archive: URL) async throws {
        let locator = RuntimeLocator()
        guard case .sevenZip(let sevenZip)? = locator.locate().archiveTool else {
            // Sin 7zz se usa `zip`, presente en cualquier macOS.
            let command = ProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
                arguments: ["-r", "-q", archive.path, "."],
                currentDirectoryURL: source
            )
            _ = try await ProcessRunner().run(command)
            return
        }

        let command = ProcessCommand(
            executableURL: sevenZip,
            arguments: ["a", "-bso0", "-bsp0", archive.path, source.path + "/."],
            currentDirectoryURL: source
        )
        _ = try await ProcessRunner().run(command)
    }

    /// Corta la espera si el proceso se cuelga, para que la prueba falle en vez de bloquearse.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestFailure(description: "el proceso se quedó colgado más de \(Int(seconds)) s")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
