import Foundation
import LeverCore

/// Una sesión de Windows aislada de verdad, con Wine. Tarda (crea un Windows la primera vez), así
/// que solo corre con `LEVER_WINE_TESTS=1`.
enum SafeWineIntegrationTests {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["LEVER_WINE_TESTS"] == "1" else {
            print("SKIP SafeWineIntegrationTests: define LEVER_WINE_TESTS=1 (tarda un par de minutos)")
            return
        }
        let requestedWine = ProcessInfo.processInfo.environment["LEVER_TEST_WINE"].map { URL(fileURLWithPath: $0) }
        guard let wine = requestedWine ?? RuntimeLocator().locate().wineURL, await Sandbox.checkAvailability() == .available else {
            print("SKIP SafeWineIntegrationTests (sin Wine o sin aislamiento)")
            return
        }
        let fixture = try TemporaryFixture()
        let fileManager = FileManager.default
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let outside = fixture.directoryURL.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secreto".utf8).write(to: outside.appendingPathComponent("secreto.txt"))
        // Ruta de Windows a una carpeta de macOS, ya escapada para ir dentro de una cadena de JScript.
        let unixOutside = ("\\\\?\\unix" + (try SandboxPath.canonical(outside)).replacingOccurrences(of: "/", with: "\\"))
            .replacingOccurrences(of: "\\", with: "\\\\")

        let source = fixture.directoryURL.appendingPathComponent("Juego", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        var fso = new ActiveXObject("Scripting.FileSystemObject");
        var log = fso.CreateTextFile("C:\\\\resultado.txt", true);
        function tryWrite(p) { try { var f = fso.CreateTextFile(p, true); f.Close(); log.WriteLine("FUGA_ESCRITURA " + p); } catch (e) {} }
        function tryRead(p) { try { var f = fso.OpenTextFile(p, 1); f.ReadAll(); log.WriteLine("FUGA_LECTURA " + p); } catch (e) {} }
        tryWrite("\(unixOutside)\\\\escape.txt");
        tryRead("\(unixOutside)\\\\secreto.txt");
        tryWrite("Z:\\\\tmp\\\\lever-z.txt");
        try { var h = new ActiveXObject("WinHttp.WinHttpRequest.5.1"); h.SetTimeouts(3000,3000,3000,3000); h.Open("GET", "http://1.1.1.1/", false); h.Send(); log.WriteLine("FUGA_RED " + h.Status); } catch (e) {}
        var here = fso.CreateTextFile("D:\\\\Juego\\\\partida.sav", true); here.Close();
        log.WriteLine("FIN");
        log.Close();
        """.utf8).write(to: source.appendingPathComponent("sonda.js"))
        let batch = source.appendingPathComponent("sonda.bat")
        try Data("@echo off\r\ncscript //nologo D:\\Juego\\sonda.js\r\n".utf8).write(to: batch)

        let runner = SafeWindowsRunner(runner: ProcessRunner(), base: base)
        let (workspace, program) = try runner.workspace(for: batch)
        let filesReal = try SandboxPath.canonical(workspace.files)
        try expect(program.path.hasPrefix(filesReal), "el programa se ejecuta desde su clon")
        let lines = LineCollector()
        let outcome: SafeRunOutcome
        do {
            outcome = try await runner.run(program: program, in: workspace, wine: wine, allowsNetwork: false,
                                          session: ProcessSession(), onStage: { _ in }, onLine: { lines.add($0) })
        } catch {
            throw TestFailure(description: "SafeWineIntegration: \(error) · \(lines.text)")
        }

        let result = (try? String(contentsOf: workspace.windows.appendingPathComponent("drive_c/resultado.txt"),
                                  encoding: .utf8)) ?? ""
        try expect(result.contains("FIN"),
                   "el script de Windows corrió dentro del aislamiento: \(result) (\(outcome.exitCode)) \(lines.text)")
        try expect(!result.contains("FUGA"), "nada de lo que intentó fuera funcionó: \(result)")
        try expect(fileManager.fileExists(atPath: workspace.files.appendingPathComponent("Juego/partida.sav").path),
                   "lo que escribe en D: se queda en el espacio")
        let outsideContents = try fileManager.contentsOfDirectory(atPath: outside.path)
        try expect(outsideContents == ["secreto.txt"], "fuera no aparece nada: \(outsideContents)")
        let devices = try fileManager.contentsOfDirectory(atPath: workspace.windows.appendingPathComponent("dosdevices").path)
        try expect(Set(devices) == ["c:", "d:"], "solo existen C: y D:: \(devices)")
        try expect(!fileManager.fileExists(atPath: source.appendingPathComponent("partida.sav").path), "el original no se toca")
        try expect(!fileManager.fileExists(atPath: workspace.engine.path), "el motor temporal se borra")
        try expect(SafeProcessTracker.processes(executableUnder: workspace.engine).isEmpty, "y no queda ningún proceso")
    }
}

/// Junta la salida de un proceso para enseñarla si una prueba falla.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(25).joined(separator: " | ")
    }
}
