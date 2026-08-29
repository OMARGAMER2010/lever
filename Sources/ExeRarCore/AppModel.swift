import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    private let locator: RuntimeLocator
    private let runner: ProcessRunner
    private var customWineURL: URL?

    @Published public var selectedExe: URL?
    @Published public var selectedArchive: URL?
    @Published public var extractionDestination: URL?
    @Published public private(set) var runtimeStatus: RuntimeStatus
    @Published public var isBusy: Bool
    @Published public private(set) var activityMessage: String
    @Published public private(set) var logLines: [String]
    @Published public private(set) var lastError: String?

    public var canRunExe: Bool {
        guard let selectedExe else { return false }
        return !isBusy
            && SupportedFileKind.exe.accepts(selectedExe)
            && FileManager.default.isReadableFile(atPath: selectedExe.path)
            && runtimeStatus.wineURL != nil
    }

    public var canExtractArchive: Bool {
        guard let selectedArchive, let extractionDestination else { return false }
        var isDirectory = ObjCBool(false)
        let destinationExists = FileManager.default.fileExists(
            atPath: extractionDestination.path,
            isDirectory: &isDirectory
        )
        return !isBusy
            && SupportedFileKind.rar.accepts(selectedArchive)
            && FileManager.default.isReadableFile(atPath: selectedArchive.path)
            && destinationExists
            && isDirectory.boolValue
            && runtimeStatus.archiveTool != nil
    }

    public var canPrepareTools: Bool {
        !isBusy && runtimeStatus.homebrewURL != nil
    }

    public init(
        locator: RuntimeLocator = RuntimeLocator(),
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.locator = locator
        self.runner = runner
        self.customWineURL = nil
        self.selectedExe = nil
        self.selectedArchive = nil
        self.extractionDestination = nil
        self.runtimeStatus = locator.locate()
        self.isBusy = false
        self.activityMessage = "Listo"
        self.logLines = []
        self.lastError = nil
    }

    public func refreshTools() {
        runtimeStatus = locator.locate(customWineURL: customWineURL)
    }

    public func selectExe() {
        guard let url = FileActions.chooseFile(extensions: ["exe"]) else { return }
        guard SupportedFileKind.exe.accepts(url) else {
            showError("Selecciona un archivo con extensión .exe.")
            return
        }

        selectedExe = url
        clearError()
        addLog("EXE seleccionado: \(url.lastPathComponent)")
    }

    public func selectArchive() {
        guard let url = FileActions.chooseFile(extensions: ["rar"]) else { return }
        guard SupportedFileKind.rar.accepts(url) else {
            showError("Selecciona un archivo con extensión .rar.")
            return
        }

        selectedArchive = url
        clearError()
        addLog("RAR seleccionado: \(url.lastPathComponent)")
    }

    public func selectDestination() {
        guard let url = FileActions.chooseDirectory() else { return }
        extractionDestination = url
        clearError()
        addLog("Destino: \(url.path)")
    }

    public func selectWine() {
        guard let url = FileActions.chooseWine() else { return }
        guard let resolvedURL = RuntimeLocator.resolveWineURL(url) else {
            showError("La selección no parece un ejecutable Wine válido.")
            return
        }

        customWineURL = resolvedURL
        refreshTools()
        clearError()
        addLog("Wine seleccionado: \(resolvedURL.path)")
    }

    public func runSelectedExe() {
        guard !isBusy else { return }
        guard let exe = selectedExe,
              SupportedFileKind.exe.accepts(exe),
              FileManager.default.isReadableFile(atPath: exe.path) else {
            showError("Selecciona un archivo .exe válido.")
            return
        }
        guard let wine = runtimeStatus.wineURL else {
            showError("No hay un runtime Wine disponible. Usa “Buscar Wine”.")
            return
        }

        let command = ProcessCommand(
            executableURL: wine,
            arguments: [exe.path],
            currentDirectoryURL: exe.deletingLastPathComponent()
        )
        execute(command, activity: "Ejecutando \(exe.lastPathComponent)")
    }

    public func extractSelectedArchive() {
        guard !isBusy else { return }
        guard let archive = selectedArchive,
              SupportedFileKind.rar.accepts(archive),
              FileManager.default.isReadableFile(atPath: archive.path) else {
            showError("Selecciona un archivo .rar válido.")
            return
        }
        guard let destination = extractionDestination else {
            showError("Selecciona una carpeta de destino.")
            return
        }
        guard let archiveTool = runtimeStatus.archiveTool else {
            showError("No hay un extractor RAR disponible. Usa “Preparar herramientas”.")
            return
        }

        let command = ArchiveCommandBuilder.command(
            for: archiveTool,
            archive: archive,
            destination: destination
        )
        execute(command, activity: "Extrayendo \(archive.lastPathComponent)")
    }

    public func prepareTools() {
        guard !isBusy else { return }
        guard let homebrew = runtimeStatus.homebrewURL else {
            showError("Homebrew no está instalado.")
            return
        }

        let command = ProcessCommand(
            executableURL: homebrew,
            arguments: ["install", "sevenzip", "unar"],
            currentDirectoryURL: nil
        )
        execute(command, activity: "Preparando herramientas", refreshToolsWhenDone: true)
    }

    private func execute(
        _ command: ProcessCommand,
        activity: String,
        refreshToolsWhenDone: Bool = false
    ) {
        isBusy = true
        activityMessage = activity
        clearError()
        addLog(activity)

        Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await runner.run(command)
                if result.succeeded {
                    activityMessage = "Finalizado"
                    addLog("Finalizado correctamente (código 0)")
                } else {
                    activityMessage = "Terminó con errores"
                    showError("El proceso terminó con código \(result.exitCode).")
                }
                addOutput(result.output)
                if refreshToolsWhenDone {
                    refreshTools()
                }
            } catch {
                activityMessage = "No se pudo iniciar"
                showError(error.localizedDescription)
            }

            isBusy = false
        }
    }

    private func addLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 120 {
            logLines.removeFirst(logLines.count - 120)
        }
    }

    private func addOutput(_ output: String) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        lines.forEach(addLog)
    }

    private func clearError() {
        lastError = nil
    }

    private func showError(_ message: String) {
        lastError = message
        addLog("Error: \(message)")
    }
}
