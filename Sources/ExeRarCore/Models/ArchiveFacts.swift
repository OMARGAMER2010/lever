import Foundation

/// Lo que la app ha averiguado sobre un comprimido concreto. Solo hechos observados:
/// nada que no se haya leído del archivo o de la respuesta de la herramienta.
public struct ArchiveFacts: Equatable, Sendable {
    public let entryNames: [String]
    /// Se pone cuando el listado falló aunque el archivo sí se puede leer: la causa más
    /// frecuente es que pida contraseña.
    public let listingFailed: Bool

    public init(entryNames: [String] = [], listingFailed: Bool = false) {
        self.entryNames = entryNames
        self.listingFailed = listingFailed
    }

    public var isEmpty: Bool { entryNames.isEmpty && !listingFailed }
    public var entryCount: Int { entryNames.count }
}

public extension URL {
    /// `juego.part1.rar`, `juego.r01` y compañía son trozos de un mismo comprimido.
    /// Si falta alguno la extracción fallará, así que conviene avisar antes.
    var looksLikeArchivePart: Bool {
        let name = lastPathComponent.lowercased()
        if name.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"\.z\d{2}$"#, options: .regularExpression) != nil { return true }
        if name.hasSuffix(".001") { return true }
        return false
    }

    /// Formato en mayúsculas para enseñarlo tal cual: RAR, ZIP, 7Z…
    var archiveFormatName: String {
        pathExtension.uppercased()
    }
}
