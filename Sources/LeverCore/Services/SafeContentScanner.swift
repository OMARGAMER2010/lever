import CoreServices
import CryptoKit
import Darwin
import Foundation

/// Lo que dejó el barrido de una carpeta extraída o importada.
public struct SafeSweepResult: Equatable, Sendable {
    public let findings: [SafeFinding]
    public let executables: [SafeExecutable]
    /// Ejecutables y scripts, para el escáner de firmas.
    public let scanTargets: [URL]
    public let fileCount: Int
    public let totalBytes: Int64
}

/// Hechos de una cabecera PE. No se ejecuta ni se carga nada: se leen unos cientos de bytes.
public struct PEFacts: Equatable, Sendable {
    public let architecture: ProgramArchitecture
    public let isDLL: Bool
    /// Trae tabla de certificados. **No** se valida la firma, solo se dice si viene.
    public let hasSignature: Bool
    public let isDotNet: Bool

    public static func read(_ url: URL) -> PEFacts? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else { return nil }
        let peOffset = UInt64(le32(dos, 0x3C))
        guard peOffset > 0, peOffset < 0x1000_0000, (try? handle.seek(toOffset: peOffset)) != nil,
              let header = try? handle.read(upToCount: 24 + 240), header.count >= 24 + 112,
              header[0] == 0x50, header[1] == 0x45, header[2] == 0, header[3] == 0 else { return nil }

        let machine = UInt16(header[4]) | UInt16(header[5]) << 8
        let characteristics = UInt16(header[22]) | UInt16(header[23]) << 8
        let optional = 24
        let magic = UInt16(header[optional]) | UInt16(header[optional + 1]) << 8
        // Los directorios de datos empiezan en 96 (PE32) o 112 (PE32+) dentro de la cabecera opcional.
        let directories = optional + (magic == 0x20B ? 112 : 96)
        let countOffset = directories - 4
        let count = header.count >= countOffset + 4 ? le32(header, countOffset) : 0

        func directorySize(_ index: Int) -> UInt32 {
            let offset = directories + index * 8 + 4
            guard UInt32(index) < count, header.count >= offset + 4 else { return 0 }
            return le32(header, offset)
        }

        let architecture: ProgramArchitecture
        switch machine {
        case 0x014C: architecture = .bits32
        case 0x8664: architecture = .bits64
        case 0xAA64: architecture = .arm64
        default: architecture = .unknown
        }
        return PEFacts(
            architecture: architecture,
            isDLL: characteristics & 0x2000 != 0,
            hasSignature: directorySize(4) > 0,
            isDotNet: directorySize(14) > 0
        )
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
    }
}

/// Revisa lo extraído: lo deja inerte para macOS y dice qué hay dentro.
public enum SafeContentScanner {
    /// Órdenes que un script legítimo de un juego casi nunca necesita. Se enseña el trozo exacto que
    /// coincidió, no una etiqueta: así cualquiera puede comprobarlo.
    static let riskyScriptPatterns: [String] = [
        #"-enc(odedcommand)?\s+[A-Za-z0-9+/=]{20,}"#,
        #"frombase64string"#,
        #"invoke-webrequest|downloadstring|downloadfile|start-bitstransfer|net\.webclient"#,
        #"bitsadmin(\.exe)?\s"#,
        #"certutil(\.exe)?\s+-urlcache"#,
        #"\b(curl|wget)(\.exe)?\s+[^\r\n]*https?://"#,
        #"-windowstyle\s+hidden"#,
        #"\bmshta(\.exe)?\s"#,
        #"regsvr32(\.exe)?\s+[^\r\n]*/i:"#,
        #"currentversion\\run"#,
        #"schtasks(\.exe)?\s+/create"#,
        #"start menu\\programs\\startup"#,
        #"add-mppreference|set-mppreference|disablerealtimemonitoring"#,
        #"netsh\s+advfirewall"#,
        #"vssadmin(\.exe)?\s+delete"#,
        #"wevtutil(\.exe)?\s+cl"#,
        #"\bdel\s+/[a-z/ ]*[a-z]:\\\s"#,
        #"\brd\s+/s\s+/q\s+[a-z]:\\"#,
        #"launchctl\s+(load|bootstrap)"#,
        #"library/launchagents"#,
        #"\bosascript\b"#,
        #"xattr\s+-[a-z]*d[a-z]*\s+com\.apple\.quarantine"#,
        #"spctl\s+--master-disable"#
    ]

    public static func sweep(root: URL, applyQuarantine: Bool = true, fileManager: FileManager = .default) -> SafeSweepResult {
        let rootPath = root.path
        var findings: [SafeFinding] = []
        var executables: [SafeExecutable] = []
        var targets: [URL] = []
        var fileCount = 0
        var totalBytes: Int64 = 0
        var directoriesWithPrograms: Set<String> = []
        var systemNamedDlls: [(directory: String, relative: String)] = []
        var shortcuts = 0
        let quarantine: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Lever",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String
        ]

        // `enumerator(atPath:)` no entra por los enlaces: los enseña como una entrada más.
        let relativePaths = (fileManager.enumerator(atPath: rootPath)?.allObjects as? [String]) ?? []
        for relative in relativePaths {
            let path = rootPath + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            let name = (relative as NSString).lastPathComponent
            let directory = (relative as NSString).deletingLastPathComponent.lowercased()

            switch type {
            case S_IFLNK:
                // El aislamiento no deja crearlos; si alguno llegó, no se queda.
                let target = (try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? ""
                unlink(path)
                findings.append(SafeFinding(.blockedLink, subject: relative, detail: target))
                continue
            case S_IFDIR:
                _ = chmod(path, (info.st_mode & 0o755) | 0o700)
                if name.lowercased().hasSuffix(".app") {
                    findings.append(SafeFinding(.macProgram, subject: relative))
                }
                if applyQuarantine { setQuarantine(path, quarantine) }
                continue
            case S_IFREG:
                break
            default:
                unlink(path)
                findings.append(SafeFinding(.specialFile, subject: relative))
                continue
            }

            if info.st_nlink > 1 {
                // Un enlace duro compartiría el archivo con otro sitio: se rompe la relación.
                unlink(path)
                findings.append(SafeFinding(.blockedLink, subject: relative))
                continue
            }
            if info.st_mode & (S_ISUID | S_ISGID) != 0 {
                findings.append(SafeFinding(.setIDBit, subject: relative))
            }
            // Sin ejecución, sin setuid y sin escritura para otros. Wine no necesita el bit de
            // ejecución para cargar un .exe; macOS sí para ejecutar lo que no debería.
            _ = chmod(path, (info.st_mode & 0o644) | 0o600)
            if applyQuarantine { setQuarantine(path, quarantine) }

            fileCount += 1
            totalBytes += Int64(info.st_size)
            let url = URL(fileURLWithPath: path)
            let ext = (name as NSString).pathExtension.lowercased()
            let magic = head(of: path)

            if magic.starts(with: [0x4D, 0x5A]), let pe = PEFacts.read(url) {
                targets.append(url)
                if pe.isDLL {
                    if SafeContentRules.systemDllNames.contains(name.lowercased()) {
                        systemNamedDlls.append((directory, relative))
                    }
                } else if ext == "exe" || ext == "scr" || ext == "com" {
                    directoriesWithPrograms.insert(directory)
                    executables.append(SafeExecutable(
                        relativePath: relative,
                        isInstaller: SafeContentRules.isWindowsInstaller(name),
                        architecture: pe.architecture == .unknown ? nil : architectureLabel(pe.architecture),
                        hasSignature: pe.hasSignature,
                        sha256: info.st_size <= 2_147_483_648 ? sha256(of: url) : nil
                    ))
                    if SafeContentRules.isWindowsInstaller(name) {
                        findings.append(SafeFinding(.windowsInstaller, subject: relative))
                    }
                }
            } else if ext == "msi" {
                targets.append(url)
                executables.append(SafeExecutable(relativePath: relative, isInstaller: true, architecture: nil,
                                                  hasSignature: false, sha256: sha256(of: url)))
                findings.append(SafeFinding(.windowsInstaller, subject: relative))
            } else if isMachO(magic) || magic.starts(with: Array("xar!".utf8)) || ext == "dmg" {
                targets.append(url)
                findings.append(SafeFinding(.macProgram, subject: relative))
            } else if SafeContentRules.isScript(name) || magic.starts(with: Array("#!".utf8)) {
                targets.append(url)
                if let matches = riskyCommands(in: url) {
                    findings.append(SafeFinding(.riskyScript, subject: relative, detail: matches))
                } else {
                    findings.append(SafeFinding(.script, subject: relative))
                }
            } else if SafeContentRules.webShortcutExtensions.contains(ext) {
                shortcuts += 1
            }

            if SafeContentRules.isDeceptiveName(name) {
                findings.append(SafeFinding(.deceptiveName, subject: relative))
            }
            // Lo que se llama como un ejecutable se analiza aunque por dentro no lo parezca.
            if SafeContentRules.executableExtensions.contains(ext), targets.last != url {
                targets.append(url)
            }
        }

        for dll in systemNamedDlls where directoriesWithPrograms.contains(dll.directory) {
            findings.append(SafeFinding(.dllSideLoading, subject: dll.relative))
        }
        if !executables.isEmpty {
            findings.append(SafeFinding(.windowsProgram, subject: root.lastPathComponent, detail: String(executables.count)))
        }
        if shortcuts > 0 {
            findings.append(SafeFinding(.webShortcut, subject: root.lastPathComponent, detail: String(shortcuts)))
        }
        executables.sort { lhs, rhs in
            // Primero los juegos y programas, luego los instaladores; y los menos anidados antes.
            if lhs.isInstaller != rhs.isInstaller { return !lhs.isInstaller }
            let depth = { (e: SafeExecutable) in e.relativePath.split(separator: "/").count }
            if depth(lhs) != depth(rhs) { return depth(lhs) < depth(rhs) }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        return SafeSweepResult(findings: findings, executables: executables, scanTargets: targets,
                               fileCount: fileCount, totalBytes: totalBytes)
    }

    /// Quita los enlaces de dentro de una carpeta que apunten fuera de ella. Devuelve cuántos.
    ///
    /// Al extraer no se pueden crear; en una sesión de Windows sí, porque Wine los necesita para
    /// sus unidades. Dentro del aislamiento da igual —el kernel mira la ruta resuelta, así que un
    /// enlace a tus Documentos no lleva a ninguna parte—, pero cuando la sesión termina esa carpeta
    /// se abre en el Finder como una carpeta tuya, y ahí el enlace sí funciona.
    @discardableResult
    public static func removeEscapingLinks(under root: URL, fileManager: FileManager = .default) -> Int {
        guard let base = try? SandboxPath.canonical(root) else { return 0 }
        let inside = base + "/"
        var removed = 0
        // `enumerator(atPath:)` no entra por los enlaces: los enseña como una entrada más.
        for relative in (fileManager.enumerator(atPath: base)?.allObjects as? [String]) ?? [] {
            let path = base + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { continue }
            // Uno que ni siquiera se puede leer no se queda.
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
                unlink(path)
                removed += 1
                continue
            }
            let absolute = target.hasPrefix("/")
                ? target
                : (path as NSString).deletingLastPathComponent + "/" + target
            let resolved = (try? SandboxPath.canonical(URL(fileURLWithPath: absolute))) ?? absolute
            guard resolved == base || resolved.hasPrefix(inside) else {
                unlink(path)
                removed += 1
                continue
            }
        }
        return removed
    }

    /// Las órdenes de riesgo que aparecen en un script, o `nil` si no hay ninguna.
    public static func riskyCommands(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1024), !data.isEmpty else { return nil }
        // Los .bat de Windows pueden venir en UTF-16; se prueba antes de caer a Latin-1.
        let text = String(data: data, encoding: .utf8)
            ?? (data.starts(with: [0xFF, 0xFE]) ? String(data: data, encoding: .utf16LittleEndian) : nil)
            ?? String(decoding: data, as: UTF8.self)
        var found: [String] = []
        for pattern in riskyScriptPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { continue }
            let snippet = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(String(snippet.prefix(60)))
        }
        return found.isEmpty ? nil : found.joined(separator: " · ")
    }

    static func architectureLabel(_ architecture: ProgramArchitecture) -> String {
        switch architecture {
        case .bits32: return "x86"
        case .bits64: return "x64"
        case .arm64: return "ARM64"
        case .unknown: return ""
        }
    }

    private static func head(of path: String) -> [UInt8] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        return [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
    }

    private static func isMachO(_ magic: [UInt8]) -> Bool {
        guard magic.count >= 8 else { return false }
        let thin: [[UInt8]] = [[0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE]]
        if thin.contains(where: { magic.starts(with: $0) }) { return true }
        // 0xCAFEBABE es también una clase de Java: un binario universal declara pocas arquitecturas.
        if magic.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) {
            let count = UInt32(magic[4]) << 24 | UInt32(magic[5]) << 16 | UInt32(magic[6]) << 8 | UInt32(magic[7])
            return count > 0 && count < 20
        }
        return false
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func setQuarantine(_ path: String, _ properties: [String: Any]) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try? url.setResourceValues(values)
    }
}
