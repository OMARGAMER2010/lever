import Foundation

/// Tipos de archivo que la app sabe tratar.
///
/// Con valor de texto porque se guarda en la lista de recientes entre sesiones: un `enum` sin
/// valor crudo obligaría a inventar una correspondencia aparte que se despistaría al añadir un
/// tipo nuevo.
public enum SupportedFileKind: String, Codable, CaseIterable, Sendable {
    /// Programas de Windows: `.exe` y `.msi`.
    case exe
    /// Comprimidos. `.rar` es el caso principal, pero los extractores abren muchos más.
    case rar
    /// Aplicaciones de Android. Solo `.apk`: un `.aab` o un `.xapk` no se instalan tal cual.
    case apk

    public var extensions: [String] {
        switch self {
        case .exe:
            return ["exe", "msi"]
        case .apk:
            return ["apk"]
        case .rar:
            return [
                "rar", "zip", "7z", "tar", "gz", "tgz", "bz2", "tbz",
                "xz", "txz", "zst", "iso", "cab", "arj", "lzh", "lha",
                "z", "zipx", "dmg", "wim", "001"
            ]
        }
    }

    public func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return extensions.contains(ext)
    }

    /// Descripción corta para mensajes de error.
    public var humanDescription: String {
        switch self {
        case .exe: return "programa de Windows (.exe o .msi)"
        case .rar: return "archivo comprimido (.rar, .zip, .7z…)"
        case .apk: return "aplicación de Android (.apk)"
        }
    }
}

public extension URL {
    /// Formatos que envuelven varios `.apk` dentro. `adb install` no sabe abrirlos y hace falta
    /// `bundletool` u otra herramienta: conviene decirlo con nombre propio en vez de soltar un
    /// «no reconozco este archivo».
    var looksLikeAndroidBundle: Bool {
        ["aab", "apks", "xapk", "apkm"].contains(pathExtension.lowercased())
    }
}

public extension URL {
    /// Nombre del archivo sin extensión, sirviendo de nombre por defecto para la carpeta destino.
    var suggestedFolderName: String {
        var name = deletingPathExtension().lastPathComponent
        // `algo.tar.gz` -> `algo`
        let compound = ["tar"]
        let inner = URL(fileURLWithPath: name).pathExtension.lowercased()
        if compound.contains(inner) {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        // `algo.part1` de un multiparte -> `algo`
        if let range = name.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.isEmpty ? "Extraido" : name
    }

    /// Tamaño en bytes, o `nil` si no se puede leer.
    var fileSizeInBytes: Int64? {
        (try? resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
    }

    /// Tamaño ya formateado ("12,4 MB").
    var formattedFileSize: String? {
        guard let bytes = fileSizeInBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
