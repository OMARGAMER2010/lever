import Foundation

/// Versión del motor con la que se exportó el juego.
///
/// Se lee de la cabecera del `.pck`, no del `.exe`: son cuatro enteros en un sitio fijo, mientras
/// que rastrear la cadena "Godot Engine v" obligaría a recorrer cien megas de binario.
public struct GodotVersion: Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Nombre de la publicación en GitHub. Godot omite el parche cuando es cero: la 4.6.0 se
    /// publica como `4.6-stable`, no como `4.6.0-stable`. Equivocarse aquí da un 404.
    public var releaseTag: String { "\(description)-stable" }

    /// Las plantillas de exportación de todas las plataformas vienen en un solo archivo.
    public var templatesURL: URL {
        URL(string: "https://github.com/godotengine/godot/releases/download/"
            + "\(releaseTag)/Godot_v\(releaseTag)_export_templates.tpz")!
    }
}

/// Dónde están los datos del juego.
public enum GodotPackLocation: Equatable, Sendable {
    /// Un `.pck` aparte, al lado del `.exe`. Es lo habitual.
    case sibling(URL)
    /// Pegado al final del propio `.exe`, en las exportaciones de un solo archivo.
    case embedded(URL, offset: UInt64)

    /// Archivo que hay que leer para sacar los datos.
    public var container: URL {
        switch self {
        case .sibling(let url): return url
        case .embedded(let url, _): return url
        }
    }

    /// Byte donde empieza la cabecera `GDPC`.
    public var startOffset: UInt64 {
        switch self {
        case .sibling: return 0
        case .embedded(_, let offset): return offset
        }
    }

    public var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }
}

/// Un complemento nativo que el juego carga en marcha (GDExtension).
///
/// Importa porque es el punto donde suele romperse el paso a Mac: el archivo `.gdextension` casi
/// siempre declara macOS, pero la exportación de Windows solo mete el `.dll`. Sin el `.dylib`
/// equivalente el juego arranca y falla al primer vídeo, sonido o lo que sea que aporte.
public struct GodotExtension: Equatable, Sendable {
    /// Ruta del `.gdextension` dentro del juego.
    public let configPath: String
    /// Nombre de la carpeta del complemento: `gde_gozen`, `godot-jolt`…
    public let addonName: String
    /// Ruta que el juego espera para la librería de macOS, tal cual la pide el `.gdextension`.
    public let macLibraryPath: String?
    /// `true` cuando la librería ya está disponible (venía en la carpeta o la tenemos guardada).
    public var isSatisfied: Bool

    public init(configPath: String, addonName: String, macLibraryPath: String?, isSatisfied: Bool) {
        self.configPath = configPath
        self.addonName = addonName
        self.macLibraryPath = macLibraryPath
        self.isSatisfied = isSatisfied
    }

    /// Nombre del archivo `.dylib`, que es la clave con la que se guarda y se busca.
    public var macLibraryFileName: String? {
        macLibraryPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// El `.gdextension` ni siquiera menciona macOS: no hay nada que copiar, hay que rehacerlo.
    public var declaresMac: Bool { macLibraryPath != nil }
}

/// Retrato de un `.exe` que resultó ser un juego de Godot.
public struct GodotGame: Equatable, Sendable {
    public let executable: URL
    public let version: GodotVersion
    public let pack: GodotPackLocation
    /// Versión del formato del paquete: 1 en Godot 3, 2 en Godot 4.0–4.4, 3 desde la 4.5.
    public let packFormat: Int
    /// `application/config/name` del proyecto, si se pudo leer.
    public let projectName: String?
    /// Ruta interna del icono declarado por el proyecto.
    public let iconPath: String?
    public let extensions: [GodotExtension]

    public init(
        executable: URL,
        version: GodotVersion,
        pack: GodotPackLocation,
        packFormat: Int,
        projectName: String?,
        iconPath: String?,
        extensions: [GodotExtension]
    ) {
        self.executable = executable
        self.version = version
        self.pack = pack
        self.packFormat = packFormat
        self.projectName = projectName
        self.iconPath = iconPath
        self.extensions = extensions
    }

    /// Solo Godot 4 está contemplado. Godot 3 usa otro nombre de plantilla y otra estructura de
    /// bundle; se detecta igual para poder decirlo con claridad en vez de fallar a mitad.
    public var isSupported: Bool { version.major == 4 }

    /// Complementos que se quedarán sin su parte nativa si no se hace nada.
    public var unresolvedExtensions: [GodotExtension] {
        extensions.filter { !$0.isSatisfied }
    }

    /// Nombre del `.app` resultante. Se prefiere el del proyecto porque el del ejecutable suele
    /// ser una sigla (`TC.exe`), y «townscharm» dice bastante más que «TC» en el Escritorio.
    public var suggestedAppName: String {
        if let projectName, projectName.count >= 3 { return projectName }
        let fromExecutable = executable.deletingPathExtension().lastPathComponent
        return fromExecutable.isEmpty ? "Juego" : fromExecutable
    }

    /// El ejecutable del bundle y el `.pck` tienen que llamarse igual: Godot busca
    /// `Contents/Resources/<nombre del ejecutable>.pck` y si no coincide arranca en vacío.
    public var bundleExecutableName: String {
        executable.deletingPathExtension().lastPathComponent
    }
}
