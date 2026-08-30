import Foundation

/// Versión de NW.js con la que se repartió el juego.
///
/// Sale del recurso de versión de `nw.dll`. El `.exe` también lo lleva, pero RPG Maker lo renombra
/// a `Game.exe` y hay herramientas que de paso le reescriben el icono y la versión con los del
/// juego; a la DLL no la toca nadie.
public struct NwjsVersion: Equatable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (left: NwjsVersion, right: NwjsVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// NW.js publica cada versión en su propia carpeta, con `v` delante.
    public var releaseTag: String { "v\(description)" }

    /// La versión más antigua que dibuja algo en macOS 15.
    ///
    /// No es una suposición: se probaron la 0.29.4, 0.31.5, 0.35.5, 0.38.2, 0.42.6, 0.43.6, 0.46.4
    /// y 0.47.3, y en todas el proceso del navegador arranca y abre ventana pero el que dibuja
    /// muere antes de cargar la página —ni siquiera se pide una imagen del HTML—. La 0.48.4 va
    /// entera: lee sus datos con XHR desde `file://`, guarda con `fs`, arranca WebGL y pinta.
    public static let oldestThatRuns = NwjsVersion(major: 0, minor: 48, patch: 0)

    /// NW.js empezó a publicar binarios de Apple silicon en la 0.77.0. Antes, solo Intel.
    public static let oldestOnAppleSilicon = NwjsVersion(major: 0, minor: 77, patch: 0)

    public var isSupported: Bool { self >= Self.oldestThatRuns }

    public func macAssetName(appleSilicon: Bool) -> String {
        let architecture = (appleSilicon && self >= Self.oldestOnAppleSilicon) ? "arm64" : "x64"
        return "nwjs-\(releaseTag)-osx-\(architecture).zip"
    }

    public func macDownloadURL(appleSilicon: Bool) -> URL {
        URL(string: "https://dl.nwjs.io/\(releaseTag)/\(macAssetName(appleSilicon: appleSilicon))")!
    }

    /// En un Mac de Apple silicon, una versión sin binarios propios irá traducida por Rosetta.
    public func needsRosetta(appleSilicon: Bool) -> Bool {
        appleSilicon && self < Self.oldestOnAppleSilicon
    }
}

/// Lo que el `package.json` de un juego de NW.js dice de sí mismo.
///
/// Es el manifiesto que lee el propio motor: sin él NW.js no sabe qué abrir. RPG Maker MZ lo deja
/// en la raíz apuntando a `index.html`; RPG Maker MV, apuntando a `www/index.html`.
public struct NwjsManifest: Equatable, Sendable {
    /// Página por la que arranca el juego.
    public let main: String
    /// Nombre interno del paquete, que NW.js usa para su carpeta de datos.
    public let name: String?
    /// Título de la ventana. En RPG Maker es el nombre del juego tal como lo escribió su autor.
    public let title: String?
    /// Ruta del icono de ventana dentro del propio juego.
    public let icon: String?

    public init(main: String, name: String?, title: String?, icon: String?) {
        self.main = main
        self.name = name
        self.title = title
        self.icon = icon
    }
}

/// Retrato de un `.exe` que resultó ser un juego hecho con NW.js.
///
/// NW.js es Chromium con Node dentro: el juego es HTML, JavaScript y recursos, y nada de eso sabe
/// en qué sistema corre. Lo único de Windows son los binarios del motor, y NW.js publica los de
/// macOS por su cuenta. El traslado es cambiar una mitad por la otra.
public struct NwjsGame: Equatable, Sendable {
    public let executable: URL
    /// Carpeta que contiene el `.exe`, los binarios del motor y el juego.
    public let root: URL
    public let engineVersion: NwjsVersion
    public let manifest: NwjsManifest
    /// Archivos y carpetas del juego, sin los del motor. Son los que viajan al `.app`.
    public let gameEntries: [String]
    /// Lo que ocupa el juego, para saber si cabe.
    public let gameBytes: Int64
    /// Módulos nativos que el juego trae compilados para Windows: `.node` de Node y `.dll` que no
    /// son del motor. No hay versión de macOS que descargar.
    public let windowsModules: [String]
    /// `true` si este Mac es de Apple silicon. Decide qué binario de NW.js se descarga.
    public let appleSilicon: Bool

    public init(
        executable: URL,
        root: URL,
        engineVersion: NwjsVersion,
        manifest: NwjsManifest,
        gameEntries: [String],
        gameBytes: Int64,
        windowsModules: [String],
        appleSilicon: Bool
    ) {
        self.executable = executable
        self.root = root
        self.engineVersion = engineVersion
        self.manifest = manifest
        self.gameEntries = gameEntries
        self.gameBytes = gameBytes
        self.windowsModules = windowsModules
        self.appleSilicon = appleSilicon
    }

    public var version: String { engineVersion.description }

    public var isSupported: Bool { engineVersion.isSupported }

    public var needsRosetta: Bool { engineVersion.needsRosetta(appleSilicon: appleSilicon) }

    public var macDownloadURL: URL { engineVersion.macDownloadURL(appleSilicon: appleSilicon) }

    /// RPG Maker llama `Game.exe` a todos sus juegos, así que el nombre del ejecutable no sirve.
    /// El bueno es el título de la ventana, que es el que escribió el autor.
    public var bundleExecutableName: String {
        let candidatos = [manifest.title, manifest.name, executable.deletingPathExtension().lastPathComponent]
        for candidato in candidatos {
            let limpio = Self.sanearNombre(candidato ?? "")
            if !limpio.isEmpty { return limpio }
        }
        return "juego"
    }

    public var suggestedAppName: String { bundleExecutableName }

    /// Un título de ventana puede traer cualquier cosa; un nombre de archivo, no.
    public static func sanearNombre(_ texto: String) -> String {
        let prohibidos = CharacterSet(charactersIn: "/\\:*?\"<>|\n\t")
        return texto.components(separatedBy: prohibidos).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
