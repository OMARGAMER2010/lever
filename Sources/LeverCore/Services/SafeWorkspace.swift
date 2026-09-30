import Darwin
import Foundation

/// De dónde salió un espacio aislado.
public struct SafeWorkspaceOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case archive
        case program
    }

    public let kind: Kind
    /// Ruta del archivo original: el comprimido, o el programa importado.
    public let path: String
    public let createdAt: Date

    public init(kind: Kind, path: String, createdAt: Date = Date()) {
        self.kind = kind
        self.path = path
        self.createdAt = createdAt
    }
}

/// Una carpeta desechable donde vive todo lo que Safe Mode hace con un archivo.
///
/// ```
/// <id>/control   informe, perfiles, origen: el aislamiento no puede ni leerlo
/// <id>/files     lo extraído o importado (la unidad D: de Windows)
/// <id>/windows   el prefijo de Windows de este espacio (la unidad C:)
/// <id>/home      HOME aislado, con Escritorio y Documentos vacíos
/// <id>/tmp       TMPDIR aislado
/// <id>/engine    clon del motor de Wine mientras dura una ejecución
/// ```
public struct SafeWorkspace: Equatable, Hashable, Sendable, Identifiable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var id: String { root.lastPathComponent }
    public var control: URL { root.appendingPathComponent("control", isDirectory: true) }
    public var files: URL { root.appendingPathComponent("files", isDirectory: true) }
    public var windows: URL { root.appendingPathComponent("windows", isDirectory: true) }
    public var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    public var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    public var engine: URL { root.appendingPathComponent("engine", isDirectory: true) }
    public var reportURL: URL { control.appendingPathComponent("report.json") }
    public var originURL: URL { control.appendingPathComponent("origin.json") }

    /// `~/Library/Application Support/Lever/Safe Mode`, junto al resto de lo de Lever pero aparte.
    public static var defaultBase: URL {
        WineLauncher.prefixURL.deletingLastPathComponent()
            .appendingPathComponent("Safe Mode", isDirectory: true)
    }

    // MARK: - Crear y encontrar

    public static func create(
        origin: SafeWorkspaceOrigin,
        base: URL = defaultBase,
        fileManager: FileManager = .default
    ) throws -> SafeWorkspace {
        let workspace = SafeWorkspace(root: base.appendingPathComponent(UUID().uuidString, isDirectory: true))
        // Solo el dueño: ni otros usuarios del Mac ni otros procesos con otro usuario.
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true, attributes: attributes)
        for directory in [workspace.root, workspace.control, workspace.files] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        }
        let data = try JSONEncoder().encode(origin)
        try data.write(to: workspace.originURL, options: .atomic)
        return workspace
    }

    /// Todos los espacios que hay, del más reciente al más antiguo.
    public static func all(base: URL = defaultBase, fileManager: FileManager = .default) -> [SafeWorkspace] {
        let children = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { SafeWorkspace(root: $0) }
            .filter { fileManager.fileExists(atPath: $0.control.path) }
            .sorted { ($0.origin()?.createdAt ?? .distantPast) > ($1.origin()?.createdAt ?? .distantPast) }
    }

    /// El espacio cuya carpeta de archivos contiene esta ruta, si lo hay.
    public static func containing(_ url: URL, base: URL = defaultBase) -> SafeWorkspace? {
        guard let real = try? SandboxPath.canonical(url),
              let baseReal = try? SandboxPath.canonical(base) else { return nil }
        let prefix = baseReal + "/"
        guard real.hasPrefix(prefix) else { return nil }
        let rest = real.dropFirst(prefix.count).split(separator: "/")
        guard rest.count >= 2, UUID(uuidString: String(rest[0])) != nil, rest[1] == "files" else { return nil }
        return SafeWorkspace(root: URL(fileURLWithPath: baseReal).appendingPathComponent(String(rest[0]), isDirectory: true))
    }

    /// El espacio que ya se creó para este programa, para que las partidas guardadas sigan ahí.
    public static func existing(forProgramAt path: String, base: URL = defaultBase, fileManager: FileManager = .default) -> SafeWorkspace? {
        all(base: base, fileManager: fileManager).first { workspace in
            guard let origin = workspace.origin(), origin.kind == .program, origin.path == path else { return false }
            return fileManager.fileExists(atPath: workspace.files.path)
        }
    }

    /// Los espacios que ya salieron de **este mismo comprimido**, del más reciente al más antiguo.
    ///
    /// A diferencia de un programa, aquí no se reutiliza ninguno por su cuenta: extraer otra vez
    /// sobre lo de antes mezclaría contenido viejo con nuevo, y si alguien vuelve a extraer suele
    /// ser porque la primera vez salió mal. Lo que hace falta es **saber que ya están**, que es de
    /// lo que se encarga esta lista: quien decide qué hacer con ellos es quien mira.
    public static func all(forArchiveAt path: String, base: URL = defaultBase, fileManager: FileManager = .default) -> [SafeWorkspace] {
        all(base: base, fileManager: fileManager).filter { workspace in
            guard let origin = workspace.origin(), origin.kind == .archive, origin.path == path else { return false }
            return fileManager.fileExists(atPath: workspace.files.path)
        }
    }

    public func origin() -> SafeWorkspaceOrigin? {
        guard let data = try? Data(contentsOf: originURL) else { return nil }
        return try? JSONDecoder().decode(SafeWorkspaceOrigin.self, from: data)
    }

    // MARK: - Informe

    public func loadReport() -> SafeReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(SafeReport.self, from: data)
    }

    public func save(_ report: SafeReport) throws {
        let data = try JSONEncoder().encode(report)
        try data.write(to: reportURL, options: .atomic)
    }

    // MARK: - Preparar una ejecución

    /// HOME y TMPDIR limpios. Las carpetas personales existen, vacías: un programa que busca sus
    /// Documentos encuentra algo y no falla, pero no son los tuyos.
    public func prepareRunDirectories(fileManager: FileManager = .default) throws {
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        for name in ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"] {
            try fileManager.createDirectory(at: home.appendingPathComponent(name, isDirectory: true),
                                            withIntermediateDirectories: true, attributes: attributes)
        }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: attributes)
    }

    // MARK: - Acceso desde el Escritorio

    public static var defaultDesktop: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Deja en el Escritorio un **enlace** a lo extraído, y devuelve dónde quedó.
    ///
    /// Un enlace, y no una copia ni una mudanza, y no es por comodidad. Sacar lo extraído de la
    /// base rompería tres cosas a la vez: el perfil de `windowsSession` da permisos por `subpath`
    /// de la raíz del espacio, así que Wine no podría leer lo que viviera fuera; `containing(_:)`
    /// —que es lo que hace que un `.exe` de aquí se abra en Safe Mode y no normal— dejaría de
    /// reconocerlo, y un ejecutable de un comprimido dudoso pasaría a abrirse **sin aislar**; y lo
    /// extraído perdería el sitio donde la cuarentena y el `0o644` sin bit de ejecución significan
    /// algo. Un enlace no rompe ninguna: `SandboxPath.canonical` lo resuelve antes de que llegue a
    /// ningún perfil, y por dentro sigue siendo la misma carpeta de siempre.
    @discardableResult
    public func createDesktopShortcut(
        named name: String,
        desktop: URL = defaultDesktop,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        let target = try SandboxPath.canonical(files)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var link = desktop.appendingPathComponent(clean, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: link.path) || Self.isSymbolicLink(link.path, fileManager: fileManager) {
            // Si el que hay ya es el enlace de este mismo espacio, no hace falta otro.
            if Self.isSymbolicLink(link.path, fileManager: fileManager),
               let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
               destination == target {
                return link
            }
            link = desktop.appendingPathComponent("\(clean) \(suffix)", isDirectory: false)
            suffix += 1
            if suffix > 50 { throw SandboxError.unusablePath(link.path) }
        }
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        return link
    }

    /// Quita del Escritorio los enlaces que apuntaban a este espacio. Se llama al borrarlo, para no
    /// dejar un acceso que no lleva a ninguna parte. Solo toca enlaces: nunca un archivo de verdad.
    public static func removeDesktopShortcuts(
        into workspace: SafeWorkspace,
        desktop: URL = defaultDesktop,
        fileManager: FileManager = .default
    ) {
        guard let root = try? SandboxPath.canonical(workspace.root) else { return }
        let children = (try? fileManager.contentsOfDirectory(atPath: desktop.path)) ?? []
        for name in children {
            let path = desktop.path + "/" + name
            guard isSymbolicLink(path, fileManager: fileManager),
                  let destination = try? fileManager.destinationOfSymbolicLink(atPath: path),
                  destination == root || destination.hasPrefix(root + "/") else { continue }
            unlink(path)
        }
    }

    private static func isSymbolicLink(_ path: String, fileManager: FileManager = .default) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Borrar

    /// Borra el espacio entero. Solo si de verdad es un espacio de Safe Mode: una ruta rara o un
    /// enlace nunca pueden llevar este borrado fuera de su carpeta.
    public func delete(base: URL = SafeWorkspace.defaultBase, fileManager: FileManager = .default) throws {
        try Self.removeTree(at: root, confinedTo: base, fileManager: fileManager)
    }

    /// Borra una carpeta de dentro de la base de Safe Mode aunque lo extraído venga con permisos
    /// que lo impidan (una carpeta sin escritura, un archivo inmutable). No sigue enlaces.
    public static func removeTree(at url: URL, confinedTo base: URL, fileManager: FileManager = .default) throws {
        let real = try SandboxPath.canonical(url)
        let baseReal = try SandboxPath.canonical(base)
        guard real.hasPrefix(baseReal + "/"), real != baseReal else {
            throw SandboxError.unusablePath(real)
        }
        guard fileManager.fileExists(atPath: real) else { return }
        makeRemovable(real)
        try fileManager.removeItem(atPath: real)
    }

    /// Recorre sin seguir enlaces y deja cada carpeta con permiso para vaciarla.
    private static func makeRemovable(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        _ = lchflags(path, 0)
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return }
        _ = chmod(path, 0o700)
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for child in children {
            makeRemovable(path + "/" + child)
        }
    }

    /// Lo que ocupa en disco. Recorre todo, así que va fuera del hilo principal.
    public func allocatedBytes(fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
