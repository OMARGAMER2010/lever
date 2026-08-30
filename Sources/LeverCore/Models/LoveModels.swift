import Foundation

/// Versión del motor LÖVE con la que se distribuyó el juego.
///
/// Sale del recurso de versión de `love.dll`, no del `.exe`: las herramientas que empaquetan
/// juegos de LÖVE (makelove, love-release) reescriben el icono y la versión del ejecutable con
/// los del juego, y entonces el `.exe` miente. A la DLL no la toca nadie.
public struct LoveVersion: Equatable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (left: LoveVersion, right: LoveVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }

    public var description: String { releaseTag }

    /// Nombre de la publicación en GitHub. LÖVE numeró la serie 0.x con tres cifras
    /// (`0.10.2`) y la 11 con dos (`11.5`, nunca `11.5.0`): usar la forma equivocada da un 404.
    public var releaseTag: String {
        major >= 11 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Nombre del archivo de macOS dentro de esa publicación.
    ///
    /// Tres convenciones distintas, comprobadas en las diecisiete publicaciones que existen:
    /// `macosx-ub` hasta la 0.8 (binarios de 32 bits), `macosx-x64` de la 0.9 a la 0.10.2, y
    /// `macos` de la 11 en adelante. La 11.0 es la única que nombra el archivo con tres cifras
    /// aunque su etiqueta lleve dos.
    public var macAssetName: String {
        if major >= 11 {
            return minor == 0
                ? "love-\(major).0.0-macos.zip"
                : "love-\(releaseTag)-macos.zip"
        }
        return "love-\(releaseTag)-macosx-x64.zip"
    }

    public var macDownloadURL: URL {
        URL(string: "https://github.com/love2d/love/releases/download/\(releaseTag)/\(macAssetName)")!
    }

    /// Los binarios de macOS anteriores a la 0.9 son universales de PowerPC e Intel de 32 bits, y
    /// macOS dejó de ejecutar 32 bits en Catalina. Del 0.9 en adelante sí arrancan: la 0.10.2 se
    /// probó en macOS 15 y corre bajo Rosetta.
    public var isSupported: Bool { self >= LoveVersion(major: 0, minor: 9, patch: 0) }

    /// LÖVE añadió binarios nativos de arm64 en la 11.4. Todo lo anterior es solo Intel.
    public var needsRosetta: Bool { self < LoveVersion(major: 11, minor: 4, patch: 0) }
}

/// Dónde están los datos del juego.
public enum LovePayload: Equatable, Sendable {
    /// Pegado al final del `.exe`. Es lo que hace la receta oficial de Windows:
    /// `copy /b love.exe+juego.love juego.exe`.
    case fused(URL, offset: UInt64)
    /// Un `.love` suelto al lado del `.exe`, para quien no fusiona.
    case sibling(URL)
}

/// Retrato de un `.exe` que resultó ser un juego hecho con LÖVE.
///
/// El `.love` es un ZIP con Lua y recursos dentro: no sabe en qué sistema corre. El motor de
/// macOS lo encuentra solo, sin argumentos ni configuración —`getLoveInResources()` pide al
/// bundle *cualquier* archivo con extensión `.love` dentro de `Contents/Resources/` y lo arranca
/// en modo fusionado—, así que el traslado es juntar las dos mitades y poco más.
public struct LoveGame: Equatable, Sendable {
    public let executable: URL
    /// Carpeta que contiene el `.exe` y las DLL.
    public let root: URL
    public let engineVersion: LoveVersion
    public let payload: LovePayload
    /// Tamaño exacto del `.love`. Se sabe sin extraerlo y sirve para calcular el sitio que hace
    /// falta en disco sin inventarse una cifra.
    public let payloadBytes: Int64
    /// DLL de la carpeta que no son del motor: son módulos de Lua compilados que el juego carga
    /// con `require`, y no existe ninguna versión de macOS que descargar.
    public let windowsLibraries: [String]

    public init(
        executable: URL,
        root: URL,
        engineVersion: LoveVersion,
        payload: LovePayload,
        payloadBytes: Int64,
        windowsLibraries: [String]
    ) {
        self.executable = executable
        self.root = root
        self.engineVersion = engineVersion
        self.payload = payload
        self.payloadBytes = payloadBytes
        self.windowsLibraries = windowsLibraries
    }

    public var version: String { engineVersion.releaseTag }

    public var isSupported: Bool { engineVersion.isSupported }

    public var needsRosetta: Bool { engineVersion.needsRosetta }

    /// El `.app` lleva el nombre del `.exe`, que es el que eligió el desarrollador.
    ///
    /// Salvo cuando no lo eligió: en el reparto sin fusionar el ejecutable es el `love.exe` tal
    /// cual sale del motor, y quedaría una app llamada «love». Ahí el nombre bueno es el del
    /// `.love`, que ese sí lo puso alguien.
    public var bundleExecutableName: String {
        let fromExecutable = executable.deletingPathExtension().lastPathComponent
        if case .sibling(let file) = payload, ["love", "lovec"].contains(fromExecutable.lowercased()) {
            let fromPayload = file.deletingPathExtension().lastPathComponent
            if !fromPayload.isEmpty { return fromPayload }
        }
        return fromExecutable.isEmpty ? "juego" : fromExecutable
    }

    public var suggestedAppName: String { bundleExecutableName }
}
