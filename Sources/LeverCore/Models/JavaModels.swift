import Foundation

/// Versión de Java que pide un juego.
///
/// Solo cuenta el número mayor —8, 11, 17, 21—: es lo que nombra la descarga de Temurin y lo que
/// decide si la máquina virtual sabe leer el bytecode. El resto del número no cambia nada.
public struct JavaFeature: Equatable, Sendable, Comparable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) { self.number = number }

    public static func < (left: JavaFeature, right: JavaFeature) -> Bool { left.number < right.number }

    public var description: String { String(number) }

    /// El número mayor del formato de clase menos 44. No es una convención de nadie: es la tabla
    /// del propio JVM. Java 8 escribe 52 y Java 17 escribe 61.
    public static func readingClassFile(major: Int) -> JavaFeature? {
        major >= 45 ? JavaFeature(major - 44) : nil
    }

    /// Las de soporte largo son las que Temurin mantiene publicadas. Pedirle una que ya no esté
    /// da un 404 a mitad del traslado, así que se sube a la primera que exista y sepa leer este
    /// bytecode: una máquina virtual nueva lee el bytecode viejo, al revés no.
    public static let longTermSupport = [8, 11, 17, 21, 25]

    public var runtimeToDownload: JavaFeature? {
        Self.longTermSupport.first { $0 >= number }.map(JavaFeature.init)
    }

    /// Temurin no publica Java 8 para Apple silicon, y no es un descuido: Java 8 es de 2014 y el
    /// primer Mac de ARM de 2020. Comprobado contra la API de Adoptium —de la 11 en adelante hay
    /// `aarch64`, de la 8 solo `x64`—. Un juego de Java 8 va con el de Intel y Rosetta, que es
    /// más fiel que subirlo a la 11, donde se quitaron cosas, sin un juego con el que comprobarlo.
    public static let oldestOnAppleSilicon = JavaFeature(11)

    public func needsRosetta(appleSilicon: Bool) -> Bool {
        appleSilicon && self < Self.oldestOnAppleSilicon
    }

    /// La arquitectura tal como la nombra Adoptium.
    public func architecture(appleSilicon: Bool) -> String {
        (appleSilicon && self >= Self.oldestOnAppleSilicon) ? "aarch64" : "x64"
    }

    /// El JRE de Temurin de esta versión. `latest/<N>/ga` da siempre la última corrección, que es
    /// lo que se quiere: dentro de una versión mayor no hay incompatibilidades que temer.
    public func macDownloadURL(appleSilicon: Bool) -> URL {
        URL(string: "https://api.adoptium.net/v3/binary/latest/\(number)/ga/mac/"
            + "\(architecture(appleSilicon: appleSilicon))/jre/hotspot/normal/eclipse")!
    }
}

/// De dónde salió el número de versión de Java, porque no todas las fuentes valen lo mismo.
public enum JavaRequirementOrigin: Equatable, Sendable {
    /// Del `release` del `jre/` que el juego trae dentro. Es la mejor: es con la que su autor lo
    /// probó, no la mínima con la que compila.
    case bundledRuntime
    /// Del número mayor del formato de la clase principal. Es un suelo, no una preferencia.
    case classFile
}

/// Dónde está el jar que arranca el juego.
public enum JavaLaunchJar: Equatable, Sendable {
    /// Pegado al final del `.exe`. Es lo que hace Launch4j: su lanzador nativo con el jar detrás.
    case fused(URL, offset: UInt64)
    /// Un `.jar` suelto al lado del `.exe`.
    case sibling(URL)

    public var container: URL {
        switch self {
        case .fused(let url, _): return url
        case .sibling(let url): return url
        }
    }
}

/// Un jar de nativos de LWJGL que el juego trae compilado para Windows.
///
/// LWJGL 3 carga sus binarios del propio classpath, no de `java.library.path`, así que basta con
/// cambiar el jar por el de macOS y no hay que tocar cómo se lanza el juego. Medido con un juego
/// hecho a mano: con el de Windows falla con `UnsatisfiedLinkError: liblwjgl.dylib` y LWJGL avisa
/// de «Platform/architecture mismatch»; cambiando solo el jar, arranca y pinta.
public struct LwjglNatives: Equatable, Sendable {
    /// Nombre del artefacto en Maven, tal cual lo dice `Implementation-Title`: `lwjgl`,
    /// `lwjgl-glfw`, `lwjgl-opengl`…
    public let module: String
    /// De `Specification-Version`. `Implementation-Version` no sirve: ahí pone «build 1».
    public let version: String
    /// Ruta del jar dentro del reparto, relativa a la carpeta del juego.
    public let relativePath: String

    public init(module: String, version: String, relativePath: String) {
        self.module = module
        self.version = version
        self.relativePath = relativePath
    }

    /// La misma versión, obligatoriamente: LWJGL comprueba que los bindings y los binarios
    /// coincidan y se niega a arrancar si no.
    public func macAssetName(appleSilicon: Bool) -> String {
        // El de Intel se llama `natives-macos` a secas, sin `-x64`. El de ARM sí lleva sufijo.
        "\(module)-\(version)-natives-\(appleSilicon ? "macos-arm64" : "macos").jar"
    }

    public func macDownloadURL(appleSilicon: Bool) -> URL {
        URL(string: "https://repo1.maven.org/maven2/org/lwjgl/\(module)/\(version)/"
            + macAssetName(appleSilicon: appleSilicon))!
    }
}

/// Retrato de un `.exe` que resultó ser un juego de Java.
///
/// Java es el caso más limpio de todos: el bytecode ya es portable y no hay que cambiar ni una
/// línea. Lo único de Windows son el lanzador —que se tira— y los binarios de las librerías
/// nativas, que se sustituyen uno a uno por los que el propio proyecto publica para macOS.
public struct JavaGame: Equatable, Sendable {
    public let executable: URL
    /// Carpeta que contiene el `.exe`, los jars y, a veces, un `jre/` entero.
    public let root: URL
    public let launchJar: JavaLaunchJar
    /// Clase con el `main`, del `Main-Class` del manifiesto. Sin ella no hay nada que lanzar.
    public let mainClass: String
    /// Archivos y carpetas del juego que viajan al `.app`. No incluye el `.exe` ni el `jre/`.
    public let gameEntries: [String]
    public let gameBytes: Int64
    public let required: JavaFeature
    public let requiredFrom: JavaRequirementOrigin
    /// Jars de nativos de LWJGL para Windows, que sí tienen sustituto.
    public let lwjgl: [LwjglNatives]
    /// Binarios de Windows sueltos que no lo tienen.
    public let windowsLibraries: [String]
    public let appleSilicon: Bool

    public init(
        executable: URL,
        root: URL,
        launchJar: JavaLaunchJar,
        mainClass: String,
        gameEntries: [String],
        gameBytes: Int64,
        required: JavaFeature,
        requiredFrom: JavaRequirementOrigin,
        lwjgl: [LwjglNatives],
        windowsLibraries: [String],
        appleSilicon: Bool
    ) {
        self.executable = executable
        self.root = root
        self.launchJar = launchJar
        self.mainClass = mainClass
        self.gameEntries = gameEntries
        self.gameBytes = gameBytes
        self.required = required
        self.requiredFrom = requiredFrom
        self.lwjgl = lwjgl
        self.windowsLibraries = windowsLibraries
        self.appleSilicon = appleSilicon
    }

    /// La que se descarga, que puede ser más nueva que la que pide el juego.
    public var runtime: JavaFeature? { required.runtimeToDownload }

    public var version: String { required.description }

    public var runtimeVersionText: String { runtime?.description ?? required.description }

    /// `false` solo si Temurin ya no publica ninguna versión capaz de leer este bytecode. Hoy no
    /// pasa; pasará el día que salga un formato de clase más nuevo que la última de soporte largo.
    public var isSupported: Bool { runtime != nil }

    public var needsRosetta: Bool {
        runtime.map { $0.needsRosetta(appleSilicon: appleSilicon) } ?? false
    }

    /// En macOS, GLFW exige ser el primer hilo del proceso y la JVM solo lo es con
    /// `-XstartOnFirstThread`. En Windows no hace falta, así que el reparto no lo trae.
    ///
    /// No se pone siempre: con AWT o Swing esa bandera estorba, porque su bucle de eventos quiere
    /// para sí el mismo hilo. Se pone cuando el juego trae GLFW, que es cuando se sabe que hace
    /// falta.
    public var needsMainThreadFlag: Bool { lwjgl.contains { $0.module == "lwjgl-glfw" } }

    public var macRuntimeURL: URL? { runtime?.macDownloadURL(appleSilicon: appleSilicon) }

    public var architecture: String {
        runtime?.architecture(appleSilicon: appleSilicon) ?? (appleSilicon ? "aarch64" : "x64")
    }

    /// El nombre del `.exe` sin extensión. En Java no hay mejor sitio de donde sacarlo: el
    /// manifiesto no lleva título y el `Main-Class` es un nombre de paquete.
    public var suggestedAppName: String {
        let base = executable.deletingPathExtension().lastPathComponent
        let limpio = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\t"))
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return limpio.isEmpty ? "juego" : limpio
    }
}
