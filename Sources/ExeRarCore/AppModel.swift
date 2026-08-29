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

    // MARK: - Herramientas del sistema

    @Published public private(set) var runtimeStatus: RuntimeStatus

    // MARK: - Programa de Windows

    @Published public var selectedProgram: URL?
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
    @Published public private(set) var archiveContents: [String] = []
    @Published public private(set) var isInspecting = false

    // MARK: - Estado común

    @Published public private(set) var log: [LogEntry] = []
    @Published public private(set) var activityMessage = "Todo listo"
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSuccessFolder: URL?
    @Published public private(set) var isInstallingTools = false

    public var isBusy: Bool {
        isRunningProgram || isExtracting || isInstallingTools || isPreparingWindows
    }

    // MARK: - Reglas de habilitación

    public var canRunProgram: Bool {
        guard let selectedProgram, !isRunningProgram, !isPreparingWindows else { return false }
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

    /// Las formas de conseguir Wine que funcionan hoy en un Mac con chip Apple.
    /// No hay una sola respuesta buena, así que se enseñan y el usuario elige.
    public static let wineOptions: [WineOption] = [
        WineOption(
            name: "Game Porting Toolkit",
            detail: "Gratis. La compilación que mantiene la comunidad para Mac con chip Apple.",
            command: "brew tap gcenx/wine && HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask gcenx/wine/game-porting-toolkit"
        ),
        WineOption(
            name: "CrossOver",
            detail: "De pago, con 14 días de prueba. Es la más fiable con diferencia.",
            command: "brew install --cask crossover"
        ),
        WineOption(
            name: "Ya tengo uno",
            detail: "Si ya tienes Wine en el Mac, señálalo a mano con «Otro Wine».",
            command: nil
        )
    ]

    public func copyCommand(_ command: String) {
        FileActions.copyToClipboard(command)
        add("Orden copiada. Pégala en la Terminal.", level: .info)
    }

    /// Qué le falta al sistema para que la app funcione entera.
    public var missingTools: [String] {
        var missing: [String] = []
        if runtimeStatus.wineURL == nil { missing.append("Wine") }
        if runtimeStatus.archiveTool == nil { missing.append("un extractor") }
        return missing
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
        self.customWineURL = Preferences.customWineURL
        self.overwritePolicy = Preferences.overwritePolicy
        self.extractIntoSubfolder = Preferences.extractIntoSubfolder
        self.revealWhenDone = Preferences.revealWhenDone
        self.runtimeStatus = locator.locate(customWineURL: Preferences.customWineURL)
        self.wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)
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
        add(found.isEmpty ? "No se encontró ninguna herramienta." : "Herramientas: \(found.joined(separator: ", "))",
            level: found.isEmpty ? .warning : .info)
    }

    // MARK: - Selección de archivos

    public func selectProgram() {
        guard let url = FileActions.chooseFile(kind: .exe) else { return }
        acceptProgram(url)
    }

    public func acceptProgram(_ url: URL) {
        guard SupportedFileKind.exe.accepts(url) else {
            showError("«\(url.lastPathComponent)» no es un \(SupportedFileKind.exe.humanDescription).")
            return
        }
        selectedProgram = url
        clearError()
        add("Programa elegido: \(url.lastPathComponent)", level: .info)
    }

    public func clearProgram() {
        selectedProgram = nil
    }

    public func selectArchive() {
        guard let url = FileActions.chooseFile(kind: .rar) else { return }
        acceptArchive(url)
    }

    public func acceptArchive(_ url: URL) {
        guard SupportedFileKind.rar.accepts(url) else {
            showError("«\(url.lastPathComponent)» no es un \(SupportedFileKind.rar.humanDescription).")
            return
        }
        selectedArchive = url
        chosenDestination = nil
        archiveContents = []
        archivePassword = ""
        clearError()
        add("Comprimido elegido: \(url.lastPathComponent)", level: .info)
        inspectArchive()
    }

    public func clearArchive() {
        selectedArchive = nil
        chosenDestination = nil
        archiveContents = []
        archivePassword = ""
    }

    /// Punto de entrada para arrastrar y soltar, y para «Abrir con» desde el Finder.
    /// Devuelve `true` si reconoció algo.
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
            showError("No se reconoce «\(first.lastPathComponent)». Admite .exe, .msi y comprimidos como .rar o .zip.")
        }
        return handled
    }

    public func selectDestination() {
        let start = chosenDestination ?? selectedArchive?.deletingLastPathComponent()
        guard let url = FileActions.chooseDirectory(startingAt: start) else { return }
        chosenDestination = url
        Preferences.lastDestinationURL = url
        clearError()
        add("Destino: \(url.path)", level: .info)
    }

    public func useSuggestedDestination() {
        chosenDestination = nil
    }

    // MARK: - Wine

    public func selectWine() {
        guard let url = FileActions.chooseWine() else { return }
        guard let resolved = RuntimeLocator.resolveWineURL(url) else {
            showError("Ahí no hay un ejecutable de Wine. Busca el archivo «wine» o una app «Wine…app».")
            return
        }
        customWineURL = resolved
        Preferences.customWineURL = resolved
        runtimeStatus = locator.locate(customWineURL: resolved)
        wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)
        clearError()
        add("Wine elegido a mano: \(resolved.path)", level: .success)
    }

    public func forgetCustomWine() {
        customWineURL = nil
        Preferences.customWineURL = nil
        refreshTools()
    }

    public func openWineSettings() {
        guard let wine = runtimeStatus.wineURL else { return }
        launchDetached(WineLauncher.configCommand(wine: wine), describing: "Abriendo la configuración de Wine")
    }

    public func closeWindowsPrograms() {
        guard let wine = runtimeStatus.wineURL else { return }
        launchDetached(WineLauncher.killCommand(wine: wine), describing: "Cerrando los programas de Windows")
    }

    public var windowsFolderURL: URL { WineLauncher.prefixURL }

    /// Borra el entorno de Windows. Se vuelve a crear solo en la siguiente ejecución.
    public func resetWindowsEnvironment() {
        guard !isRunningProgram, !isPreparingWindows else {
            showError("Espera a que termine el programa que está en marcha.")
            return
        }
        do {
            try WineLauncher.resetPrefix()
            add("Entorno de Windows borrado. Se creará de nuevo la próxima vez que ejecutes algo.", level: .success)
            activityMessage = "Windows restablecido"
        } catch {
            showError("No se pudo borrar el entorno: \(error.localizedDescription)")
        }
    }

    // MARK: - Ejecutar un programa de Windows

    public func runProgram() {
        guard !isRunningProgram, !isPreparingWindows else { return }
        guard let program = selectedProgram,
              SupportedFileKind.exe.accepts(program),
              fileManager.isReadableFile(atPath: program.path) else {
            showError("Elige un programa .exe o .msi válido.")
            return
        }
        guard let wine = runtimeStatus.wineURL else {
            showError("No hay Wine disponible. Instálalo o búscalo a mano.")
            return
        }
        if !runtimeStatus.hasRosetta {
            showError("Falta Rosetta 2, que Wine necesita en los Mac con chip Apple. Instálalo con: softwareupdate --install-rosetta")
            return
        }
        if wineIsBlocked {
            showError("macOS tiene Wine bloqueado porque lo marcó como descargado de internet. Pulsa «Desbloquear Wine» y vuelve a intentarlo.")
            return
        }

        clearError()
        let session = ProcessSession()
        programSession = session

        Task { [weak self] in
            guard let self else { return }

            if WineLauncher.needsFirstRunSetup() {
                isPreparingWindows = true
                activityMessage = "Preparando Windows por primera vez…"
                add("Primer arranque: creando el entorno de Windows. Puede tardar un par de minutos.", level: .info)
                let boot = WineLauncher.bootCommand(wine: wine)
                _ = try? await runner.run(boot, session: session) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
                isPreparingWindows = false
                if session.isCancelled {
                    finishProgram(message: "Preparación cancelada", level: .warning)
                    return
                }
                // Si el entorno sigue incompleto, seguir solo llevaría a un error críptico.
                if WineLauncher.needsFirstRunSetup() {
                    finishProgram(message: "No se pudo preparar Windows", level: .failure)
                    showError("Este Wine no consigue crear el entorno de Windows. Suele pasar con la versión «wine-stable» de Homebrew, que ya no es compatible con las versiones recientes de macOS. Prueba con otro Wine (CrossOver, Kegworks o una compilación para Apple Silicon) desde «Otro Wine».")
                    return
                }
                add("Entorno de Windows listo.", level: .success)
            }

            isRunningProgram = true
            activityMessage = "Ejecutando \(program.lastPathComponent)"
            add("Ejecutando \(program.lastPathComponent) con Wine…", level: .info)

            let command = WineLauncher.runCommand(wine: wine, program: program)
            do {
                let result = try await runner.run(command, session: session) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
                if result.wasCancelled {
                    finishProgram(message: "Detenido", level: .warning)
                } else if result.succeeded {
                    finishProgram(message: "El programa se cerró", level: .success)
                } else {
                    activityMessage = "Terminó con errores"
                    isRunningProgram = false
                    showError(explain(exitCode: result.exitCode, forProgram: true))
                }
            } catch {
                isRunningProgram = false
                activityMessage = "No se pudo iniciar"
                showError(error.localizedDescription)
            }
            programSession = nil
        }
    }

    /// Quita la marca de cuarentena que impide arrancar Wine.
    public func unblockWine() {
        guard !isUnblockingWine, let wine = runtimeStatus.wineURL else { return }
        let target = QuarantineGuard.repairTarget(for: wine)

        isUnblockingWine = true
        clearError()
        add("Desbloqueando \(target.lastPathComponent)…", level: .info)

        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(QuarantineGuard.repairCommand(for: wine)) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            isUnblockingWine = false
            wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)

            if wineIsBlocked {
                showError("No se pudo desbloquear Wine. Desde la Terminal: xattr -dr com.apple.quarantine \"\(target.path)\"")
            } else {
                activityMessage = "Wine desbloqueado"
                add("Wine desbloqueado. Ya se pueden ejecutar programas de Windows.", level: .success)
                _ = result
            }
        }
    }

    public func stopProgram() {
        programSession?.cancel()
        add("Pidiendo el cierre del programa…", level: .warning)
    }

    private func finishProgram(message: String, level: LogLevel) {
        isRunningProgram = false
        isPreparingWindows = false
        activityMessage = message
        add(message, level: level)
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
                archiveContents = []
                return
            }
            archiveContents = ArchiveCommandBuilder.names(fromListing: result.output, usedLister: usedLister)
        }
    }

    public func extractArchive() {
        guard !isExtracting else { return }
        guard let archive = selectedArchive,
              SupportedFileKind.rar.accepts(archive),
              fileManager.isReadableFile(atPath: archive.path) else {
            showError("Elige un archivo comprimido válido.")
            return
        }
        guard let destination = effectiveDestination else {
            showError("Elige una carpeta de destino.")
            return
        }
        guard let tool = runtimeStatus.tool(for: archive) else {
            showError("No hay ningún extractor instalado. Pulsa «Instalar herramientas».")
            return
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            showError("No se pudo crear la carpeta «\(destination.lastPathComponent)»: \(error.localizedDescription)")
            return
        }

        // Si la carpeta estaba vacía, un reintento puede reemplazar sin miedo lo que quedó a medias.
        let destinationWasEmpty = isEmptyDirectory(destination)

        clearError()
        lastSuccessFolder = nil
        extractionProgress = tool.reportsProgress ? 0 : nil
        isExtracting = true
        activityMessage = "Extrayendo \(archive.lastPathComponent)"
        add("Extrayendo \(archive.lastPathComponent) con \(tool.displayName)…", level: .info)

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
                finishExtraction(message: "Extracción detenida")
                add("Extracción detenida. Lo ya extraído sigue en la carpeta.", level: .warning)
                return
            }

            if result.succeeded {
                finishExtraction(message: "Extraído")
                add("Listo. El contenido está en \(destination.path)", level: .success)
                add("El archivo original no se ha tocado.", level: .info)
                lastSuccessFolder = destination
                if revealWhenDone { FileActions.openInFinder(destination) }
                return
            }

            // Cada extractor cubre formatos distintos: si uno no puede, se prueba con el otro.
            if !isRetry, let alternative = runtimeStatus.fallbackTool(for: archive, after: tool) {
                add("\(tool.displayName) no pudo con este archivo. Probando con \(alternative.displayName)…", level: .warning)
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

            finishExtraction(message: "Terminó con errores")
            showError(explain(exitCode: result.exitCode, forProgram: false))
        } catch {
            finishExtraction(message: "No se pudo iniciar")
            showError(error.localizedDescription)
        }
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

    public func stopExtraction() {
        extractionSession?.cancel()
        add("Deteniendo la extracción…", level: .warning)
    }

    public func revealResult() {
        guard let lastSuccessFolder else { return }
        FileActions.openInFinder(lastSuccessFolder)
    }

    // MARK: - Instalar herramientas

    public func installTools() {
        guard !isInstallingTools else { return }
        guard let homebrew = runtimeStatus.homebrewURL else {
            showError("Homebrew no está instalado. Instálalo desde brew.sh y vuelve a intentarlo.")
            return
        }

        // Solo los extractores. Wine no se instala a ciegas: en Apple Silicon las versiones de
        // Homebrew chocan entre sí y varias están obsoletas, así que se explican las opciones.
        guard runtimeStatus.archiveTool == nil else {
            add("Los extractores ya están instalados.", level: .success)
            return
        }
        let formulae = ["sevenzip", "unar"]

        clearError()
        isInstallingTools = true
        activityMessage = "Instalando herramientas"
        add("Instalando con Homebrew: \(formulae.joined(separator: ", "))", level: .info)
        add("Suele tardar un par de minutos.", level: .info)

        let command = ProcessCommand(
            executableURL: homebrew,
            arguments: ["install"] + formulae,
            currentDirectoryURL: nil,
            environment: ["PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":"),
                          "HOMEBREW_NO_AUTO_UPDATE": "1"]
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
                    activityMessage = "Herramientas instaladas"
                    add("Instalación terminada.", level: .success)
                } else {
                    activityMessage = "La instalación falló"
                    showError("Homebrew terminó con el código \(result.exitCode). Revisa la actividad para ver el motivo.")
                }
            } catch {
                isInstallingTools = false
                activityMessage = "No se pudo iniciar"
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Registro de actividad

    public func clearLog() {
        log.removeAll()
        lastError = nil
        activityMessage = "Todo listo"
    }

    public func copyLog() {
        let text = log.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
        FileActions.copyToClipboard(text)
        add("Actividad copiada al portapapeles.", level: .info)
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
    private func explain(exitCode: Int32, forProgram: Bool) -> String {
        if forProgram {
            switch exitCode {
            case 53:
                return "Wine se cerró sin poder arrancar el programa. Si acaba de pasar en el primer arranque, es que esta versión de Wine no funciona en tu macOS: prueba con otra desde «Otro Wine»."
            case 127:
                return "Wine no encontró algo que necesita. Revisa la actividad para ver qué biblioteca falta."
            default:
                return "El programa terminó con el código \(exitCode). Muchos programas de Windows no funcionan bajo Wine: los que necesitan controladores, anti-trampas o gráficos especiales suelen fallar."
            }
        }

        switch exitCode {
        case 2:
            return "Ningún extractor pudo con este comprimido. Si tiene contraseña, escríbela arriba; si está partido en varias partes, déjalas todas en la misma carpeta. Instalar «unar» suele resolver los .rar más antiguos."
        case 1:
            return "La extracción terminó con avisos. Revisa la actividad: puede que algún archivo se haya saltado."
        default:
            return "El extractor terminó con el código \(exitCode). Revisa la actividad para ver el motivo."
        }
    }

    // MARK: - Utilidades

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
