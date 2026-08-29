import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    private let locator: RuntimeLocator
    private let runner: ProcessRunner
    private let fileManager: FileManager

    private var customWineURL: URL?
    private var programSession: ProcessSession?
    private var extractionSession: ProcessSession?

    // MARK: - Idioma

    @Published public var language: Language {
        didSet {
            guard language != oldValue else { return }
            Preferences.language = language
            strings = Strings.table(for: language)
        }
    }
    @Published public private(set) var strings: Strings

    // MARK: - Herramientas del sistema

    @Published public private(set) var runtimeStatus: RuntimeStatus

    // MARK: - Programa de Windows

    @Published public var selectedProgram: URL? {
        didSet {
            programArchitecture = selectedProgram.map(ProgramInspector.architecture(of:)) ?? .unknown
        }
    }
    @Published public private(set) var programArchitecture: ProgramArchitecture = .unknown
    @Published public private(set) var isRunningProgram = false
    @Published public private(set) var isPreparingWindows = false
    /// macOS bloquea Wine si viene marcado como descargado. Se detecta al arrancar.
    @Published public private(set) var wineIsBlocked = false
    @Published public private(set) var isUnblockingWine = false

    // MARK: - Archivo comprimido

    @Published public var selectedArchive: URL?
    /// Destino elegido a mano. Si es `nil`, se usa el sugerido automáticamente.
    @Published public var chosenDestination: URL?
    @Published public var archivePassword = ""
    @Published public var overwritePolicy: OverwritePolicy {
        didSet { Preferences.overwritePolicy = overwritePolicy }
    }
    @Published public var extractIntoSubfolder: Bool {
        didSet {
            Preferences.extractIntoSubfolder = extractIntoSubfolder
            chosenDestination = nil
        }
    }
    @Published public var revealWhenDone: Bool {
        didSet { Preferences.revealWhenDone = revealWhenDone }
    }
    @Published public private(set) var isExtracting = false
    /// De 0 a 1 mientras `7zz` informa. `nil` cuando no hay dato.
    @Published public private(set) var extractionProgress: Double?
    @Published public private(set) var archiveFacts = ArchiveFacts()
    @Published public private(set) var isInspecting = false

    // MARK: - Estado común

    @Published public private(set) var log: [LogEntry] = []
    @Published public private(set) var activityMessage = ""
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSuccessFolder: URL?
    @Published public private(set) var isInstallingTools = false

    public var isBusy: Bool {
        isRunningProgram || isExtracting || isInstallingTools || isPreparingWindows
    }

    // MARK: - Lo que la app sabe del archivo elegido

    public var archiveContents: [String] { archiveFacts.entryNames }

    /// El extractor que abrirá el comprimido elegido.
    public var toolForSelectedArchive: ArchiveTool? {
        selectedArchive.flatMap { runtimeStatus.tool(for: $0) }
    }

    /// La elección merece explicación cuando se descarta `7zz` a propósito por ser un `.rar`.
    public var toolChoiceNeedsExplaining: Bool {
        guard let tool = toolForSelectedArchive, case .unar = tool else { return false }
        return runtimeStatus.archiveTools.contains { if case .sevenZip = $0 { return true }; return false }
    }

    /// El Wine disponible solo ejecuta 64 bits, así que un programa de 32 no arrancará.
    public var programWontRunOnThisWine: Bool {
        runtimeStatus.wineURL != nil && programArchitecture.warnsAboutWine
    }

    // MARK: - Reglas de habilitación

    public var canRunProgram: Bool {
        guard let selectedProgram, !isRunningProgram, !isPreparingWindows, !wineIsBlocked else { return false }
        return SupportedFileKind.exe.accepts(selectedProgram)
            && fileManager.isReadableFile(atPath: selectedProgram.path)
            && runtimeStatus.wineURL != nil
    }

    /// Carpeta donde acabará el contenido si el usuario no cambia nada.
    public var suggestedDestination: URL? {
        guard let selectedArchive else { return nil }
        let parent = selectedArchive.deletingLastPathComponent()
        guard extractIntoSubfolder else { return parent }
        return parent.appendingPathComponent(selectedArchive.suggestedFolderName, isDirectory: true)
    }

    public var effectiveDestination: URL? { chosenDestination ?? suggestedDestination }

    public var canExtractArchive: Bool {
        guard let selectedArchive, effectiveDestination != nil, !isExtracting else { return false }
        return SupportedFileKind.rar.accepts(selectedArchive)
            && fileManager.isReadableFile(atPath: selectedArchive.path)
            && runtimeStatus.tool(for: selectedArchive) != nil
    }

    public var canInstallTools: Bool {
        !isInstallingTools && runtimeStatus.homebrewURL != nil && runtimeStatus.archiveTool == nil
    }

    /// Qué le falta al sistema para que la app funcione entera.
    public var missingTools: [String] {
        var missing: [String] = []
        if runtimeStatus.wineURL == nil { missing.append("Wine") }
        if runtimeStatus.archiveTool == nil { missing.append(strings[.toolExtractor]) }
        return missing
    }

    /// Las formas de conseguir Wine que funcionan hoy en un Mac con chip Apple.
    public var wineOptions: [WineOption] {
        [
            WineOption(
                name: strings[.wineOptionGptk],
                detail: strings[.wineOptionGptkWhy],
                command: "brew tap gcenx/wine && HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask gcenx/wine/game-porting-toolkit"
            ),
            WineOption(
                name: strings[.wineOptionCrossover],
                detail: strings[.wineOptionCrossoverWhy],
                command: "brew install --cask crossover"
            ),
            WineOption(
                name: strings[.wineOptionExisting],
                detail: strings[.wineOptionExistingWhy],
                command: nil
            )
        ]
    }

    // MARK: - Ciclo de vida

    public init(
        locator: RuntimeLocator = RuntimeLocator(),
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.locator = locator
        self.runner = runner
        self.fileManager = fileManager
        self.language = Preferences.language
        self.strings = Strings.table(for: Preferences.language)
        self.customWineURL = Preferences.customWineURL
        self.overwritePolicy = Preferences.overwritePolicy
        self.extractIntoSubfolder = Preferences.extractIntoSubfolder
        self.revealWhenDone = Preferences.revealWhenDone
        self.runtimeStatus = locator.locate(customWineURL: Preferences.customWineURL)
        self.wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)
        self.activityMessage = Strings.table(for: Preferences.language)[.allReady]
    }

    private static func detectBlockedWine(in status: RuntimeStatus) -> Bool {
        guard let wine = status.wineURL else { return false }
        return QuarantineGuard.isQuarantined(wine)
    }

    public func refreshTools() {
        runtimeStatus = locator.locate(customWineURL: customWineURL)
        wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)

        let found = [
            runtimeStatus.wineURL != nil ? "Wine" : nil,
            runtimeStatus.archiveToolName
        ].compactMap { $0 }

        if found.isEmpty {
            add(strings[.logNoTools], level: .warning)
        } else {
            add(strings(.logToolsFound, found.joined(separator: ", ")), level: .info)
        }
    }

    // MARK: - Selección de archivos

    public func selectProgram() {
        guard let url = FileActions.chooseFile(kind: .exe, title: strings[.menuOpenProgram]) else { return }
        acceptProgram(url)
    }

    public func acceptProgram(_ url: URL) {
        guard SupportedFileKind.exe.accepts(url) else {
            showError(strings(.errNotAProgram, url.lastPathComponent))
            return
        }
        selectedProgram = url
        clearError()
        add(strings(.logProgramChosen, url.lastPathComponent), level: .info)
    }

    public func clearProgram() {
        selectedProgram = nil
    }

    public func selectArchive() {
        guard let url = FileActions.chooseFile(kind: .rar, title: strings[.menuOpenArchive]) else { return }
        acceptArchive(url)
    }

    public func acceptArchive(_ url: URL) {
        guard SupportedFileKind.rar.accepts(url) else {
            showError(strings(.errNotAnArchive, url.lastPathComponent))
            return
        }
        selectedArchive = url
        chosenDestination = nil
        archiveFacts = ArchiveFacts()
        archivePassword = ""
        clearError()
        add(strings(.logArchiveChosen, url.lastPathComponent), level: .info)
        inspectArchive()
    }

    public func clearArchive() {
        selectedArchive = nil
        chosenDestination = nil
        archiveFacts = ArchiveFacts()
        archivePassword = ""
        lastSuccessFolder = nil
    }

    /// Punto de entrada para arrastrar y soltar, y para «Abrir con» desde el Finder.
    @discardableResult
    public func accept(droppedURLs urls: [URL]) -> Bool {
        var handled = false
        for url in urls {
            if SupportedFileKind.exe.accepts(url) {
                acceptProgram(url)
                handled = true
            } else if SupportedFileKind.rar.accepts(url) {
                acceptArchive(url)
                handled = true
            }
        }
        if !handled, let first = urls.first {
            showError(strings(.errUnknownFile, first.lastPathComponent))
        }
        return handled
    }

    public func selectDestination() {
        let start = chosenDestination ?? selectedArchive?.deletingLastPathComponent()
        guard let url = FileActions.chooseDirectory(startingAt: start, title: strings[.saveIn]) else { return }
        chosenDestination = url
        Preferences.lastDestinationURL = url
        clearError()
        add(strings(.logDestination, url.path), level: .info)
    }

    public func useSuggestedDestination() {
        chosenDestination = nil
    }

    // MARK: - Wine

    public func selectWine() {
        guard let url = FileActions.chooseWine(title: strings[.menuFindWine]) else { return }
        guard let resolved = RuntimeLocator.resolveWineURL(url) else {
            showError(strings[.errNotWineExecutable])
            return
        }
        customWineURL = resolved
        Preferences.customWineURL = resolved
        runtimeStatus = locator.locate(customWineURL: resolved)
        wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)
        clearError()
        add(strings(.logWineChosen, resolved.path), level: .success)
    }

    public func forgetCustomWine() {
        customWineURL = nil
        Preferences.customWineURL = nil
        refreshTools()
    }

    public func openWineSettings() {
        guard let wine = runtimeStatus.wineURL else { return }
        launchDetached(WineLauncher.configCommand(wine: wine), describing: strings[.wineSettings])
    }

    public func closeWindowsPrograms() {
        guard let wine = runtimeStatus.wineURL else { return }
        launchDetached(WineLauncher.killCommand(wine: wine), describing: strings[.closeAll])
    }

    public var windowsFolderURL: URL { WineLauncher.prefixURL }

    /// Borra el entorno de Windows. Se vuelve a crear solo en la siguiente ejecución.
    public func resetWindowsEnvironment() {
        guard !isRunningProgram, !isPreparingWindows else {
            showError(strings[.errBusy])
            return
        }
        do {
            try WineLauncher.resetPrefix()
            add(strings[.logWindowsReset], level: .success)
            activityMessage = strings[.statusWindowsReset]
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Quita la marca de cuarentena que impide arrancar Wine.
    public func unblockWine() {
        guard !isUnblockingWine, let wine = runtimeStatus.wineURL else { return }
        let target = QuarantineGuard.repairTarget(for: wine)

        isUnblockingWine = true
        clearError()

        Task { [weak self] in
            guard let self else { return }
            _ = try? await runner.run(QuarantineGuard.repairCommand(for: wine)) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            isUnblockingWine = false
            wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)

            if wineIsBlocked {
                showError(strings(.errUnblockFailed, target.path))
            } else {
                activityMessage = strings[.statusWineUnblocked]
                add(strings[.logWineUnblocked], level: .success)
            }
        }
    }

    // MARK: - Ejecutar un programa de Windows

    public func runProgram() {
        guard !isRunningProgram, !isPreparingWindows else { return }
        guard let program = selectedProgram,
              SupportedFileKind.exe.accepts(program),
              fileManager.isReadableFile(atPath: program.path) else {
            showError(strings[.errPickProgram])
            return
        }
        guard let wine = runtimeStatus.wineURL else {
            showError(strings[.errNoWine])
            return
        }
        if !runtimeStatus.hasRosetta {
            showError(strings[.errNoRosetta])
            return
        }
        if wineIsBlocked {
            showError(strings[.errWineBlocked])
            return
        }

        clearError()
        let session = ProcessSession()
        programSession = session

        Task { [weak self] in
            guard let self else { return }

            if WineLauncher.needsFirstRunSetup() {
                isPreparingWindows = true
                activityMessage = strings[.statusPreparing]
                add(strings[.logFirstRun], level: .info)

                _ = try? await runner.run(WineLauncher.bootCommand(wine: wine), session: session) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
                isPreparingWindows = false

                if session.isCancelled {
                    finishProgram(message: strings[.statusStopped], level: .warning)
                    return
                }
                // Si el entorno sigue incompleto, seguir solo llevaría a un error críptico.
                if WineLauncher.needsFirstRunSetup() {
                    finishProgram(message: strings[.statusWindowsFailed], level: .failure)
                    showError(strings[.errWinePrefixFailed])
                    return
                }
                add(strings[.logWindowsReady], level: .success)
            }

            isRunningProgram = true
            activityMessage = strings(.statusRunning, program.lastPathComponent)

            do {
                let result = try await runner.run(
                    WineLauncher.runCommand(wine: wine, program: program),
                    session: session
                ) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }

                if result.wasCancelled {
                    finishProgram(message: strings[.statusStopped], level: .warning)
                } else if result.succeeded {
                    finishProgram(message: strings[.statusFinished], level: .success)
                } else {
                    isRunningProgram = false
                    activityMessage = strings[.statusFailed]
                    showError(strings(.errProgramExit, String(result.exitCode)))
                }
            } catch {
                isRunningProgram = false
                activityMessage = strings[.statusCannotStart]
                showError(error.localizedDescription)
            }
            programSession = nil
        }
    }

    public func stopProgram() {
        programSession?.cancel()
        add(strings[.logStopping], level: .warning)
    }

    private func finishProgram(message: String, level: LogLevel) {
        isRunningProgram = false
        isPreparingWindows = false
        activityMessage = message
        add(level == .success ? strings[.logProgramClosed] : message, level: level)
    }

    // MARK: - Extraer

    public func inspectArchive() {
        guard let archive = selectedArchive,
              let tool = runtimeStatus.tool(for: archive) else { return }
        let lister = locator.listerURL(for: tool)
        guard let command = ArchiveCommandBuilder.listCommand(
            for: tool,
            lister: lister,
            archive: archive,
            password: archivePassword
        ) else { return }

        isInspecting = true
        let usedLister = lister != nil

        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(command)
            isInspecting = false

            guard let result, result.succeeded else {
                // El archivo se lee pero la herramienta no pudo listarlo: casi siempre, contraseña.
                archiveFacts = ArchiveFacts(entryNames: [], listingFailed: true)
                return
            }
            archiveFacts = ArchiveFacts(
                entryNames: ArchiveCommandBuilder.names(fromListing: result.output, usedLister: usedLister),
                listingFailed: false
            )
        }
    }

    public func extractArchive() {
        guard !isExtracting else { return }
        guard let archive = selectedArchive,
              SupportedFileKind.rar.accepts(archive),
              fileManager.isReadableFile(atPath: archive.path) else {
            showError(strings[.errPickArchive])
            return
        }
        guard let destination = effectiveDestination else {
            showError(strings[.errPickDestination])
            return
        }
        guard let tool = runtimeStatus.tool(for: archive) else {
            showError(strings[.errNoExtractor])
            return
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            showError(strings(.errCannotCreateFolder, destination.lastPathComponent, error.localizedDescription))
            return
        }

        // Si la carpeta estaba vacía, un reintento puede reemplazar sin miedo lo que quedó a medias.
        let destinationWasEmpty = isEmptyDirectory(destination)

        clearError()
        lastSuccessFolder = nil
        extractionProgress = tool.reportsProgress ? 0 : nil
        isExtracting = true
        activityMessage = strings(.statusExtracting, archive.lastPathComponent)
        add(strings(.logExtracting, archive.lastPathComponent, tool.displayName), level: .info)

        let session = ProcessSession()
        extractionSession = session

        Task { [weak self] in
            guard let self else { return }
            await self.performExtraction(
                archive: archive,
                destination: destination,
                tool: tool,
                session: session,
                destinationWasEmpty: destinationWasEmpty,
                isRetry: false
            )
        }
    }

    private func performExtraction(
        archive: URL,
        destination: URL,
        tool: ArchiveTool,
        session: ProcessSession,
        destinationWasEmpty: Bool,
        isRetry: Bool
    ) async {
        // En un reintento lo escrito por la herramienta anterior no es fiable, así que se reemplaza,
        // pero solo si la carpeta estaba vacía antes de empezar: nunca se pisan archivos del usuario.
        let policy: OverwritePolicy = (isRetry && destinationWasEmpty) ? .overwrite : overwritePolicy

        let command = ArchiveCommandBuilder.command(
            for: tool,
            archive: archive,
            destination: destination,
            policy: policy,
            password: archivePassword
        )

        do {
            let result = try await runner.run(command, session: session) { line in
                Task { @MainActor [weak self] in self?.addExtractionLine(line) }
            }

            if result.wasCancelled {
                finishExtraction(message: strings[.statusStopped])
                add(strings[.logStopped], level: .warning)
                return
            }

            if result.succeeded {
                finishExtraction(message: strings[.statusExtracted])
                add(strings(.logExtractedTo, destination.path), level: .success)
                add(strings[.logOriginalKept], level: .info)
                lastSuccessFolder = destination
                if revealWhenDone { FileActions.openInFinder(destination) }
                return
            }

            // Cada extractor cubre formatos distintos: si uno no puede, se prueba con el otro.
            if !isRetry, let alternative = runtimeStatus.fallbackTool(for: archive, after: tool) {
                add(strings(.logRetryingWith, tool.displayName, alternative.displayName), level: .warning)
                extractionProgress = alternative.reportsProgress ? 0 : nil
                await performExtraction(
                    archive: archive,
                    destination: destination,
                    tool: alternative,
                    session: session,
                    destinationWasEmpty: destinationWasEmpty,
                    isRetry: true
                )
                return
            }

            finishExtraction(message: strings[.statusFailed])
            showError(explain(exitCode: result.exitCode))
        } catch {
            finishExtraction(message: strings[.statusCannotStart])
            showError(error.localizedDescription)
        }
    }

    public func stopExtraction() {
        extractionSession?.cancel()
        add(strings[.logStopping], level: .warning)
    }

    public func revealResult() {
        guard let lastSuccessFolder else { return }
        FileActions.openInFinder(lastSuccessFolder)
    }

    private func finishExtraction(message: String) {
        isExtracting = false
        extractionProgress = nil
        extractionSession = nil
        activityMessage = message
    }

    private func isEmptyDirectory(_ url: URL) -> Bool {
        let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
        return (contents ?? []).filter { $0 != ".DS_Store" }.isEmpty
    }

    // MARK: - Instalar herramientas

    public func installTools() {
        guard !isInstallingTools else { return }
        guard let homebrew = runtimeStatus.homebrewURL else {
            showError(strings[.errHomebrewMissing])
            return
        }
        // Solo los extractores. Wine no se instala a ciegas: en Apple Silicon los casks chocan
        // entre sí y varios están obsoletos, así que sus opciones se explican en una hoja aparte.
        guard runtimeStatus.archiveTool == nil else {
            add(strings[.logExtractorsPresent], level: .success)
            return
        }

        let formulae = ["sevenzip", "unar"]
        clearError()
        isInstallingTools = true
        activityMessage = strings[.statusInstalling]
        add(strings(.logInstalling, formulae.joined(separator: ", ")), level: .info)
        add(strings[.logInstallTakesTime], level: .info)

        let command = ProcessCommand(
            executableURL: homebrew,
            arguments: ["install"] + formulae,
            currentDirectoryURL: nil,
            environment: [
                "PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":"),
                "HOMEBREW_NO_AUTO_UPDATE": "1"
            ]
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.run(command) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
                isInstallingTools = false
                refreshTools()
                if result.succeeded {
                    activityMessage = strings[.statusToolsInstalled]
                    add(strings[.logInstallDone], level: .success)
                } else {
                    activityMessage = strings[.statusFailed]
                    showError(strings(.errInstallFailed, String(result.exitCode)))
                }
            } catch {
                isInstallingTools = false
                activityMessage = strings[.statusCannotStart]
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Registro de actividad

    public func clearLog() {
        log.removeAll()
        lastError = nil
        activityMessage = strings[.allReady]
    }

    public func copyLog() {
        let text = log.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
        FileActions.copyToClipboard(text)
        add(strings[.logActivityCopied], level: .info)
    }

    public func copyCommand(_ command: String) {
        FileActions.copyToClipboard(command)
        add(strings[.logCommandCopied], level: .info)
    }

    private func addExtractionLine(_ line: String) {
        if let percentage = ArchiveCommandBuilder.progressPercentage(from: line) {
            extractionProgress = Double(percentage) / 100
            // Las líneas de porcentaje llegan a decenas por segundo: no van al registro.
            return
        }
        addOutput(line)
    }

    private func addOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(trimmed, level: .output)
    }

    private func add(_ text: String, level: LogLevel) {
        log.append(LogEntry(text: text, level: level))
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    private func clearError() {
        lastError = nil
    }

    private func showError(_ message: String) {
        lastError = message
        add(message, level: .failure)
    }

    /// Traduce códigos de salida secos en algo accionable.
    private func explain(exitCode: Int32) -> String {
        switch exitCode {
        case 2: return strings[.errExtractExit2]
        case 1: return strings[.errExtractExit1]
        default: return strings(.errExtractExitOther, String(exitCode))
        }
    }

    private func launchDetached(_ command: ProcessCommand, describing activity: String) {
        add(activity, level: .info)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await runner.run(command) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
        }
    }
}
