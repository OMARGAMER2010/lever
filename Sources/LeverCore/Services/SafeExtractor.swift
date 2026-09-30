import Darwin
import Foundation

public enum SafeExtractionStage: Equatable, Sendable {
    case listing
    case extracting
    case sweeping
    case scanning
}

public enum SafeExtractionError: Error, Equatable, Sendable {
    case sandboxUnavailable
    case noTool
    /// El índice no se pudo leer. Con la última línea útil de la herramienta.
    case listingFailed(String)
    /// No cabe, o declara demasiadas entradas.
    case blocked(SafeFinding)
    /// Este mismo comprimido ya tiene espacios extraídos. Lleva cuántos.
    case alreadyExtracted(Int)
    case limitHit(ResourceLimitReason)
    case toolFailed(Int32, String)
    case cancelled
}

/// Qué hacer cuando el comprimido ya tiene espacios extraídos de antes.
///
/// No hay un `reuse` como el de los programas a propósito: el espacio de un programa guarda sus
/// partidas y conviene que sea el mismo, pero extraer encima de lo ya extraído mezcla contenido
/// viejo con nuevo, y quien vuelve a extraer suele hacerlo porque la primera vez salió mal.
public enum PreviousSpacePolicy: Equatable, Sendable {
    /// Lo normal: no se extrae nada y se avisa de que ya está. Ningún espacio nuevo, ninguno menos.
    case refuse
    /// Borra los anteriores y deja uno solo. Lo que ocupaban cuenta como sitio libre.
    case replace
    /// Crea otro espacio y deja los de antes donde están. El disco tiene que dar para los dos.
    case keepBoth
}

public struct SafeExtractionOutcome: Sendable {
    public let workspace: SafeWorkspace
    public let report: SafeReport
    public let assessment: ArchiveAssessment
    /// Cuántos espacios anteriores se borraron para dejar sitio a éste.
    public let replacedSpaces: Int

    public init(workspace: SafeWorkspace, report: SafeReport, assessment: ArchiveAssessment, replacedSpaces: Int = 0) {
        self.workspace = workspace
        self.report = report
        self.assessment = assessment
        self.replacedSpaces = replacedSpaces
    }
}

/// Extrae un comprimido dentro de un espacio aislado.
///
/// El orden importa: primero se lee el índice **aislado** y se decide si merece la pena seguir;
/// después se extrae con escritura solo en el espacio; luego se deja inerte lo extraído y se hace
/// inventario; y al final, si hay escáner de firmas, se le pasa lo ejecutable.
public struct SafeExtractor: Sendable {
    let runner: ProcessRunner
    let base: URL
    let scanner: SignatureScanner?

    public init(runner: ProcessRunner, base: URL = SafeWorkspace.defaultBase, scanner: SignatureScanner? = SignatureScanner.locate()) {
        self.runner = runner
        self.base = base
        self.scanner = scanner
    }

    // MARK: - Qué herramienta

    /// Por **contenido**: un RAR va con `unar`, que abre los métodos antiguos que `7zz` convierte
    /// en archivos vacíos; lo demás con `7zz`, que es el único que sabe de ZIP con Zstd.
    public static func toolOrder(for format: ArchiveFormat, available: [ArchiveTool]) -> [ArchiveTool] {
        func first(_ match: (ArchiveTool) -> Bool) -> ArchiveTool? { available.first(where: match) }
        let sevenZip = first { if case .sevenZip = $0 { return true }; return false }
        let unar = first { if case .unar = $0 { return true }; return false }
        let unrar = first { if case .unrar = $0 { return true }; return false }
        let order = format == .rar ? [unar, unrar, sevenZip] : [sevenZip, unar, unrar]
        return order.compactMap { $0 }
    }

    // MARK: - Solo mirar

    /// Lee el índice aislado y aplica las reglas. Rápido: se usa nada más elegir el archivo.
    public func assess(
        archive: URL,
        tools: [ArchiveTool],
        lister: URL?,
        password: String?,
        reclaimableBytes: Int64 = 0,
        fileManager: FileManager = .default
    ) async -> (ArchiveAssessment, listingError: String?) {
        let format = ArchiveSignature.detect(archive)
        let listing = await list(archive: archive, format: format, tools: tools, lister: lister, password: password,
                                 fileManager: fileManager)
        let assessment = SafeArchiveAnalyzer.assess(
            archive: archive,
            entries: listing.entries,
            format: format,
            archiveBytes: archive.fileSizeInBytes ?? 0,
            freeBytes: ResourceWatchdog.freeBytes(on: base),
            reclaimableBytes: reclaimableBytes
        )
        return (assessment, listing.error)
    }

    /// Los espacios que ya salieron de este comprimido, y lo que ocupan. Recorre carpetas enteras,
    /// así que va fuera del hilo principal.
    public func previousSpaces(for archive: URL) async -> (spaces: [SafeWorkspace], bytes: Int64) {
        let base = base
        let path = archive.path
        return await Task.detached {
            let spaces = SafeWorkspace.all(forArchiveAt: path, base: base)
            return (spaces, spaces.reduce(Int64(0)) { $0 + $1.allocatedBytes() })
        }.value
    }

    private func list(
        archive: URL,
        format: ArchiveFormat,
        tools: [ArchiveTool],
        lister: URL?,
        password: String?,
        fileManager: FileManager
    ) async -> (entries: [ArchiveEntry]?, error: String?) {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("lever-list-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let secret = password?.isEmpty == false ? password : nil
        var lastError: String?

        // 7zz da la estructura completa; `lsar` queda para lo que 7zz no abra.
        if case .sevenZip(let sevenZip)? = tools.first(where: { if case .sevenZip = $0 { return true }; return false }) {
            var arguments = ["l", "-slt", "-ba"]
            arguments.append("-p\(secret ?? "")")
            arguments.append(archive.path)
            if let result = await runListing(tool: sevenZip, arguments: arguments, archive: archive, scratch: scratch) {
                if result.succeeded { return (ArchiveListingParser.parseSevenZip(result.output), nil) }
                lastError = Self.lastMeaningfulLine(result.output)
            }
        }
        if let lister {
            var arguments = ["-json"]
            if let secret { arguments += ["-p", secret] }
            arguments.append(archive.path)
            if let result = await runListing(tool: lister, arguments: arguments, archive: archive, scratch: scratch),
               result.succeeded, let entries = ArchiveListingParser.parseLsar(Data(result.output.utf8)) {
                return (entries, nil)
            } else if lastError == nil {
                lastError = "lsar"
            }
        }
        return (nil, lastError)
    }

    private func runListing(tool: URL, arguments: [String], archive: URL, scratch: URL) async -> ProcessResult? {
        guard let real = try? SandboxPath.canonical(tool),
              let profile = try? SandboxProfile.archiveListing(tool: URL(fileURLWithPath: real), archive: archive) else {
            return nil
        }
        let profileURL = scratch.appendingPathComponent("listing.sb")
        guard (try? Sandbox.write(profile, to: profileURL)) != nil else { return nil }
        let command = Sandbox.command(
            ProcessCommand(executableURL: URL(fileURLWithPath: real), arguments: arguments, currentDirectoryURL: nil),
            profileURL: profileURL,
            environment: Sandbox.minimalEnvironment(temporary: nil)
        )
        return try? await runner.run(command)
    }

    // MARK: - Extraer

    public func extract(
        archive: URL,
        tools: [ArchiveTool],
        lister: URL?,
        password: String?,
        session: ProcessSession,
        previous: PreviousSpacePolicy = .refuse,
        onStage: @escaping @Sendable (SafeExtractionStage) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void,
        onLine: @escaping @Sendable (String) -> Void,
        fileManager: FileManager = .default
    ) async throws -> SafeExtractionOutcome {
        // Antes que nada, y antes de crear nada: ¿este comprimido ya está extraído? Extraer dos
        // veces el mismo archivo sin decirlo es lo que llenaba el disco con dos copias completas.
        let earlier = SafeWorkspace.all(forArchiveAt: archive.path, base: base, fileManager: fileManager)
        if previous == .refuse, !earlier.isEmpty {
            throw SafeExtractionError.alreadyExtracted(earlier.count)
        }
        // Lo que ocupan los anteriores solo es sitio libre si se van a borrar. Si se pide un espacio
        // aparte, «no cabe» se decide contra el disco tal y como está: los dos tienen que caber.
        let reclaimable: Int64 = previous == .replace && !earlier.isEmpty
            ? await Task.detached { earlier.reduce(Int64(0)) { $0 + $1.allocatedBytes() } }.value
            : 0

        onStage(.listing)
        let (assessment, listingError) = await assess(
            archive: archive, tools: tools, lister: lister, password: password,
            reclaimableBytes: reclaimable, fileManager: fileManager)
        if session.isCancelled { throw SafeExtractionError.cancelled }
        guard assessment.inspected else { throw SafeExtractionError.listingFailed(listingError ?? "") }
        if let blocking = assessment.blockingProblem { throw SafeExtractionError.blocked(blocking) }

        let order = Self.toolOrder(for: assessment.format, available: tools)
        guard !order.isEmpty else { throw SafeExtractionError.noTool }

        // Se borra aquí y no antes: primero hay que saber que lo nuevo cabe. Así nunca se pierde
        // lo que había por una extracción que ya se sabía que iba a fallar.
        var replaced = 0
        if previous == .replace {
            for space in earlier {
                try? space.delete(base: base, fileManager: fileManager)
                replaced += 1
            }
        }

        let workspace = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: archive.path), base: base, fileManager: fileManager)
        do {
            try workspace.prepareRunDirectories(fileManager: fileManager)
            onStage(.extracting)
            var extracted = false
            var blockedLinks: [SafeFinding] = []
            var lastFailure: (code: Int32, line: String)?

            for (attempt, tool) in order.enumerated() {
                if attempt > 0 {
                    // Lo que dejó el anterior no es fiable: se empieza de cero, que es del espacio.
                    try SafeWorkspace.removeTree(at: workspace.files, confinedTo: base, fileManager: fileManager)
                    try fileManager.createDirectory(at: workspace.files, withIntermediateDirectories: true)
                    onLine("↻ \(tool.displayName)")
                }
                let outcome = try await runExtraction(
                    tool: tool, archive: archive, workspace: workspace, assessment: assessment,
                    password: password, session: session, onProgress: onProgress, onLine: onLine)
                switch outcome {
                case .finished:
                    extracted = true
                case .finishedWithBlockedLinks(let findings):
                    extracted = true
                    blockedLinks = findings
                case .failed(let code, let line):
                    lastFailure = (code, line)
                }
                if extracted { break }
            }
            guard extracted else {
                throw SafeExtractionError.toolFailed(lastFailure?.code ?? -1, lastFailure?.line ?? "")
            }

            onStage(.sweeping)
            let files = workspace.files
            let sweep = await Task.detached { SafeContentScanner.sweep(root: files) }.value
            if session.isCancelled { throw SafeExtractionError.cancelled }

            var report = SafeReport(
                findings: Self.merge(assessment.findings, blockedLinks, sweep.findings),
                executables: sweep.executables,
                signatureScan: .notAvailable,
                entryCount: assessment.entryCount,
                totalBytes: sweep.totalBytes,
                inspected: true
            )

            if let scanner {
                onStage(.scanning)
                let scanSession = ProcessSession()
                let forward = Task.detached {
                    while !Task.isCancelled {
                        if session.isCancelled { scanSession.cancel(); return }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                let (scan, detections) = await scanner.scan(
                    targets: sweep.scanTargets, relativeTo: files, workspace: workspace,
                    runner: runner, session: scanSession, fileManager: fileManager)
                forward.cancel()
                if session.isCancelled { throw SafeExtractionError.cancelled }
                report.signatureScan = scan
                report.findings = Self.merge(report.findings, detections)
            }

            try workspace.save(report)
            return SafeExtractionOutcome(workspace: workspace, report: report, assessment: assessment,
                                         replacedSpaces: replaced)
        } catch {
            // Una extracción a medias no sirve para nada y ocupa: se borra entera.
            try? workspace.delete(base: base, fileManager: fileManager)
            if session.isCancelled, !(error is SafeExtractionError) { throw SafeExtractionError.cancelled }
            throw error
        }
    }

    private enum RunOutcome {
        case finished
        case finishedWithBlockedLinks([SafeFinding])
        case failed(Int32, String)
    }

    private func runExtraction(
        tool: ArchiveTool,
        archive: URL,
        workspace: SafeWorkspace,
        assessment: ArchiveAssessment,
        password: String?,
        session: ProcessSession,
        onProgress: @escaping @Sendable (Double) -> Void,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> RunOutcome {
        let real = URL(fileURLWithPath: try SandboxPath.canonical(tool.executableURL))
        let realTool: ArchiveTool
        switch tool {
        case .sevenZip: realTool = .sevenZip(real)
        case .unar: realTool = .unar(real)
        case .unrar: realTool = .unrar(real)
        }
        let profile = try SandboxProfile.archiveExtraction(
            tool: real, archive: archive, destination: workspace.files, temporary: workspace.temporary)
        let profileURL = workspace.control.appendingPathComponent("extraction.sb")
        try Sandbox.write(profile, to: profileURL)

        let free = ResourceWatchdog.freeBytes(on: workspace.root) ?? Int64.max
        let room = max(0, free - SafeArchiveAnalyzer.diskReserveBytes)
        // Cada archivo, como mucho lo que declara el mayor, con margen; sin datos, lo que quepa.
        let perFile: Int64 = assessment.largestEntryBytes.map { min(room, max($0 + $0 / 20 + 16_777_216, 67_108_864)) } ?? room
        let written: Int64? = assessment.declaredBytes.map { $0 + $0 / 20 + 268_435_456 }

        let base = ArchiveCommandBuilder.command(
            for: realTool, archive: archive, destination: workspace.files, policy: .skip, password: password)
        let command = Sandbox.command(
            ProcessCommand(executableURL: base.executableURL, arguments: base.arguments,
                           currentDirectoryURL: workspace.files),
            profileURL: profileURL,
            environment: Sandbox.minimalEnvironment(temporary: workspace.temporary),
            fileSizeLimit: max(perFile, 1_048_576)
        )

        let watchdog = ResourceWatchdog(
            session: session, volume: workspace.root, maximumBytesWritten: written,
            maximumFootprint: ResourceWatchdog.defaultExtractionFootprint)
        watchdog.start()
        defer { watchdog.stop() }

        let result = try await runner.run(command, session: session) { line in
            if let percentage = ArchiveCommandBuilder.progressPercentage(from: line) {
                onProgress(Double(percentage) / 100)
            } else {
                onLine(line)
            }
        }
        watchdog.stop()

        if let reason = watchdog.tripped { throw SafeExtractionError.limitHit(reason) }
        if result.endedBySignal, result.exitCode == SIGXFSZ { throw SafeExtractionError.limitHit(.fileSize) }
        if result.wasCancelled { throw SafeExtractionError.cancelled }
        if result.succeeded { return .finished }

        // Si lo único que falló fueron los enlaces que el aislamiento no deja crear, lo demás está
        // bien extraído: se dice qué enlaces se quedaron fuera y se sigue.
        let links = assessment.findings.filter { $0.kind == .symbolicLink || $0.kind == .hardLink }
        let output = result.output.lowercased()
        let onlyLinkErrors = !links.isEmpty && (output.contains("symbolic link") || output.contains("symlink")
            || output.contains("hard link") || output.contains("operation not permitted"))
        if onlyLinkErrors, !result.endedBySignal {
            return .finishedWithBlockedLinks(links.map { SafeFinding(.blockedLink, subject: $0.subject, detail: $0.detail) })
        }
        return .failed(result.exitCode, Self.lastMeaningfulLine(result.output) ?? "")
    }

    // MARK: - Utilidades

    /// Une listas de hallazgos sin repetir el mismo dos veces.
    static func merge(_ lists: [SafeFinding]...) -> [SafeFinding] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    static func lastMeaningfulLine(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("Scanning") }
    }
}
