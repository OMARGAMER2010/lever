import Foundation

/// Un archivo que ya se abrió alguna vez, para no tener que volver a arrastrarlo.
public struct RecentFile: Identifiable, Equatable, Sendable, Codable {
    public let path: String
    public let kind: SupportedFileKind
    public let lastOpened: Date

    /// El archivo ya no está donde estaba: lo movieron o lo borraron desde fuera de la app.
    ///
    /// No se guarda: se comprueba al leer la lista. Guardarlo sería recordar algo que puede haber
    /// dejado de ser cierto entre dos sesiones, y una lista que ofrece abrir lo que ya no existe
    /// es peor que no tener lista.
    public var isMissing = false

    private enum CodingKeys: String, CodingKey {
        case path, kind, lastOpened
    }

    public init(path: String, kind: SupportedFileKind, lastOpened: Date, isMissing: Bool = false) {
        self.path = path
        self.kind = kind
        self.lastOpened = lastOpened
        self.isMissing = isMissing
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }

    /// La carpeta donde vive, con `~` en vez de la ruta completa de la casa.
    public var folder: String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Por qué no se pudo renombrar o mover. Se devuelve el motivo, no un texto: quien lo enseña es
/// quien sabe en qué idioma está hablando.
public enum RecentFileError: Error, Equatable, Sendable {
    case emptyName
    case alreadyExists(String)
    case failed(String)
}

/// La lista de archivos abiertos hace poco, y las operaciones sobre ellos.
///
/// Renombrar y mover tocan el archivo **de verdad**, no una etiqueta de la lista. Un apodo que no
/// se correspondiera con el disco haría que la lista mintiera sobre lo que hay, y al abrirlo
/// aparecería otro nombre.
@MainActor
public enum RecentFiles {
    private static let defaults = UserDefaults.standard
    private static let key = "recentFiles"
    /// Por tipo, no en total: si no, abrir diez comprimidos seguidos borraría los programas.
    private static let limitPerKind = 12

    // MARK: - Lectura y escritura

    public static func load(fileManager: FileManager = .default) -> [RecentFile] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([RecentFile].self, from: data) else { return [] }

        return stored.map { file in
            var checked = file
            checked.isMissing = !fileManager.fileExists(atPath: file.path)
            return checked
        }
    }

    /// Apunta un archivo recién abierto. Si ya estaba, sube al principio en vez de duplicarse.
    public static func remember(_ url: URL, kind: SupportedFileKind, now: Date = Date()) {
        var files = load().filter { $0.path != url.path }
        files.insert(RecentFile(path: url.path, kind: kind, lastOpened: now), at: 0)
        save(files)
    }

    public static func forget(_ file: RecentFile) {
        save(load().filter { $0.path != file.path })
    }

    public static func clear(kind: SupportedFileKind) {
        save(load().filter { $0.kind != kind })
    }

    /// Los de un tipo, del más reciente al más antiguo.
    public static func files(of kind: SupportedFileKind, in files: [RecentFile]) -> [RecentFile] {
        files.filter { $0.kind == kind }.sorted { $0.lastOpened > $1.lastOpened }
    }

    // MARK: - Operaciones sobre el archivo

    /// Cambia el nombre conservando la extensión.
    ///
    /// La extensión se conserva a propósito: es lo que decide si la app reconoce el archivo, y
    /// renombrar `juego.apk` a `juego.zip` desde aquí solo serviría para que dejara de aparecer.
    /// Para eso está el Finder.
    @discardableResult
    public static func rename(
        _ file: RecentFile,
        to newName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RecentFileError.emptyName }

        let extension_ = file.url.pathExtension
        var base = trimmed
        // Si ya escribió la extensión, no se pone dos veces.
        if !extension_.isEmpty, base.lowercased().hasSuffix(".\(extension_.lowercased())") {
            base = String(base.dropLast(extension_.count + 1))
        }
        guard !base.isEmpty else { throw RecentFileError.emptyName }

        let destination = file.url
            .deletingLastPathComponent()
            .appendingPathComponent(extension_.isEmpty ? base : "\(base).\(extension_)")

        return try relocate(file, to: destination, fileManager: fileManager)
    }

    /// Mueve el archivo a otra carpeta, con el mismo nombre.
    @discardableResult
    public static func move(
        _ file: RecentFile,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try relocate(
            file,
            to: directory.appendingPathComponent(file.name),
            fileManager: fileManager
        )
    }

    /// El paso común de renombrar y mover: comprobar, mover y actualizar la lista.
    private static func relocate(
        _ file: RecentFile,
        to destination: URL,
        fileManager: FileManager
    ) throws -> URL {
        // Mismo sitio: no es un error, simplemente no hay nada que hacer.
        guard destination.standardizedFileURL != file.url.standardizedFileURL else { return file.url }

        guard fileManager.fileExists(atPath: file.path) else {
            throw RecentFileError.failed(file.name)
        }
        // Nunca se pisa un archivo del usuario, ni siquiera el suyo propio.
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RecentFileError.alreadyExists(destination.lastPathComponent)
        }

        do {
            try fileManager.moveItem(at: file.url, to: destination)
        } catch {
            throw RecentFileError.failed(error.localizedDescription)
        }

        // La entrada se identifica por la ruta, así que hay que rehacerla, no editarla.
        var files = load().filter { $0.path != file.path }
        files.insert(
            RecentFile(path: destination.path, kind: file.kind, lastOpened: file.lastOpened),
            at: 0
        )
        save(files)

        return destination
    }

    private static func save(_ files: [RecentFile]) {
        // Se recorta por tipo conservando el orden en que llegaron.
        var kept: [RecentFile] = []
        for kind in SupportedFileKind.allCases {
            kept += files
                .filter { $0.kind == kind }
                .sorted { $0.lastOpened > $1.lastOpened }
                .prefix(limitPerKind)
        }

        guard let data = try? JSONEncoder().encode(kept.sorted { $0.lastOpened > $1.lastOpened }) else { return }
        defaults.set(data, forKey: key)
    }
}
