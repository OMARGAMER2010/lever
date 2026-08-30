import Foundation

/// Una parte nativa que el juego trae compilada para Windows y hay que conseguir para macOS.
///
/// Es lo que tienen en común los tres casos del proyecto —los binarios de LWJGL, los `.node` de
/// Electron y las GDExtension de Godot—: un nombre, una versión, una plataforma y, cuando la parte
/// va atada a un ABI, también el ABI. Esas cuatro señas son su identidad y por tanto la clave de la
/// caché: dos partes con la misma identidad son intercambiables, y con distinta, no. Confundir un
/// binario de un ABI con el de otro es el fallo que más caro sale, porque no da error al montar.
public struct NativePart: Equatable, Sendable {
    public let name: String
    public let version: String
    /// `macos-arm64`, `macos-x64`… Lo que distingue un binario de otro dentro de la misma versión.
    public let platform: String
    /// ABI de Node contra el que se compiló. `nil` para las partes que no dependen de ninguno,
    /// como las de LWJGL.
    public let abi: Int?
    /// De dónde bajarla. `nil` cuando no se conoce ningún sitio: entonces solo cabe nombrarla.
    public let download: URL?
    /// Con qué nombre se guarda el archivo.
    public let fileName: String

    public init(name: String, version: String, platform: String, abi: Int?, download: URL?, fileName: String) {
        self.name = name
        self.version = version
        self.platform = platform
        self.abi = abi
        self.download = download
        self.fileName = fileName
    }

    /// Cómo se enseña: «better-sqlite3 12.11.1».
    public var label: String { "\(name) \(version)" }

    /// Nombre de la carpeta en la caché, con las cuatro señas dentro.
    public var cacheKey: String {
        let base = "\(name)-\(version)-\(platform)".replacingOccurrences(of: "/", with: "-")
        return abi.map { "\(base)-abi\($0)" } ?? base
    }
}

/// Cómo acabó el intento de conseguir una parte, para poder decirlo sin adornos.
public enum NativePartOutcome: Equatable, Sendable {
    /// Ya estaba guardada de otro traslado.
    case cached(URL)
    /// Se acaba de bajar.
    case downloaded(URL)
    /// No hay ningún sitio conocido de donde sacarla.
    case noSourceKnown
    /// Se sabía de dónde, pero no estaba: el módulo no publica esa combinación.
    case notPublished

    public var file: URL? {
        switch self {
        case .cached(let url), .downloaded(let url): return url
        case .noSourceKnown, .notPublished: return nil
        }
    }
}

/// Consigue las partes nativas de macOS, con las estrategias del plan y en su orden.
///
/// Antes esto vivía dentro de `JavaPorter`, atado a LWJGL. Está fuera porque los tres motores que
/// tienen partes nativas hacen lo mismo: mirar si ya se bajó, bajarla si se sabe de dónde, y si no,
/// decir cuál falta. Lo único que cambia entre ellos es cómo se arma la dirección, y eso se queda
/// con cada motor, que es quien conoce su ecosistema.
public enum NativeParts {
    public static func obtain(
        _ part: NativePart,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary,
        fileManager: FileManager = .default,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> NativePartOutcome {
        let carpeta = library.nativePartURL(key: part.cacheKey)
        let archivo = carpeta.appendingPathComponent(part.fileName)
        if fileManager.fileExists(atPath: archivo.path) { return .cached(archivo) }
        guard let direccion = part.download else { return .noSourceKnown }

        try? fileManager.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let descarga = try await runner.run(
            PortCommands.download(direccion, into: archivo), session: session, onLine: onLine
        )
        if session.isCancelled { throw PortFailure.cancelled }
        guard descarga.succeeded else {
            // Un 404 aquí no es un fallo del traslado: quiere decir que ese módulo no publica esta
            // combinación de plataforma y ABI, que es de lo más normal.
            try? fileManager.removeItem(at: archivo)
            return .notPublished
        }
        return .downloaded(archivo)
    }
}

/// El ABI de módulos nativos de Node, que es lo que decide si un `.node` sirve o no.
///
/// Un binario compilado para un ABI no carga en otro, y el ABI no se elige: viene dado por la
/// versión de Node que lleva dentro cada Electron. Se saca del registro de `node-abi`, que es el
/// mismo que usa `prebuild-install` para decidir qué prebuild bajar, así que por construcción
/// coincide con lo que los módulos publican.
public enum NodeAbi {
    /// Pesa menos de ocho kilobytes: no compensa tenerlo escrito a mano y que envejezca.
    public static let registryURL =
        URL(string: "https://raw.githubusercontent.com/electron/node-abi/main/abi_registry.json")!

    /// El registro tiene una entrada por versión mayor, con la primera alfa como etiqueta. El ABI
    /// depende solo del mayor: comprobado contra el índice de publicaciones de Electron y contra lo
    /// que la propia app trasladada imprime al arrancar.
    public static func forElectron(major: Int, registry: Data) -> Int? {
        guard let filas = try? JSONSerialization.jsonObject(with: registry) as? [[String: Any]]
        else { return nil }
        for fila in filas {
            guard (fila["runtime"] as? String) == "electron",
                  let objetivo = fila["target"] as? String,
                  let mayor = Int(objetivo.split(separator: ".").first ?? ""), mayor == major,
                  let abi = fila["abi"] as? String else { continue }
            return Int(abi)
        }
        return nil
    }
}
