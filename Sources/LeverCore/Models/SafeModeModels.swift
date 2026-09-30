import Foundation

/// Cómo se abre un archivo: como siempre, o dentro de un espacio aislado.
public enum OpenMode: String, Codable, CaseIterable, Sendable {
    case normal
    case safe
}

/// Cuánto pesa un hallazgo. Solo `warning` y `danger` cuentan como «sospechoso»: lo demás se
/// enseña en los detalles para quien quiera saberlo, pero no alarma a nadie.
public enum SafeSeverity: Int, Codable, Comparable, Sendable {
    /// Un dato: hay un acceso a una web, hay un comprimido dentro de otro.
    case info = 0
    /// Algo que conviene saber y no es raro en archivos legítimos: un ejecutable, un script.
    case notice
    /// Lo que casi nunca trae un archivo honrado, o una técnica que usa el malware.
    case warning
    /// Hostil sin discusión: firma de amenaza conocida, o una estructura hecha para escapar.
    case danger

    public static func < (lhs: SafeSeverity, rhs: SafeSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Qué se ha encontrado. Cada caso sabe su gravedad y su texto, para que la lista de reglas y la
/// forma de contarlo no se puedan despistar entre sí.
public enum SafeFindingKind: String, Codable, CaseIterable, Sendable {
    // Estructura del comprimido
    case pathTraversal
    case absolutePath
    case symbolicLink
    case hardLink
    case specialFile
    case setIDBit
    case deceptiveName
    case caseCollision
    case tooManyEntries
    case doesNotFit
    case compressionBomb
    case extensionMismatch
    case encryptedContent
    case nestedArchive
    case unreadableListing
    // Contenido
    case windowsProgram
    case windowsInstaller
    case script
    case riskyScript
    case macProgram
    case dllSideLoading
    case webShortcut
    case knownThreat
    // Lo que el aislamiento cortó mientras trabajaba
    case blockedLink
    case resourceLimit

    public var severity: SafeSeverity {
        switch self {
        case .pathTraversal, .absolutePath, .specialFile, .knownThreat, .resourceLimit:
            return .danger
        case .symbolicLink, .hardLink, .setIDBit, .deceptiveName, .extensionMismatch, .riskyScript,
             .macProgram, .dllSideLoading, .tooManyEntries, .blockedLink, .compressionBomb:
            return .warning
        // Que no quepa en el disco impide extraer, pero no dice nada de las intenciones del archivo.
        case .caseCollision, .encryptedContent, .unreadableListing, .windowsInstaller, .script, .doesNotFit:
            return .notice
        case .windowsProgram, .nestedArchive, .webShortcut:
            return .info
        }
    }

    public var textKey: TextKey {
        switch self {
        case .pathTraversal: return .safeFindingPathTraversal
        case .absolutePath: return .safeFindingAbsolutePath
        case .symbolicLink: return .safeFindingSymbolicLink
        case .hardLink: return .safeFindingHardLink
        case .specialFile: return .safeFindingSpecialFile
        case .setIDBit: return .safeFindingSetID
        case .deceptiveName: return .safeFindingDeceptiveName
        case .caseCollision: return .safeFindingCaseCollision
        case .tooManyEntries: return .safeFindingTooManyEntries
        case .doesNotFit: return .safeFindingDoesNotFit
        case .compressionBomb: return .safeFindingCompressionBomb
        case .extensionMismatch: return .safeFindingExtensionMismatch
        case .encryptedContent: return .safeFindingEncrypted
        case .nestedArchive: return .safeFindingNestedArchive
        case .unreadableListing: return .safeFindingUnreadable
        case .windowsProgram: return .safeFindingWindowsProgram
        case .windowsInstaller: return .safeFindingWindowsInstaller
        case .script: return .safeFindingScript
        case .riskyScript: return .safeFindingRiskyScript
        case .macProgram: return .safeFindingMacProgram
        case .dllSideLoading: return .safeFindingDllSideLoading
        case .webShortcut: return .safeFindingWebShortcut
        case .knownThreat: return .safeFindingKnownThreat
        case .blockedLink: return .safeFindingBlockedLink
        case .resourceLimit: return .safeFindingResourceLimit
        }
    }
}

/// Un hallazgo concreto: qué, dónde y, si hace falta, un dato más (el destino de un enlace, la
/// firma que encontró el escáner, las órdenes de riesgo de un script).
public struct SafeFinding: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let kind: SafeFindingKind
    /// Ruta dentro del comprimido o del espacio aislado, o el nombre del archivo.
    public let subject: String
    public let detail: String?

    public init(_ kind: SafeFindingKind, subject: String, detail: String? = nil) {
        self.kind = kind
        self.subject = subject
        self.detail = detail
    }

    public var id: String { "\(kind.rawValue)\u{1F}\(subject)\u{1F}\(detail ?? "")" }
    public var severity: SafeSeverity { kind.severity }
}

/// Lo que dijo el escáner de firmas, si lo hay. Es una capa más, nunca la protección.
public enum SafeSignatureScan: Codable, Equatable, Sendable {
    /// No hay escáner instalado, o no tiene firmas.
    case notAvailable
    /// No se analizó porque no había nada que analizar (ni ejecutables ni scripts).
    case nothingToScan
    case clean(engine: String)
    case detected(engine: String, count: Int)
    /// El escáner no terminó: tardó demasiado o falló. No se concluye nada.
    case failed(engine: String)
}

/// La frase que resume el informe. Ninguna dice «seguro»: ningún análisis puede prometerlo.
public enum SafeVerdict: Equatable, Sendable {
    /// Un escáner de firmas reconoció amenazas.
    case knownThreats(Int)
    /// Hay hallazgos que casi nunca trae un archivo honrado.
    case suspicious(Int)
    /// No se pudo mirar dentro: cifrado, o el listado falló.
    case unverified
    /// Se revisó la estructura y no hay nada raro, pero no había escáner de firmas.
    case nothingSuspicious
    /// Estructura sin nada raro y el escáner de firmas no reconoció nada.
    case noKnownThreats
}

/// Un programa de Windows encontrado dentro del espacio aislado, que se puede ejecutar allí.
public struct SafeExecutable: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Ruta relativa a la carpeta de archivos del espacio.
    public let relativePath: String
    public let isInstaller: Bool
    public let architecture: String?
    /// Si la cabecera PE trae certificado. **No** se valida: solo se dice si viene firmado.
    public let hasSignature: Bool
    public let sha256: String?

    public init(relativePath: String, isInstaller: Bool, architecture: String?, hasSignature: Bool, sha256: String?) {
        self.relativePath = relativePath
        self.isInstaller = isInstaller
        self.architecture = architecture
        self.hasSignature = hasSignature
        self.sha256 = sha256
    }

    public var id: String { relativePath }
    public var name: String { (relativePath as NSString).lastPathComponent }
}

/// Lo que Safe Mode sabe de un archivo después de procesarlo.
public struct SafeReport: Codable, Equatable, Sendable {
    public var findings: [SafeFinding]
    public var executables: [SafeExecutable]
    public var signatureScan: SafeSignatureScan
    public var entryCount: Int
    public var totalBytes: Int64?
    /// `false` cuando no se pudo leer la estructura. Sin eso no hay conclusión posible.
    public var inspected: Bool
    /// Si en la última ejecución se permitió la red. Por defecto no.
    public var networkAllowed: Bool

    public init(
        findings: [SafeFinding] = [],
        executables: [SafeExecutable] = [],
        signatureScan: SafeSignatureScan = .notAvailable,
        entryCount: Int = 0,
        totalBytes: Int64? = nil,
        inspected: Bool = true,
        networkAllowed: Bool = false
    ) {
        self.findings = findings
        self.executables = executables
        self.signatureScan = signatureScan
        self.entryCount = entryCount
        self.totalBytes = totalBytes
        self.inspected = inspected
        self.networkAllowed = networkAllowed
    }

    /// Hallazgos que cuentan como sospechosos, de lo más grave a lo menos.
    public var suspicious: [SafeFinding] {
        findings.filter { $0.severity >= .warning }.sorted { $0.severity > $1.severity }
    }

    public var verdict: SafeVerdict {
        if case .detected(_, let count) = signatureScan { return .knownThreats(count) }
        let threats = findings.filter { $0.kind == .knownThreat }.count
        if threats > 0 { return .knownThreats(threats) }
        if !suspicious.isEmpty { return .suspicious(suspicious.count) }
        let unreadable = findings.contains { $0.kind == .encryptedContent || $0.kind == .unreadableListing }
        if !inspected || unreadable { return .unverified }
        if case .clean = signatureScan { return .noKnownThreats }
        return .nothingSuspicious
    }
}

/// Por qué Lever recomienda Safe Mode para un archivo, antes de hacer nada con él.
public struct SafeRecommendation: Equatable, Sendable {
    /// Solo señales fuertes. Que un archivo venga de internet no basta: lo es casi todo, y un aviso
    /// que salta siempre deja de leerse.
    public let reasons: [SafeFinding]

    public init(reasons: [SafeFinding]) {
        self.reasons = reasons
    }

    public static let none = SafeRecommendation(reasons: [])
    public var isRecommended: Bool { !reasons.isEmpty }
}

/// Lo que este mismo comprimido ya dejó extraído de antes.
///
/// Existe para poder decirlo **antes** de volver a extraer. Sin esto, extraer dos veces el mismo
/// archivo creaba dos espacios completos, cada uno con todo dentro, y lo único que lo delataba era
/// el disco llenándose.
public struct SafePreviousExtractions: Equatable, Sendable {
    public let spaces: [SafeWorkspace]
    /// Lo que ocupan entre todos, ya medido: recorrer las carpetas no puede hacerse al dibujar.
    public let bytes: Int64
    /// Cuándo se hizo la más reciente.
    public let latest: Date?

    public init(spaces: [SafeWorkspace], bytes: Int64, latest: Date?) {
        self.spaces = spaces
        self.bytes = bytes
        self.latest = latest
    }

    public static let none = SafePreviousExtractions(spaces: [], bytes: 0, latest: nil)
    public var isEmpty: Bool { spaces.isEmpty }
    public var count: Int { spaces.count }
    public var formattedSize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// «hace 5 minutos». Vacío si no se sabe cuándo fue.
    public var formattedAge: String {
        guard let latest else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: latest, relativeTo: Date())
    }
}

/// Si Safe Mode se puede usar en este Mac. Se comprueba aplicando de verdad un aislamiento: que
/// exista la herramienta no demuestra que el sistema la respete.
public enum SandboxAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}
