import AppKit
import Darwin
import Foundation
import LeverCore

/// Safe Mode contra el sistema de verdad: `sandbox-exec`, los extractores instalados y procesos
/// que intentan salirse. Lo que se comprueba siempre es el efecto **fuera** del aislamiento, no lo
/// que diga la herramienta.
enum SafeModeIntegrationTests {
    static func run() async throws {
        guard await Sandbox.checkAvailability() == .available else {
            print("SKIP SafeModeIntegrationTests (sandbox-exec no aplica aislamiento aquí)")
            return
        }
        try await testFileSizeLimitIsEnforcedByTheKernel()
        try await testWatchdogStopsTheProcess()
        try await testWorkspaceDeletionStaysInsideItsBase()
        try await testSweepLeavesContentInert()
        try await testWindowsSessionProfileContainsTheProcessTree()

        let locator = RuntimeLocator()
        let tools = locator.locate().archiveTools
        guard !tools.isEmpty else {
            print("SKIP extracción de Safe Mode (no hay extractor instalado)")
            return
        }
        let unar = tools.first { if case .unar = $0 { return true }; return false }
        let lister = unar.flatMap { locator.listerURL(for: $0) }
        try await testHostileArchivesCannotWriteOutside(tools: tools, lister: lister)
        try await testCancelledOrBrokenExtractionLeavesNothingBehind(tools: tools, lister: lister)
        try await testSameArchiveNeverGetsTwoSpacesByAccident(tools: tools, lister: lister)
        try await testKnownThreatIsReportedWhenAScannerExists(tools: tools, lister: lister)
    }

    // MARK: - Límites

    private static func testFileSizeLimitIsEnforcedByTheKernel() async throws {
        let fixture = try TemporaryFixture()
        let profileURL = fixture.directoryURL.appendingPathComponent("p.sb")
        let out = fixture.directoryURL.appendingPathComponent("grande.bin")
        try Sandbox.write(SandboxProfile(text: """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process-exec (literal "/bin/dd"))
        (allow file-read* file-map-executable (literal "/bin/dd"))
        (allow file-read* file-write* (subpath "\(try SandboxPath.canonical(fixture.directoryURL))"))
        """), to: profileURL)
        let command = Sandbox.command(
            ProcessCommand(executableURL: URL(fileURLWithPath: "/bin/dd"),
                           arguments: ["if=/dev/zero", "of=\(out.path)", "bs=1048576", "count=8"],
                           currentDirectoryURL: nil),
            profileURL: profileURL, environment: Sandbox.minimalEnvironment(temporary: nil),
            fileSizeLimit: 1_048_576)
        let result = try await ProcessRunner().run(command)
        try expect(result.endedBySignal && result.exitCode == SIGXFSZ,
                   "pasar del límite por archivo termina con SIGXFSZ: \(result.exitCode) \(result.output)")
        try expect((out.fileSizeInBytes ?? 0) <= 1_048_576, "y el archivo no pasa del límite")
    }

    private static func testWatchdogStopsTheProcess() async throws {
        let session = ProcessSession()
        let watchdog = ResourceWatchdog(session: session, volume: FileManager.default.temporaryDirectory,
                                        maximumBytesWritten: nil, maximumFootprint: 1)
        watchdog.start(interval: .milliseconds(50))
        let started = ContinuousClock.now
        let result = try await ProcessRunner().run(
            ProcessCommand(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], currentDirectoryURL: nil),
            session: session)
        watchdog.stop()
        try expect(watchdog.tripped == .memory, "con un techo de memoria imposible, la vigilancia corta")
        try expect(!result.succeeded && ContinuousClock.now - started < .seconds(10), "y el proceso no llega al final")
    }

    private static func testWorkspaceDeletionStaysInsideItsBase() async throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let outsider = try fixture.makeFile(named: "no-tocar.txt")
        var threw = false
        do { try SafeWorkspace.removeTree(at: fixture.directoryURL, confinedTo: base) } catch { threw = true }
        try expect(threw && FileManager.default.fileExists(atPath: outsider.path), "nunca se borra fuera de la base")

        let workspace = try SafeWorkspace.create(origin: SafeWorkspaceOrigin(kind: .archive, path: "/x"), base: base)
        let locked = workspace.files.appendingPathComponent("cerrada/honda", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("a.txt"))
        let link = workspace.files.appendingPathComponent("enlace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directoryURL)
        chmod(locked.path, 0o500)
        chmod(locked.deletingLastPathComponent().path, 0o000)
        try workspace.delete(base: base)
        try expect(!FileManager.default.fileExists(atPath: workspace.root.path), "se borra aunque haya carpetas sin permisos")
        try expect(FileManager.default.fileExists(atPath: outsider.path), "y el destino del enlace sigue en su sitio")
        try expect(SafeWorkspace.all(base: base).isEmpty, "no queda ningún espacio")
    }

    // MARK: - Barrido

    private static func testSweepLeavesContentInert() async throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("files", isDirectory: true)
        let bin = root.appendingPathComponent("Juego/Binaries/Win64", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try SafeModeFixtures.peExecutable().write(to: bin.appendingPathComponent("Juego.exe"))
        try SafeModeFixtures.peExecutable(isDLL: true).write(to: bin.appendingPathComponent("winmm.dll"))
        try SafeModeFixtures.peExecutable(signed: true).write(to: root.appendingPathComponent("setup.exe"))
        let script = root.appendingPathComponent("instalar.sh")
        try Data("#!/bin/sh\nlaunchctl load ~/Library/LaunchAgents/x.plist\n".utf8).write(to: script)
        chmod(script.path, 0o4777)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: root.appendingPathComponent("herramienta"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("fuera"), withDestinationURL: fixture.directoryURL)
        let original = try fixture.makeFile(named: "original.txt")
        link(original.path, root.appendingPathComponent("duro.txt").path)

        let result = SafeContentScanner.sweep(root: root)
        let kinds = Set(result.findings.map(\.kind))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fuera").path)
                   && (try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("fuera").path)) == nil,
                   "el enlace que salía fuera ya no está")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("duro.txt").path)
                   && FileManager.default.fileExists(atPath: original.path), "el enlace duro se rompe sin tocar el original")
        for kind: SafeFindingKind in [.blockedLink, .dllSideLoading, .riskyScript, .macProgram, .setIDBit, .windowsInstaller] {
            try expect(kinds.contains(kind), "el barrido debe señalar \(kind.rawValue): \(kinds)")
        }
        var info = stat()
        stat(script.path, &info)
        try expect(info.st_mode & 0o7111 == 0, "sin ejecución ni setuid: \(String(info.st_mode, radix: 8))")
        stat(root.appendingPathComponent("herramienta").path, &info)
        try expect(info.st_mode & 0o111 == 0, "un binario de macOS extraído no se puede ejecutar")
        let quarantined = getxattr(root.appendingPathComponent("herramienta").path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        try expect(quarantined > 0, "y queda en cuarentena para Gatekeeper")

        let game = result.executables.first { $0.name == "Juego.exe" }
        try expect(game?.architecture == "x64" && game?.isInstaller == false && game?.sha256?.count == 64,
                   "el juego sale en el inventario con su arquitectura y su huella: \(result.executables)")
        try expect(result.executables.first?.name == "Juego.exe", "los juegos van antes que los instaladores")
        try expect(result.executables.first { $0.name == "setup.exe" }?.hasSignature == true, "se dice si trae firma")
    }

    // MARK: - Sesión de Windows

    /// El perfil de las sesiones de Windows, con la sonda hostil clonada en un «motor» falso en
    /// lugar de Wine: lo que se prueba es la frontera, no Wine.
    private static func testWindowsSessionProfileContainsTheProcessTree() async throws {
        let fixture = try TemporaryFixture()
        let fileManager = FileManager.default
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let workspace = try SafeWorkspace.create(origin: SafeWorkspaceOrigin(kind: .program, path: "/x"), base: base)
        try workspace.prepareRunDirectories()
        let engine = workspace.engine
        try fileManager.createDirectory(at: engine, withIntermediateDirectories: true)
        let probe = engine.appendingPathComponent("probe")
        let me = URL(fileURLWithPath: try SandboxPath.canonical(URL(fileURLWithPath: CommandLine.arguments[0])))
        try fileManager.copyItem(at: me, to: probe)
        let outside = fixture.directoryURL.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secreto".utf8).write(to: outside.appendingPathComponent("secreto.txt"))

        let uid = getuid()
        let spec = WindowsSandboxSpec(
            engine: engine, workspaceRoot: workspace.root,
            writableDirectories: [workspace.files, workspace.home, workspace.temporary],
            serverDirectory: "/private/tmp/.wine-\(uid)/server-0-0", serverName: "/tmp/.wine-\(uid)/server-0-0",
            userID: uid, allowsNetwork: false)
        let profileURL = workspace.control.appendingPathComponent("windows.sb")
        try Sandbox.write(try SandboxProfile.windowsSession(spec), to: profileURL)

        let chessWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Chess").isEmpty
        let result = try await ProcessRunner().run(Sandbox.command(
            ProcessCommand(executableURL: probe,
                           arguments: [SafeModeProbe.flag, "escape", workspace.files.path, outside.path],
                           currentDirectoryURL: workspace.files),
            profileURL: profileURL,
            environment: ["PATH": engine.path, "HOME": workspace.home.path, "TMPDIR": workspace.temporary.path + "/",
                          "DYLD_FALLBACK_LIBRARY_PATH": engine.path + "/support"]))

        try expect(result.output.contains("DENTRO_OK") && result.output.contains("FIN"),
                   "dentro del espacio se trabaja con normalidad: [\(result.exitCode)] \(result.output.suffix(600))")
        try expect(result.output.contains("DLL_PATH=" + engine.path + "/support"),
                   "las rutas de bibliotecas deben llegar al motor pese al filtrado de DYLD que hace macOS")
        for leak in ["FUGA_ESCRITURA", "FUGA_LECTURA", "FUGA_DOCUMENTOS", "FUGA_RED_IP", "FUGA_RED_DNS", "FUGA_EXEC",
                     "FUGA_HIJO", "FUGA_LANZABLE", "FUGA_LAUNCHSERVICES", "FUGA_URL", "FUGA_PORTAPAPELES",
                     "FUGA_ENLACE_ESCRITURA", "FUGA_ENLACE_LECTURA", "FUGA_ENLACE_LISTADO", "FUGA_ENLACE_DURO",
                     "FUGA_ENLACE_CASA", "FUGA_RUTA_RELATIVA", "FUGA_RUTA_RELATIVA_LECTURA", "FUGA_RUTA_ABSOLUTA",
                     "FUGA_TMP_COMPARTIDO"] {
            try expect(!result.output.contains(leak), "\(leak): el aislamiento no debe permitirlo")
        }
        // Y nada que empiece por FUGA, aunque la sonda aprenda trucos nuevos y aquí no se listen.
        let leaked = result.output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("FUGA") }
        try expect(leaked.isEmpty, "fugas no contempladas: \(leaked)")
        let outsideContents = try fileManager.contentsOfDirectory(atPath: outside.path)
        try expect(outsideContents == ["secreto.txt"], "fuera no aparece nada: \(outsideContents)")
        // Crear un enlace dentro del espacio sí se permite: Wine lo necesita para sus unidades. Lo
        // que no puede es servir de puente, que es lo que comprueban las fugas de arriba. Si algún
        // día el perfil lo prohíbe, esta línea avisa de que el comentario hay que cambiarlo.
        if !result.output.contains("ENLACE_CREADO") {
            print("NOTA: el perfil de Windows ya no deja crear enlaces dentro del espacio")
        }

        await Task.yield()
        let opened = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Chess")
        if !chessWasRunning, !opened.isEmpty {
            opened.forEach { $0.forceTerminate() }
            throw TestFailure(description: "LaunchServices abrió Ajedrez desde el aislamiento")
        }

        let orphans = SafeProcessTracker.processes(executableUnder: engine)
        try expect(orphans.count == 1, "el proceso desligado de su padre se encuentra por su ejecutable: \(orphans)")
        try expect(!SafeProcessTracker.processes(executableUnder: engine).contains(getpid()), "y nunca el propio Lever")
        await SafeProcessTracker.terminate(executableUnder: engine, grace: .milliseconds(500))
        try expect(SafeProcessTracker.processes(executableUnder: engine).isEmpty, "y se cierra")
    }

    // MARK: - Extracción

    private static func testHostileArchivesCannotWriteOutside(tools: [ArchiveTool], lister: URL?) async throws {
        let fixture = try TemporaryFixture()
        let fileManager = FileManager.default
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let outside = fixture.directoryURL.appendingPathComponent("outside", isDirectory: true)
        let archives = fixture.directoryURL.appendingPathComponent("archives", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archives, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.txt")
        try Data("original".utf8).write(to: victim)
        let outsideReal = try SandboxPath.canonical(outside)

        let cases: [(name: String, data: Data, expected: SafeFindingKind?)] = [
            ("normal.zip", SafeModeFixtures.zip([.file("juego/leeme.txt", "hola"),
                                                 SafeModeFixtures.ZipEntry(name: "juego/juego.exe", data: SafeModeFixtures.peExecutable())]), nil),
            ("Disfrazado.rar", SafeModeFixtures.zip([.file("dentro.txt", "zip con nombre de rar")]), .extensionMismatch),
            ("traversal.zip", SafeModeFixtures.zip([.file("ok.txt", "ok"), .file("../../../outside/traversal.txt", "PWNED")]), .pathTraversal),
            ("absolute.zip", SafeModeFixtures.zip([.file(outsideReal + "/absolute.txt", "PWNED")]), .absolutePath),
            ("symlink.zip", SafeModeFixtures.zip([.symlink("link", to: outsideReal), .file("link/through.txt", "PWNED")]), .symbolicLink),
            ("symlink.tar", SafeModeFixtures.tar([.symlink("dirlink", target: outsideReal), .file("dirlink/through.txt", "PWNED")]), .symbolicLink),
            ("hardlink.tar", SafeModeFixtures.tar([.hardlink("hl", target: victim.path)]), .hardLink)
        ]

        let extractor = SafeExtractor(runner: ProcessRunner(), base: base, scanner: nil)
        for item in cases {
            let archive = archives.appendingPathComponent(item.name)
            try item.data.write(to: archive)
            var outcome: SafeExtractionOutcome?
            do {
                outcome = try await extractor.extract(
                    archive: archive, tools: tools, lister: lister, password: nil, session: ProcessSession(),
                    onStage: { _ in }, onProgress: { _ in }, onLine: { _ in })
            } catch SafeExtractionError.toolFailed {
                // Un extractor puede negarse del todo a un archivo tan roto; también es aceptable.
            }

            let leaked = try fileManager.contentsOfDirectory(atPath: outside.path).filter { $0 != "victim.txt" }
            try expect(leaked.isEmpty, "\(item.name): nada debe aparecer fuera, apareció \(leaked)")
            try expect((try? String(contentsOf: victim, encoding: .utf8)) == "original", "\(item.name): la víctima no cambia")

            guard let outcome else { continue }
            let links = (fileManager.enumerator(atPath: outcome.workspace.files.path)?.allObjects as? [String] ?? [])
                .filter { (try? fileManager.destinationOfSymbolicLink(atPath: outcome.workspace.files.path + "/" + $0)) != nil }
            try expect(links.isEmpty, "\(item.name): ningún enlace dentro del espacio: \(links)")
            if let expected = item.expected {
                try expect(outcome.report.findings.contains { $0.kind == expected },
                           "\(item.name): el informe debe decir \(expected.rawValue): \(outcome.report.findings.map(\.kind))")
            }
            if item.name == "normal.zip" {
                try expect(outcome.report.executables.map(\.name) == ["juego.exe"], "el inventario encuentra el programa")
                try expect(outcome.report.verdict == .nothingSuspicious, "sin escáner y sin nada raro: \(outcome.report.verdict)")
                try expect(outcome.workspace.loadReport() == outcome.report, "el informe queda guardado en el espacio")
            }
            if item.name == "Disfrazado.rar" {
                try expect(fileManager.fileExists(atPath: outcome.workspace.files.appendingPathComponent("dentro.txt").path),
                           "un ZIP que se llama .rar se extrae igual, con la herramienta que toca por contenido")
            }
        }
    }

    private static func testCancelledOrBrokenExtractionLeavesNothingBehind(tools: [ArchiveTool], lister: URL?) async throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let broken = fixture.directoryURL.appendingPathComponent("roto.zip")
        try (Data("PK\u{03}\u{04}".utf8) + Data((0..<300).map { UInt8($0 % 251) })).write(to: broken)

        var failed = false
        do {
            _ = try await SafeExtractor(runner: ProcessRunner(), base: base, scanner: nil).extract(
                archive: broken, tools: tools, lister: lister, password: nil, session: ProcessSession(),
                onStage: { _ in }, onProgress: { _ in }, onLine: { _ in })
        } catch {
            failed = true
        }
        try expect(failed, "un comprimido dañado no se da por extraído")
        try expect(SafeWorkspace.all(base: base).isEmpty, "y no deja un espacio a medias")

        let session = ProcessSession()
        session.cancel()
        let normal = fixture.directoryURL.appendingPathComponent("normal.zip")
        try SafeModeFixtures.zip([.file("a.txt", "a")]).write(to: normal)
        var cancelled = false
        do {
            _ = try await SafeExtractor(runner: ProcessRunner(), base: base, scanner: nil).extract(
                archive: normal, tools: tools, lister: lister, password: nil, session: session,
                onStage: { _ in }, onProgress: { _ in }, onLine: { _ in })
        } catch SafeExtractionError.cancelled {
            cancelled = true
        }
        try expect(cancelled && SafeWorkspace.all(base: base).isEmpty, "cancelar no deja nada")
    }

    /// Extraer dos veces el mismo comprimido creaba dos espacios completos, cada uno con todo
    /// dentro, sin que nada lo dijera: así se llenó un disco con 56 GB repetidos. El que decide
    /// cuántos espacios quedan es quien mira, y por defecto no queda ninguno de más.
    private static func testSameArchiveNeverGetsTwoSpacesByAccident(tools: [ArchiveTool], lister: URL?) async throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let archive = fixture.directoryURL.appendingPathComponent("juego.zip")
        try SafeModeFixtures.zip([.file("juego.exe", "MZ"), .file("datos.pak", "contenido")]).write(to: archive)
        let extractor = SafeExtractor(runner: ProcessRunner(), base: base, scanner: nil)
        func extract(_ previous: PreviousSpacePolicy) async throws -> SafeExtractionOutcome {
            try await extractor.extract(archive: archive, tools: tools, lister: lister, password: nil,
                                        session: ProcessSession(), previous: previous,
                                        onStage: { _ in }, onProgress: { _ in }, onLine: { _ in })
        }

        let first = try await extract(.refuse)
        try expect(SafeWorkspace.all(base: base).count == 1, "la primera extracción crea un espacio")

        // Exactamente lo que pasó: darle a extraer otra vez sin que nadie dijera nada.
        var refused: Int?
        do { _ = try await extract(.refuse) } catch SafeExtractionError.alreadyExtracted(let count) { refused = count }
        try expect(refused == 1, "la segunda no se hace sola: avisa de que ya hay una")
        try expect(SafeWorkspace.all(base: base).map(\.id) == [first.workspace.id],
                   "y no deja ni un espacio de más ni uno de menos")

        let both = try await extract(.keepBoth)
        try expect(Set(SafeWorkspace.all(base: base).map(\.id)) == [first.workspace.id, both.workspace.id],
                   "pedir un espacio aparte sí deja dos, porque se pidió")
        try expect(both.replacedSpaces == 0, "y ahí no se borra nada")

        let replaced = try await extract(.replace)
        try expect(SafeWorkspace.all(base: base).map(\.id) == [replaced.workspace.id],
                   "reemplazar deja exactamente uno: el nuevo")
        try expect(replaced.replacedSpaces == 2, "y dice cuántos borró: \(replaced.replacedSpaces)")
        try expect(FileManager.default.fileExists(atPath: replaced.workspace.files.appendingPathComponent("juego.exe").path),
                   "con lo extraído dentro")

        // Y lo que no puede pasar: que por reemplazar se pierda lo que había si lo nuevo no cabe.
        let previousSpaces = await extractor.previousSpaces(for: archive)
        try expect(previousSpaces.spaces.map(\.id) == [replaced.workspace.id] && previousSpaces.bytes > 0,
                   "el espacio que queda se encuentra por su comprimido y se sabe lo que ocupa")
    }

    private static func testKnownThreatIsReportedWhenAScannerExists(tools: [ArchiveTool], lister: URL?) async throws {
        guard let scanner = SignatureScanner.locate() else {
            print("SKIP firma conocida (no hay ClamAV con firmas)")
            return
        }
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let archive = fixture.directoryURL.appendingPathComponent("prueba.zip")
        // EICAR: el archivo de prueba estándar que todo antivirus reconoce y que no hace nada.
        let eicar = #"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#
        try SafeModeFixtures.zip([.file("eicar.com", eicar), .file("leeme.txt", "hola")]).write(to: archive)
        let outcome = try await SafeExtractor(runner: ProcessRunner(), base: base, scanner: scanner).extract(
            archive: archive, tools: tools, lister: lister, password: nil, session: ProcessSession(),
            onStage: { _ in }, onProgress: { _ in }, onLine: { _ in })
        try expect(outcome.report.findings.contains { $0.kind == .knownThreat && $0.subject == "eicar.com" },
                   "el escáner reconoce la firma de prueba: \(outcome.report.signatureScan) \(outcome.report.findings)")
        if case .knownThreats = outcome.report.verdict {} else {
            throw TestFailure(description: "el veredicto debe ser amenaza conocida: \(outcome.report.verdict)")
        }
    }
}
