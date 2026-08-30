import Foundation

/// Retrato de un `.exe` que resultó ser un juego hecho con Ren'Py.
///
/// Ren'Py es un intérprete de Python: el juego son guiones compilados y archivos `.rpa`, y nada
/// de eso sabe en qué sistema corre. Lo único atado a Windows es la carpeta `lib/py3-windows-*`,
/// que se sustituye por la de macOS del SDK de la **misma versión** —el intérprete compilado y el
/// código Python de `renpy/` van emparejados y no se mezclan entre versiones.
public struct RenpyGame: Equatable, Sendable {
    public let executable: URL
    /// Carpeta que contiene `game/`, `renpy/` y `lib/`.
    public let root: URL
    /// Versión completa tal como la declara el juego: `8.6.0.25112108`.
    public let fullVersion: String
    /// Nombre de la carpeta con la biblioteca de Python compartida: `python3.12`.
    public let pythonLibraryName: String?
    /// `true` si el propio juego ya trae los binarios de macOS —pasa con los paquetes «market»
    /// y «steam», que incluyen las tres plataformas. Entonces no hay nada que descargar.
    public let carriesMacRuntime: Bool
    /// Ruta interna de la imagen que Ren'Py usa como icono de ventana, si existe.
    public let iconRelativePath: String?

    public init(
        executable: URL,
        root: URL,
        fullVersion: String,
        pythonLibraryName: String?,
        carriesMacRuntime: Bool,
        iconRelativePath: String?
    ) {
        self.executable = executable
        self.root = root
        self.fullVersion = fullVersion
        self.pythonLibraryName = pythonLibraryName
        self.carriesMacRuntime = carriesMacRuntime
        self.iconRelativePath = iconRelativePath
    }

    /// Los tres primeros números: es lo que nombra la descarga del SDK. El cuarto es la fecha de
    /// compilación y no aparece en la dirección.
    public var sdkVersion: String {
        fullVersion.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// Versión legible para la interfaz.
    public var version: String { sdkVersion }

    public var majorVersion: Int {
        Int(fullVersion.split(separator: ".").first ?? "") ?? 0
    }

    /// Ren'Py publica cada versión en su propia carpeta.
    public var sdkURL: URL {
        URL(string: "https://www.renpy.org/dl/\(sdkVersion)/renpy-\(sdkVersion)-sdk.zip")!
    }

    /// Ren'Py 6 es de 2015 y sus binarios de macOS son de 32 bits: no arrancan en macOS actual.
    /// La 7 (Python 2) y la 8 (Python 3) sí, aunque la 7 solo trae x86_64 y necesita Rosetta.
    public var isSupported: Bool { majorVersion >= 7 }

    /// El `.app` y su ejecutable llevan el nombre del `.exe`, igual que hace Ren'Py al exportar.
    public var bundleExecutableName: String {
        let name = executable.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "game" : name
    }

    public var suggestedAppName: String { bundleExecutableName }

    /// Ren'Py 7 solo tiene binarios de Intel: correrá bajo Rosetta.
    public var needsRosetta: Bool { majorVersion == 7 }
}
