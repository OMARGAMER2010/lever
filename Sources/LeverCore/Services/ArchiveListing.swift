import Foundation

/// Una entrada de un comprimido, leída de su índice sin extraer nada.
public struct ArchiveEntry: Equatable, Sendable {
    public let path: String
    public let size: Int64?
    public let packedSize: Int64?
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isHardLink: Bool
    public let linkTarget: String?
    public let isEncrypted: Bool
    public let hasSetIDBit: Bool
    /// Dispositivos, tuberías o sockets: un comprimido de programas no los necesita nunca.
    public let isSpecialFile: Bool

    public init(
        path: String,
        size: Int64? = nil,
        packedSize: Int64? = nil,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        isHardLink: Bool = false,
        linkTarget: String? = nil,
        isEncrypted: Bool = false,
        hasSetIDBit: Bool = false,
        isSpecialFile: Bool = false
    ) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isHardLink = isHardLink
        self.linkTarget = linkTarget
        self.isEncrypted = isEncrypted
        self.hasSetIDBit = hasSetIDBit
        self.isSpecialFile = isSpecialFile
    }
}

/// El formato que dice el **contenido** del archivo.
public enum ArchiveFormat: String, Equatable, Sendable {
    case zip, rar, sevenZip, gzip, bzip2, xz, zstd, tar, cab, iso, dmg, unknown

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7Z"
        case .gzip: return "GZIP"
        case .bzip2: return "BZIP2"
        case .xz: return "XZ"
        case .zstd: return "ZSTD"
        case .tar: return "TAR"
        case .cab: return "CAB"
        case .iso: return "ISO"
        case .dmg: return "DMG"
        case .unknown: return "?"
        }
    }
}

/// Reconoce el formato por sus primeros bytes.
///
/// La extensión la pone quien sube el archivo; los bytes, no. Un `.rar` que por dentro es un ZIP
/// no tiene por qué ser malicioso, pero es justo el tipo de disfraz que conviene decir en voz alta,
/// y además decide qué herramienta lo abre: `unar` no sabe leer un ZIP con Zstd.
public enum ArchiveSignature {
    public static func detect(_ url: URL) -> ArchiveFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), !head.isEmpty else { return .unknown }
        let bytes = [UInt8](head)

        func starts(_ magic: [UInt8]) -> Bool { bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic }

        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts([0x42, 0x5A, 0x68]) { return .bzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if starts([0x4D, 0x53, 0x43, 0x46]) { return .cab }

        // tar lleva «ustar» en el byte 257; ISO, «CD001» en el 32769; DMG, «koly» 512 bytes antes
        // del final.
        if let block = read(handle, at: 257, count: 5), block == Data("ustar".utf8) { return .tar }
        if let block = read(handle, at: 32_769, count: 5), block == Data("CD001".utf8) { return .iso }
        if let end = try? handle.seekToEnd(), end >= 512,
           let block = read(handle, at: end - 512, count: 4), block == Data("koly".utf8) {
            return .dmg
        }
        return .unknown
    }

    /// Lo que promete la extensión, o `nil` si no promete nada concreto (un volumen `.001`, `.z01`).
    public static func expectedFormat(for url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .gzip }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz") { return .bzip2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .xz }
        switch url.pathExtension.lowercased() {
        case "zip", "zipx": return .zip
        case "rar": return .rar
        case "7z": return .sevenZip
        case "gz": return .gzip
        case "bz2": return .bzip2
        case "xz": return .xz
        case "zst": return .zstd
        case "tar": return .tar
        case "cab": return .cab
        case "iso": return .iso
        case "dmg": return .dmg
        default: return nil
        }
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }
}

/// Convierte la salida de los listadores en entradas.
public enum ArchiveListingParser {
    /// `7zz l -slt -ba`: bloques de «Clave = valor» separados por una línea vacía.
    ///
    /// Los enlaces salen de dos formas según el formato: en un ZIP de Unix, en los permisos
    /// (`Attributes = A_ lrwxrwxrwx`); en un tar, en `Symbolic Link` y `Hard Link`.
    public static func parseSevenZip(_ output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]

        func flush() {
            defer { fields.removeAll() }
            guard let path = fields["Path"], !path.isEmpty else { return }
            let attributes = fields["Attributes"] ?? ""
            let mode = unixModeString(in: attributes)
            let symlinkTarget = fields["Symbolic Link"].flatMap { $0.isEmpty ? nil : $0 }
            let hardTarget = fields["Hard Link"].flatMap { $0.isEmpty ? nil : $0 }
            let isDirectory = fields["Folder"] == "+" || mode?.first == "d"
            entries.append(ArchiveEntry(
                path: path,
                size: fields["Size"].flatMap { Int64($0) },
                packedSize: fields["Packed Size"].flatMap { Int64($0) },
                isDirectory: isDirectory,
                isSymbolicLink: symlinkTarget != nil || mode?.first == "l",
                isHardLink: hardTarget != nil,
                linkTarget: symlinkTarget ?? hardTarget,
                isEncrypted: fields["Encrypted"] == "+",
                hasSetIDBit: mode.map { hasSetID($0) } ?? false,
                isSpecialFile: mode.map { ["c", "b", "p", "s"].contains($0.first ?? "-") } ?? false
            ))
        }

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            guard let separator = line.range(of: " = ") else {
                if line.hasSuffix(" =") { fields[String(line.dropLast(2))] = "" }
                continue
            }
            let key = String(line[..<separator.lowerBound])
            // Una clave repetida empieza entrada nueva aunque falte la línea vacía.
            if key == "Path", fields["Path"] != nil { flush() }
            fields[key] = String(line[separator.upperBound...])
        }
        flush()
        return entries
    }

    /// `lsar -json`, para los formatos que `7zz` no sabe listar.
    public static func parseLsar(_ data: Data) -> [ArchiveEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = root["lsarContents"] as? [[String: Any]] else { return nil }
        return contents.compactMap { item in
            guard let name = item["XADFileName"] as? String else { return nil }
            let permissions = (item["XADPosixPermissions"] as? NSNumber)?.intValue ?? 0
            let isLink = (item["XADIsLink"] as? NSNumber)?.boolValue ?? false
            let isHardLink = (item["XADIsHardLink"] as? NSNumber)?.boolValue ?? false
            let fileType = permissions & 0o170000
            return ArchiveEntry(
                path: name,
                size: (item["XADFileSize"] as? NSNumber)?.int64Value,
                packedSize: (item["XADCompressedSize"] as? NSNumber)?.int64Value,
                isDirectory: (item["XADIsDirectory"] as? NSNumber)?.boolValue ?? false,
                isSymbolicLink: isLink && !isHardLink,
                isHardLink: isHardLink,
                linkTarget: item["XADLinkDestination"] as? String,
                isEncrypted: (item["XADIsEncrypted"] as? NSNumber)?.boolValue ?? false,
                hasSetIDBit: permissions & 0o6000 != 0,
                isSpecialFile: [0o020000, 0o060000, 0o010000, 0o140000].contains(fileType)
            )
        }
    }

    /// `A_ -rwsr-xr-x` → `-rwsr-xr-x`.
    private static func unixModeString(in attributes: String) -> String? {
        attributes.split(separator: " ").map(String.init).first { part in
            part.count == 10 && "-dlcbps".contains(part.first ?? "?")
        }
    }

    private static func hasSetID(_ mode: String) -> Bool {
        let chars = Array(mode)
        guard chars.count == 10 else { return false }
        return "sS".contains(chars[3]) || "sS".contains(chars[6])
    }
}
