import Foundation

/// Herramienta capaz de abrir archivos comprimidos, con la ruta de su ejecutable.
public enum ArchiveTool: Equatable, Sendable {
    case sevenZip(URL)
    case unar(URL)
    case unrar(URL)

    public var executableURL: URL {
        switch self {
        case .sevenZip(let url), .unar(let url), .unrar(let url):
            return url
        }
    }

    public var displayName: String {
        switch self {
        case .sevenZip: return "7zz"
        case .unar: return "unar"
        case .unrar: return "unrar"
        }
    }

    /// Solo `7zz` informa del porcentaje mientras extrae.
    public var reportsProgress: Bool {
        if case .sevenZip = self { return true }
        return false
    }
}

/// Qué hacer cuando un archivo ya existe en el destino.
public enum OverwritePolicy: String, CaseIterable, Identifiable, Sendable {
    case skip
    case rename
    case overwrite

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .skip: return "Conservar los existentes"
        case .rename: return "Renombrar los nuevos"
        case .overwrite: return "Sobrescribir"
        }
    }

    public var explanation: String {
        switch self {
        case .skip: return "Si un archivo ya está en la carpeta, se deja como está."
        case .rename: return "Los archivos repetidos se guardan con otro nombre."
        case .overwrite: return "Los archivos repetidos se reemplazan por los del comprimido."
        }
    }
}

/// Retrato de las herramientas disponibles en el sistema.
public struct RuntimeStatus: Equatable, Sendable {
    public let wineURL: URL?
    /// Todos los extractores encontrados. Cuál se usa depende del formato del archivo.
    public let archiveTools: [ArchiveTool]
    public let homebrewURL: URL?
    public let hasRosetta: Bool
    /// El puente con los aparatos Android. Es lo unico imprescindible para instalar un `.apk`:
    /// con un movil enchufado basta, sin emulador ni SDK completo.
    public let adbURL: URL?
    /// El emulador de Android. Opcional a proposito: pesa gigas y solo hace falta si no hay
    /// ningun movil a mano.
    public let emulatorURL: URL?

    public init(
        wineURL: URL?,
        archiveTools: [ArchiveTool],
        homebrewURL: URL?,
        hasRosetta: Bool = true,
        adbURL: URL? = nil,
        emulatorURL: URL? = nil
    ) {
        self.wineURL = wineURL
        self.archiveTools = archiveTools
        self.homebrewURL = homebrewURL
        self.hasRosetta = hasRosetta
        self.adbURL = adbURL
        self.emulatorURL = emulatorURL
    }

    public var archiveTool: ArchiveTool? { archiveTools.first }

    /// Nombre de lo que hay instalado, para enseñarlo en la barra superior.
    public var archiveToolName: String? {
        archiveTools.isEmpty ? nil : archiveTools.map(\.displayName).joined(separator: " · ")
    }

    /// El extractor adecuado para **este** archivo.
    ///
    /// Para `.rar` manda `unar`: `7zz` no sabe descomprimir varios métodos de RAR antiguos y,
    /// lo peor, no falla del todo — crea los archivos vacíos, de 0 bytes. `unar` usa la
    /// implementación de The Unarchiver y los abre todos. Para el resto de formatos, `7zz` va
    /// mejor: es más rápido, cubre más formatos e informa del progreso.
    public func tool(for archive: URL) -> ArchiveTool? {
        let order: [(ArchiveTool) -> Bool] = isRar(archive)
            ? [{ if case .unar = $0 { return true }; return false },
               { if case .unrar = $0 { return true }; return false },
               { if case .sevenZip = $0 { return true }; return false }]
            : [{ if case .sevenZip = $0 { return true }; return false },
               { if case .unar = $0 { return true }; return false },
               { if case .unrar = $0 { return true }; return false }]

        for matches in order {
            if let tool = archiveTools.first(where: matches) { return tool }
        }
        return nil
    }

    /// El siguiente extractor a probar si el primero falla.
    public func fallbackTool(for archive: URL, after used: ArchiveTool) -> ArchiveTool? {
        archiveTools.first { $0.displayName != used.displayName }
    }

    private func isRar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".rar") || name.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil
    }

    public var canRunWindows: Bool { wineURL != nil }
    public var canExtract: Bool { !archiveTools.isEmpty }
    /// Con `adb` ya se puede instalar en un móvil enchufado. El emulador es otra cosa.
    public var canReachAndroid: Bool { adbURL != nil }
    public var canStartEmulator: Bool { emulatorURL != nil }

    /// Todo listo: se puede ejecutar, extraer e instalar sin añadir nada más.
    public var isComplete: Bool { canRunWindows && canExtract && canReachAndroid }
}

/// Una orden concreta que se le pide al sistema.
public struct ProcessCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    /// Variables que se añaden al entorno heredado. `nil` significa heredarlo tal cual.
    public let environment: [String: String]?

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
    }

    /// Representación legible, apta para copiar y pegar en la Terminal.
    public var shellDescription: String {
        ([executableURL.path] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let wasCancelled: Bool

    public var succeeded: Bool { exitCode == 0 && !wasCancelled }

    public init(exitCode: Int32, output: String, wasCancelled: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.wasCancelled = wasCancelled
    }
}

/// Severidad de una línea del registro de actividad, para pintarla distinto.
public enum LogLevel: Sendable {
    case info
    case success
    case warning
    case failure
    case output
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let level: LogLevel
    public let date: Date

    public init(text: String, level: LogLevel, date: Date = Date()) {
        self.text = text
        self.level = level
        self.date = date
    }

    public var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// Una forma concreta de conseguir Wine, con la orden lista para copiar.
public struct WineOption: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let detail: String
    public let command: String?

    public init(name: String, detail: String, command: String?) {
        self.name = name
        self.detail = detail
        self.command = command
    }
}
