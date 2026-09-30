import Foundation

/// Lo que se sabe de un comprimido antes de extraerlo.
public struct ArchiveAssessment: Equatable, Sendable {
    public let format: ArchiveFormat
    public let entryCount: Int
    public let findings: [SafeFinding]
    /// Suma de los tamaños declarados, o `nil` si alguna entrada no declara el suyo.
    public let declaredBytes: Int64?
    public let largestEntryBytes: Int64?
    /// Lo que impide extraer: que no quepa o que declare demasiadas entradas.
    public let blockingProblem: SafeFinding?
    /// `false` cuando no se pudo leer el índice: no se sabe lo que hay dentro.
    public let inspected: Bool

    public var recommendation: SafeRecommendation {
        SafeRecommendation(reasons: findings.filter { $0.severity >= .warning })
    }
}

/// Reglas de nombres y contenido que comparten el análisis previo y el inventario posterior.
public enum SafeContentRules {
    /// DLL de Windows que un programa carga del sistema, pero que si aparecen junto al ejecutable
    /// se cargan **en su lugar**. Es la técnica de cracks, mods y malware; no dice cuál de las tres
    /// es, pero significa que al abrir el programa se ejecuta código que no es del programa.
    public static let systemDllNames: Set<String> = [
        "winmm.dll", "version.dll", "winhttp.dll", "wininet.dll", "dinput8.dll", "dinput.dll",
        "dsound.dll", "d3d9.dll", "d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "opengl32.dll",
        "xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll", "iphlpapi.dll", "userenv.dll",
        "uxtheme.dll", "wtsapi32.dll", "secur32.dll", "cryptbase.dll", "cryptsp.dll", "dwmapi.dll",
        "msimg32.dll", "netapi32.dll", "profapi.dll", "propsys.dll", "sspicli.dll", "mswsock.dll",
        "ws2_32.dll", "wsock32.dll", "hid.dll", "setupapi.dll", "winspool.drv", "ddraw.dll",
        "dbgcore.dll", "mscoree.dll", "bcrypt.dll", "ncrypt.dll", "shfolder.dll", "avrt.dll"
    ]

    static let scriptExtensions: Set<String> = [
        "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "reg", "sh",
        "command", "py", "scpt", "applescript"
    ]
    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "cab", "arj", "lzh", "z"
    ]
    static let webShortcutExtensions: Set<String> = ["url", "webloc", "website", "inetloc"]
    static let macInstallerExtensions: Set<String> = ["pkg", "mpkg", "dmg"]
    static let executableExtensions: Set<String> = [
        "exe", "scr", "com", "pif", "bat", "cmd", "vbs", "vbe", "js", "jse", "wsf", "hta", "lnk",
        "msi", "ps1", "jar"
    ]

    public static func isScript(_ name: String) -> Bool {
        scriptExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isWindowsInstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext == "msi" { return true }
        guard ext == "exe" else { return false }
        return ["setup", "install", "redist", "unins", "prereq"].contains { lower.contains($0) }
    }

    /// Nombres hechos para engañar a quien los mira: caracteres que invierten el texto o no se ven,
    /// una extensión de documento delante de la de ejecutable, o espacios que empujan la extensión
    /// real fuera de la vista.
    public static func isDeceptiveName(_ name: String) -> Bool {
        let invisible: [ClosedRange<UInt32>] = [0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF...0xFEFF]
        if name.unicodeScalars.contains(where: { scalar in invisible.contains { $0.contains(scalar.value) } }) {
            return true
        }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        guard executableExtensions.contains(ext) else { return false }
        let stem = String(lower.dropLast(ext.count + 1))
        if stem.hasSuffix("   ") { return true }
        let decoy = (stem.trimmingCharacters(in: .whitespaces) as NSString).pathExtension
        return ["pdf", "jpg", "jpeg", "png", "gif", "txt", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
                "mp3", "mp4", "avi", "mkv", "mov", "zip", "rar"].contains(decoy)
    }

    /// Carpetas de aplicación de macOS dentro de un comprimido: `Algo.app/` y lo que cuelgue.
    static func macApplicationRoot(in path: String) -> String? {
        var root: [Substring] = []
        for component in path.split(separator: "/") {
            root.append(component)
            if component.lowercased().hasSuffix(".app") { return root.joined(separator: "/") }
        }
        return nil
    }
}

/// Mira el índice de un comprimido y dice lo que encuentra, antes de extraer nada.
public enum SafeArchiveAnalyzer {
    /// Más entradas que esto no las trae un juego ni un programa: es un ataque al sistema de
    /// archivos, o algo que no se debería abrir sin pensarlo.
    public static let maximumEntries = 500_000
    /// Lo que se deja libre siempre. Llenar el disco del todo deja el Mac inservible.
    public static let diskReserveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    /// - Parameter reclaimableBytes: lo que ocupan los espacios de **este mismo comprimido** que la
    ///   extracción que viene a continuación va a borrar. Cuenta como sitio libre porque va a serlo.
    ///   Vale `0` cuando no se va a borrar nada —el primer intento, o un espacio aparte—, y
    ///   entonces «no cabe» se decide contra el disco tal y como está ahora mismo.
    public static func assess(
        archive: URL,
        entries: [ArchiveEntry]?,
        format: ArchiveFormat,
        archiveBytes: Int64,
        freeBytes: Int64?,
        reclaimableBytes: Int64 = 0
    ) -> ArchiveAssessment {
        var findings: [SafeFinding] = []
        let archiveName = archive.lastPathComponent

        if let expected = ArchiveSignature.expectedFormat(for: archive), format != .unknown, expected != format {
            findings.append(SafeFinding(.extensionMismatch, subject: archiveName,
                                        detail: "\(archive.pathExtension.uppercased()) → \(format.displayName)"))
        }

        guard let entries else {
            findings.append(SafeFinding(.unreadableListing, subject: archiveName))
            return ArchiveAssessment(format: format, entryCount: 0, findings: findings, declaredBytes: nil,
                                     largestEntryBytes: nil, blockingProblem: nil, inspected: false)
        }

        var declared: Int64? = 0
        var largest: Int64 = 0
        var seen: [String: String] = [:]
        var executablesByDirectory: Set<String> = []
        var dllCandidates: [(directory: String, path: String)] = []
        var reportedApps: Set<String> = []
        var programCount = 0
        var nestedCount = 0
        var shortcutCount = 0
        var anyEncrypted = false

        for entry in entries {
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            let name = String(components.last ?? Substring(path))
            let directory = components.dropLast().joined(separator: "/").lowercased()
            let ext = (name as NSString).pathExtension.lowercased()

            if path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
                findings.append(SafeFinding(.absolutePath, subject: entry.path))
            }
            if components.contains("..") {
                findings.append(SafeFinding(.pathTraversal, subject: entry.path))
            }
            if entry.isSymbolicLink {
                findings.append(SafeFinding(.symbolicLink, subject: entry.path, detail: entry.linkTarget))
            }
            if entry.isHardLink {
                findings.append(SafeFinding(.hardLink, subject: entry.path, detail: entry.linkTarget))
            }
            if entry.isSpecialFile { findings.append(SafeFinding(.specialFile, subject: entry.path)) }
            if entry.hasSetIDBit { findings.append(SafeFinding(.setIDBit, subject: entry.path)) }
            if entry.isEncrypted { anyEncrypted = true }
            if SafeContentRules.isDeceptiveName(name) {
                findings.append(SafeFinding(.deceptiveName, subject: entry.path))
            }

            if !entry.isDirectory {
                // En APFS, que no distingue mayúsculas, dos nombres así son el mismo archivo.
                let key = path.lowercased()
                if let previous = seen[key], previous != path {
                    findings.append(SafeFinding(.caseCollision, subject: entry.path, detail: previous))
                } else {
                    seen[key] = path
                }
                if let size = entry.size {
                    declared = declared.map { $0 + size }
                    largest = max(largest, size)
                    if size > 1_073_741_824, let packed = entry.packedSize, packed > 0, size / packed > 1_000 {
                        findings.append(SafeFinding(.compressionBomb, subject: entry.path))
                    }
                } else {
                    declared = nil
                }
            }

            if let app = SafeContentRules.macApplicationRoot(in: path), reportedApps.insert(app.lowercased()).inserted {
                findings.append(SafeFinding(.macProgram, subject: app))
            }
            guard !entry.isDirectory else { continue }

            switch ext {
            case "exe":
                programCount += 1
                executablesByDirectory.insert(directory)
                if SafeContentRules.isWindowsInstaller(name) {
                    findings.append(SafeFinding(.windowsInstaller, subject: entry.path))
                }
            case "msi":
                findings.append(SafeFinding(.windowsInstaller, subject: entry.path))
            case "dll", "drv":
                if SafeContentRules.systemDllNames.contains(name.lowercased()) {
                    dllCandidates.append((directory, entry.path))
                }
            default:
                if SafeContentRules.macInstallerExtensions.contains(ext) {
                    findings.append(SafeFinding(.macProgram, subject: entry.path))
                } else if SafeContentRules.scriptExtensions.contains(ext) {
                    findings.append(SafeFinding(.script, subject: entry.path))
                } else if SafeContentRules.webShortcutExtensions.contains(ext) {
                    shortcutCount += 1
                } else if SafeContentRules.archiveExtensions.contains(ext) {
                    nestedCount += 1
                }
            }
        }

        for candidate in dllCandidates where executablesByDirectory.contains(candidate.directory) {
            findings.append(SafeFinding(.dllSideLoading, subject: candidate.path))
        }
        if anyEncrypted { findings.append(SafeFinding(.encryptedContent, subject: archiveName)) }
        if programCount > 0 { findings.append(SafeFinding(.windowsProgram, subject: archiveName, detail: String(programCount))) }
        if nestedCount > 0 { findings.append(SafeFinding(.nestedArchive, subject: archiveName, detail: String(nestedCount))) }
        if shortcutCount > 0 { findings.append(SafeFinding(.webShortcut, subject: archiveName, detail: String(shortcutCount))) }

        if let total = declared, total > 1_073_741_824, archiveBytes > 0, total / archiveBytes > 100 {
            findings.append(SafeFinding(.compressionBomb, subject: archiveName,
                                        detail: "\(total / archiveBytes):1"))
        }

        var blocking: SafeFinding?
        if entries.count > maximumEntries {
            blocking = SafeFinding(.tooManyEntries, subject: archiveName, detail: String(entries.count))
        } else if let total = declared, let freeBytes, total + diskReserveBytes > freeBytes + reclaimableBytes {
            blocking = SafeFinding(.doesNotFit, subject: archiveName,
                                   detail: ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        }
        if let blocking { findings.append(blocking) }

        return ArchiveAssessment(
            format: format,
            entryCount: entries.count,
            findings: findings,
            declaredBytes: declared,
            largestEntryBytes: entries.isEmpty ? nil : largest,
            blockingProblem: blocking,
            inspected: true
        )
    }
}
