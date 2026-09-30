import Foundation

/// Safe Mode dentro del modelo: la misma app, el mismo botón, otro entorno.
public extension AppModel {
    // MARK: - Comprobaciones

    /// Aplica de verdad un aislamiento de prueba la primera vez. Si falla, Safe Mode queda
    /// desactivado: nunca se hace «lo mismo pero sin aislar».
    internal func ensureSandbox() async -> Bool {
        if sandboxAvailability == .unknown {
            sandboxAvailability = await Sandbox.checkAvailability(runner: runner)
        }
        return sandboxAvailability == .available
    }

    func checkSandboxAvailability() {
        guard sandboxAvailability == .unknown else { return }
        Task { _ = await ensureSandbox() }
    }

    var canUseSafeMode: Bool { sandboxAvailability != .unavailable }

    // MARK: - Recomendación

    /// Lee la estructura del comprimido aislada y decide si recomendar Safe Mode.
    internal func assessArchiveForSafeMode() {
        archiveRecommendation = .none
        archivePreviousExtractions = .none
        if !isExtracting, safeWorkspace?.origin()?.kind != .program || programOpenMode == .normal {
            safeReport = nil
            safeWorkspace = nil
        }
        archiveOpenMode = SafeWorkspace.containing(selectedArchive ?? URL(fileURLWithPath: "/")) != nil ? .safe : .normal
        guard let archive = selectedArchive else { return }
        refreshPreviousExtractions()
        let tools = runtimeStatus.archiveTools
        let lister = unarLister
        let password = archivePassword
        let extractor = SafeExtractor(runner: runner, scanner: nil)
        Task { [weak self] in
            guard let self, await self.ensureSandbox() else { return }
            let (assessment, _) = await extractor.assess(archive: archive, tools: tools, lister: lister, password: password)
            guard self.selectedArchive == archive else { return }
            self.archiveRecommendation = assessment.recommendation
            if assessment.recommendation.isRecommended { self.archiveOpenMode = .safe }
        }
    }

    /// Señales que se ven sin abrir nada: un nombre engañoso, una DLL con nombre de sistema al lado,
    /// o que el programa ya viva en un espacio aislado.
    internal func refreshProgramRecommendation() {
        allowsNetworkInSafeRun = false
        guard let program = selectedProgram else {
            programRecommendation = .none
            programOpenMode = .normal
            return
        }
        var reasons: [SafeFinding] = []
        if SafeContentRules.isDeceptiveName(program.lastPathComponent) {
            reasons.append(SafeFinding(.deceptiveName, subject: program.lastPathComponent))
        }
        let siblings = (try? fileManager.contentsOfDirectory(atPath: program.deletingLastPathComponent().path)) ?? []
        for name in siblings.prefix(5_000) where SafeContentRules.systemDllNames.contains(name.lowercased()) {
            reasons.append(SafeFinding(.dllSideLoading, subject: name))
        }
        programRecommendation = SafeRecommendation(reasons: reasons)
        let fromWorkspace = SafeWorkspace.containing(program) != nil
        programOpenMode = (fromWorkspace || !reasons.isEmpty) ? .safe : .normal
        if let workspace = SafeWorkspace.containing(program) {
            safeWorkspace = workspace
            safeReport = workspace.loadReport()
        }
    }

    /// Vuelve a mirar qué espacios dejó este comprimido y cuánto ocupan.
    ///
    /// Se excluye el que se está enseñando: ése no es «lo de antes», es lo que acabas de extraer.
    /// Así el aviso significa siempre lo mismo —hay **otra** copia de esto por ahí— y no aparece
    /// justo después de extraer diciendo que ya estaba extraído.
    internal func refreshPreviousExtractions() {
        guard let archive = selectedArchive else {
            archivePreviousExtractions = .none
            return
        }
        let shown = safeWorkspace?.id
        Task { [weak self] in
            let found = await Task.detached { () -> SafePreviousExtractions in
                let spaces = SafeWorkspace.all(forArchiveAt: archive.path).filter { $0.id != shown }
                guard !spaces.isEmpty else { return .none }
                return SafePreviousExtractions(
                    spaces: spaces,
                    bytes: spaces.reduce(Int64(0)) { $0 + $1.allocatedBytes() },
                    latest: spaces.compactMap { $0.origin()?.createdAt }.max())
            }.value
            guard let self, self.selectedArchive == archive else { return }
            self.archivePreviousExtractions = found
            // Si ya lo extrajiste en Safe Mode, la pestaña enseña Safe Mode: es donde está el aviso
            // y donde están los botones para llegar a lo que ya hay.
            if !found.isEmpty, !self.isExtracting { self.archiveOpenMode = .safe }
        }
    }

    private var unarLister: URL? {
        runtimeStatus.archiveTools
            .first { if case .unar = $0 { return true }; return false }
            .flatMap { locator.listerURL(for: $0) }
    }

    // MARK: - Extraer aislado

    /// Extraer otra vez borrando lo de antes: queda un solo espacio. Lo que ocupaba el anterior
    /// cuenta como sitio libre, así que una segunda extracción del mismo tamaño vuelve a caber.
    func extractArchiveReplacingPrevious() { extractArchiveSafely(previous: .replace) }

    /// Extraer otra vez en un espacio aparte, dejando el de antes donde está. Aquí no se descuenta
    /// nada: si los dos no caben en el disco, se bloquea antes de empezar y se dice cuánto ocupa.
    func extractArchiveKeepingPrevious() { extractArchiveSafely(previous: .keepBoth) }

    internal func extractArchiveSafely(previous: PreviousSpacePolicy = .refuse) {
        guard let archive = selectedArchive, fileManager.isReadableFile(atPath: archive.path) else {
            showError(strings[.errPickArchive])
            return
        }
        guard !runtimeStatus.archiveTools.isEmpty else {
            showError(strings[.errNoExtractor])
            return
        }
        clearError()
        isExtracting = true
        extractionProgress = nil
        lastSuccessFolder = nil
        safeReport = nil
        safeWorkspace = nil
        let session = ProcessSession()
        extractionSession = session
        let tools = runtimeStatus.archiveTools
        let lister = unarLister
        let password = archivePassword

        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureSandbox() else {
                self.finishExtraction(message: self.strings[.statusFailed])
                self.showError(self.strings[.errSafeUnavailable])
                return
            }
            do {
                let outcome = try await SafeExtractor(runner: self.runner).extract(
                    archive: archive, tools: tools, lister: lister, password: password, session: session,
                    previous: previous,
                    onStage: { stage in Task { @MainActor [weak self] in self?.showSafe(stage: stage) } },
                    onProgress: { value in Task { @MainActor [weak self] in self?.extractionProgress = value } },
                    onLine: { line in Task { @MainActor [weak self] in self?.addOutput(line) } })
                self.safeWorkspace = outcome.workspace
                self.safeReport = outcome.report
                self.lastSuccessFolder = outcome.workspace.files
                self.finishExtraction(message: self.strings[.statusExtracted])
                let blocked = outcome.report.findings.filter { $0.kind == .blockedLink }.count
                if blocked > 0 { self.add(self.strings(.logSafeLinksRemoved, String(blocked)), level: .warning) }
                if outcome.replacedSpaces > 0 {
                    self.add(self.strings(.logSafeReplacedSpaces, String(outcome.replacedSpaces)), level: .info)
                }
                self.add(self.strings(.logSafeExtracted, outcome.workspace.files.path), level: .success)
                self.refreshPreviousExtractions()
            } catch let failure as SafeExtractionError {
                self.finishExtraction(message: self.strings[failure == .cancelled ? .statusStopped : .statusFailed])
                if failure != .cancelled { self.showError(self.describe(failure)) }
            } catch {
                self.finishExtraction(message: self.strings[.statusFailed])
                self.showError(error.localizedDescription)
            }
        }
    }

    private func showSafe(stage: SafeExtractionStage) {
        let key: TextKey
        switch stage {
        case .listing: key = .safeStageListing
        case .extracting: key = .safeStageExtracting
        case .sweeping: key = .safeStageSweeping
        case .scanning: key = .safeStageScanning
        }
        activityMessage = strings[key]
        add(strings[key], level: .info)
    }

    internal func describe(_ failure: SafeExtractionError) -> String {
        switch failure {
        case .sandboxUnavailable: return strings[.errSafeUnavailable]
        case .noTool: return strings[.errNoExtractor]
        case .listingFailed(let line): return strings(.errSafeListingFailed, line)
        case .blocked(let finding):
            return finding.kind == .tooManyEntries
                ? strings(.errSafeTooManyEntries, finding.detail ?? "")
                : strings(.errSafeDoesNotFit, finding.detail ?? "")
        case .alreadyExtracted:
            return strings(.errSafeAlreadyExtracted, archivePreviousExtractions.formattedSize)
        case .limitHit(let reason):
            let key: TextKey
            switch reason {
            case .fileSize: key = .safeLimitFileSize
            case .bytesWritten: key = .safeLimitWritten
            case .diskSpace: key = .safeLimitDisk
            case .memory: key = .safeLimitMemory
            }
            return strings(.errSafeLimitHit, strings[key])
        case .toolFailed(let code, let line): return strings(.errSafeExtractionFailed, String(code), line)
        case .cancelled: return strings[.statusStopped]
        }
    }

    // MARK: - Ejecutar aislado

    internal func runProgramSafely() {
        guard let program = selectedProgram, fileManager.isReadableFile(atPath: program.path) else {
            showError(strings[.errPickProgram])
            return
        }
        guard let wine = runtimeStatus.wineURL else {
            showError(strings[.errNoWine])
            return
        }
        if !runtimeStatus.hasRosetta { showError(strings[.errNoRosetta]); return }
        if wineIsBlocked { showError(strings[.errWineBlocked]); return }

        clearError()
        isPreparingWindows = true
        activityMessage = strings[.safeStagePreparing]
        let session = ProcessSession()
        programSession = session
        let network = allowsNetworkInSafeRun
        let safe = safeWindowsRunner

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.allowsNetworkInSafeRun = false
                self.programSession = nil
            }
            guard await self.ensureSandbox() else {
                self.finishProgram(message: self.strings[.statusFailed], level: .failure)
                self.showError(self.strings[.errSafeUnavailable])
                return
            }
            do {
                self.showSafe(run: .importing)
                let (workspace, inside) = try await Task.detached { try safe.workspace(for: program) }.value
                var report = workspace.loadReport()
                if report == nil {
                    let files = workspace.files
                    let sweep = await Task.detached { SafeContentScanner.sweep(root: files) }.value
                    report = SafeReport(findings: sweep.findings, executables: sweep.executables,
                                        entryCount: sweep.fileCount, totalBytes: sweep.totalBytes)
                }
                report?.networkAllowed = network
                if let report { try? workspace.save(report) }
                self.safeWorkspace = workspace
                self.safeReport = report

                let outcome = try await safe.run(
                    program: inside, in: workspace, wine: wine, allowsNetwork: network, session: session,
                    onStage: { stage in Task { @MainActor [weak self] in self?.showSafe(run: stage) } },
                    onLine: { line in Task { @MainActor [weak self] in self?.addOutput(line) } })
                self.add(self.strings(.logSafeRunClosed, String(outcome.terminatedProcesses)), level: .info)
                self.finishProgram(message: self.strings[outcome.wasStopped ? .statusStopped : .statusFinished],
                                   level: outcome.wasStopped ? .warning : .success)
            } catch let failure as SafeRunError {
                self.finishProgram(message: self.strings[.statusFailed], level: .failure)
                self.showError(self.describe(failure))
            } catch {
                self.finishProgram(message: self.strings[.statusFailed], level: .failure)
                self.showError(error.localizedDescription)
            }
        }
    }

    private func showSafe(run stage: SafeRunStage) {
        let key: TextKey
        switch stage {
        case .importing: key = .safeStageImporting
        case .preparing: key = .safeStagePreparing
        case .creatingWindows: key = .safeStageCreatingWindows
        case .running: key = .safeStageRunning
        case .cleaning: key = .safeStageCleaning
        }
        isPreparingWindows = stage != .running && stage != .cleaning
        isRunningProgram = stage == .running || stage == .cleaning
        activityMessage = strings[key]
        add(strings[key], level: .info)
    }

    internal func describe(_ failure: SafeRunError) -> String {
        switch failure {
        case .sandboxUnavailable: return strings[.errSafeUnavailable]
        case .engine(let reason): return strings(.errSafeEngine, reason)
        case .prefix: return strings[.errSafePrefix]
        case .importFailed(let reason): return strings(.errSafeImport, reason)
        case .diskLow: return strings[.errSafeDiskLow]
        }
    }

    // MARK: - Espacios aislados

    /// Abre en Safe Mode un programa encontrado en el espacio que se está enseñando.
    func runSafeExecutable(_ executable: SafeExecutable) {
        guard let workspace = safeWorkspace else { return }
        acceptProgram(workspace.files.appendingPathComponent(executable.relativePath))
        programOpenMode = .safe
    }

    func revealSafeWorkspace() {
        guard let workspace = safeWorkspace else { return }
        FileActions.openInFinder(workspace.files)
    }

    // MARK: - Lo que ya estaba extraído

    /// Enseña el espacio que ya existía en vez de volver a extraer, y abre su carpeta.
    func openPreviousSafeExtraction() {
        guard let workspace = archivePreviousExtractions.spaces.first else { return }
        safeWorkspace = workspace
        safeReport = workspace.loadReport()
        lastSuccessFolder = workspace.files
        archiveOpenMode = .safe
        FileActions.openInFinder(workspace.files)
        refreshPreviousExtractions()
    }

    /// Lo que se borraría al reemplazar, para decirlo en el diálogo antes de que pase.
    var previousSafeExtractionsSize: String { archivePreviousExtractions.formattedSize }

    func deletePreviousSafeExtractions() {
        deleteWorkspaces(archivePreviousExtractions.spaces)
    }

    /// Deja en el Escritorio un enlace a lo extraído.
    ///
    /// Un enlace y no una mudanza: lo extraído tiene que seguir dentro de la base de Safe Mode o
    /// deja de estar aislado. `SafeWorkspace.createDesktopShortcut` explica por qué con detalle.
    func createDesktopShortcutForSafeWorkspace() {
        guard let workspace = safeWorkspace else { return }
        let origin = workspace.origin()?.path ?? ""
        let stem = origin.isEmpty
            ? workspace.id
            : URL(fileURLWithPath: origin).deletingPathExtension().lastPathComponent
        do {
            let link = try workspace.createDesktopShortcut(named: strings(.safeDesktopLinkName, stem),
                                                           fileManager: fileManager)
            add(strings(.logSafeDesktopLink, link.lastPathComponent), level: .success)
            FileActions.reveal(link)
        } catch {
            showError(strings(.errSafeDesktopLink, error.localizedDescription))
        }
    }

    func openSafeModeFolder() {
        try? fileManager.createDirectory(at: SafeWorkspace.defaultBase, withIntermediateDirectories: true)
        FileActions.openInFinder(SafeWorkspace.defaultBase)
    }

    /// Lo que ocupa, para decirlo antes de borrar.
    func safeWorkspaceSize(all: Bool) async -> String {
        let targets = all ? SafeWorkspace.all() : [safeWorkspace].compactMap { $0 }
        let bytes = await Task.detached { targets.reduce(Int64(0)) { $0 + $1.allocatedBytes() } }.value
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func deleteSafeWorkspace() {
        guard let workspace = safeWorkspace else { return }
        deleteWorkspaces([workspace])
    }

    func deleteAllSafeWorkspaces() {
        deleteWorkspaces(SafeWorkspace.all())
    }

    private func deleteWorkspaces(_ workspaces: [SafeWorkspace]) {
        guard !isRunningProgram, !isPreparingWindows, !isExtracting else {
            showError(strings[.errSafeBusy])
            return
        }
        if let program = selectedProgram, workspaces.contains(where: { SafeWorkspace.containing(program)?.id == $0.id }) {
            clearProgram()
        }
        if workspaces.contains(where: { $0.id == safeWorkspace?.id }) {
            safeWorkspace = nil
            safeReport = nil
            lastSuccessFolder = nil
        }
        Task { [weak self] in
            await Task.detached {
                for workspace in workspaces {
                    // Primero el acceso del Escritorio: si no, queda un enlace que no lleva a nada.
                    SafeWorkspace.removeDesktopShortcuts(into: workspace)
                    try? workspace.delete()
                }
            }.value
            guard let self else { return }
            self.add(self.strings[.logSafeWorkspaceDeleted], level: .success)
            self.refreshPreviousExtractions()
        }
    }

    /// Al cerrar Lever no queda nada corriendo de una sesión aislada.
    func stopSafeSessionsNow() {
        safeWindowsRunner.killActiveSessionNow()
    }
}
