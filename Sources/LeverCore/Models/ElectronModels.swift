import Foundation

/// Versión del motor de Electron con la que se repartió el juego.
public struct ElectronVersion: Equatable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// De un «44.0.0» suelto, que es como lo escriben tanto el archivo `version` como la cadena
    /// que queda dentro del ejecutable.
    public init?(_ texto: String) {
        let partes = texto.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard partes.count >= 3, let a = Int(partes[0]), let b = Int(partes[1]),
              let c = Int(partes[2].prefix(while: \.isNumber)) else { return nil }
        self.init(major: a, minor: b, patch: c)
    }

    public static func < (left: ElectronVersion, right: ElectronVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public var releaseTag: String { "v\(description)" }

    /// Electron publica binarios de Apple silicon desde la 11.0.0. Comprobado contra sus propias
    /// publicaciones: la 10.4.7 solo tiene `darwin-x64` y la 11.0.0 ya trae las dos.
    public static let oldestOnAppleSilicon = ElectronVersion(major: 11, minor: 0, patch: 0)

    public func needsRosetta(appleSilicon: Bool) -> Bool {
        appleSilicon && self < Self.oldestOnAppleSilicon
    }

    public func macAssetName(appleSilicon: Bool) -> String {
        let arquitectura = (appleSilicon && self >= Self.oldestOnAppleSilicon) ? "arm64" : "x64"
        return "electron-\(releaseTag)-darwin-\(arquitectura).zip"
    }

    public func macDownloadURL(appleSilicon: Bool) -> URL {
        URL(string: "https://github.com/electron/electron/releases/download/\(releaseTag)/"
            + macAssetName(appleSilicon: appleSilicon))!
    }
}

/// De dónde salió el número de versión, porque no todas las fuentes valen lo mismo.
public enum ElectronVersionOrigin: Equatable, Sendable {
    /// Del archivo `version` que Electron deja en la raíz de su reparto. Es la buena: sobrevive al
    /// empaquetado —comprobado con `electron-packager`— y se lee en un instante.
    case versionFile
    /// De la cadena `Chrome/… Electron/<X.Y.Z>` que queda dentro del ejecutable. Es el respaldo
    /// cuando el reparto no trae el archivo. Obliga a recorrerse el binario entero.
    case embeddedString
}

/// Un módulo nativo de Node que el juego trae compilado para Windows.
///
/// Cada uno es una librería de C++ compilada contra un ABI concreto —el `process.versions.modules`
/// de esa versión de Electron—, así que no basta con que exista para macOS: tiene que existir
/// para macOS **y** para ese ABI.
public struct NodeNativeModule: Equatable, Sendable {
    /// Nombre del paquete, del `package.json` que lo contiene.
    public let name: String
    public let version: String?
    /// Ruta del `.node`, relativa a la carpeta `resources/` del reparto.
    public let relativePath: String
    /// `owner/repo` de GitHub, del `repository` de su `package.json`. Es donde `prebuild-install`
    /// va a buscar los binarios ya compilados, así que sin esto no hay de dónde bajar nada.
    public let repository: String?

    public init(name: String, version: String?, relativePath: String, repository: String?) {
        self.name = name
        self.version = version
        self.relativePath = relativePath
        self.repository = repository
    }

    /// Como se enseña en el panel: «better-sqlite3 12.2.0» o solo el nombre si no se supo.
    public var label: String { version.map { "\(name) \($0)" } ?? name }

    /// Nombre del archivo del prebuild, con la convención de `prebuild-install`:
    /// `<módulo>-v<versión>-<runtime>-v<abi>-<plataforma>-<arquitectura>.tar.gz`.
    ///
    /// El ámbito del paquete no entra en el nombre —`@scope/cosa` publica `cosa-v…`—, que es la
    /// convención de la herramienta; en el proyecto no hay ningún caso con ámbito con el que
    /// haberlo comprobado, así que va anotado.
    public func prebuildAssetName(abi: Int, appleSilicon: Bool) -> String? {
        guard let version else { return nil }
        let corto = name.split(separator: "/").last.map(String.init) ?? name
        return "\(corto)-v\(version)-electron-v\(abi)-darwin-\(appleSilicon ? "arm64" : "x64").tar.gz"
    }

    /// Los prebuilds viven en las publicaciones del propio módulo, bajo la etiqueta `v<versión>`.
    public func prebuildURL(abi: Int, appleSilicon: Bool) -> URL? {
        guard let repository, let version, let archivo = prebuildAssetName(abi: abi, appleSilicon: appleSilicon)
        else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/v\(version)/\(archivo)")
    }
}

/// Retrato de un `.exe` que resultó ser un juego hecho con Electron.
///
/// Electron es Chromium con Node dentro, igual que NW.js, y el juego que corre encima es HTML y
/// JavaScript. La diferencia está en que aquí el código va empaquetado en un `.asar` y en que los
/// juegos de Electron sí suelen traer módulos nativos: ahí está lo que no viaja.
public struct ElectronGame: Equatable, Sendable {
    public let executable: URL
    /// Carpeta que contiene el `.exe`, los binarios del motor y `resources/`.
    public let root: URL
    public let engineVersion: ElectronVersion
    public let versionOrigin: ElectronVersionOrigin
    /// El `app.asar` del juego.
    public let asar: URL
    /// Nombre que el juego se da a sí mismo, del `productName` de su `package.json`.
    public let productName: String?
    /// Lo que hay dentro de `resources/` y viaja al `.app`, sin el `default_app.asar` del motor.
    public let resourceEntries: [String]
    public let gameBytes: Int64
    /// Módulos nativos compilados para Windows.
    public let nativeModules: [NodeNativeModule]
    public let appleSilicon: Bool

    public init(
        executable: URL,
        root: URL,
        engineVersion: ElectronVersion,
        versionOrigin: ElectronVersionOrigin,
        asar: URL,
        productName: String?,
        resourceEntries: [String],
        gameBytes: Int64,
        nativeModules: [NodeNativeModule],
        appleSilicon: Bool
    ) {
        self.executable = executable
        self.root = root
        self.engineVersion = engineVersion
        self.versionOrigin = versionOrigin
        self.asar = asar
        self.productName = productName
        self.resourceEntries = resourceEntries
        self.gameBytes = gameBytes
        self.nativeModules = nativeModules
        self.appleSilicon = appleSilicon
    }

    public var version: String { engineVersion.description }

    /// Siempre: cualquier versión publicada tiene binarios de macOS, aunque las anteriores a la 11
    /// solo sean de Intel y vayan con Rosetta.
    public var isSupported: Bool { true }

    public var needsRosetta: Bool { engineVersion.needsRosetta(appleSilicon: appleSilicon) }

    public var macDownloadURL: URL { engineVersion.macDownloadURL(appleSilicon: appleSilicon) }

    public var windowsModules: [String] { nativeModules.map(\.label) }

    /// El nombre del `.exe` es el que puso quien empaquetó, así que vale; el `productName` del
    /// `package.json` vale más, porque es el que el autor escribió para que se viera.
    public var suggestedAppName: String {
        for candidato in [productName, executable.deletingPathExtension().lastPathComponent] {
            let limpio = Self.saneaNombre(candidato ?? "")
            if !limpio.isEmpty { return limpio }
        }
        return "juego"
    }

    public static func saneaNombre(_ texto: String) -> String {
        texto.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\t"))
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
