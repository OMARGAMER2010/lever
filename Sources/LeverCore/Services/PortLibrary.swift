import Foundation

/// Receta para compilar la parte de macOS de un complemento nativo.
///
/// No hay forma general de hacerlo: cada GDExtension trae su propio sistema de compilación. Por
/// eso esto es una lista de casos conocidos y no un mecanismo automático. El resto se detecta y
/// se dice con nombre y apellidos, que es mucho mejor que un juego que arranca y peta sin motivo.
public struct NativePartRecipe: Equatable, Sendable {
    /// Carpeta del complemento dentro del juego (`addons/<esto>/…`).
    public let addonName: String
    /// Cómo se llama de cara al usuario.
    public let displayName: String
    /// Para qué sirve, en una línea.
    public let purposeKey: TextKey
    /// Guion que hace el trabajo; viaja dentro del `.app`.
    public let scriptName: String
    public let approximateMinutes: Int
    public let neededGigabytes: Int

    /// Complementos que Lever sabe rehacer.
    public static let known: [NativePartRecipe] = [
        NativePartRecipe(
            addonName: "gde_gozen",
            displayName: "GoZen",
            purposeKey: .recipeGozen,
            scriptName: "build-gozen",
            approximateMinutes: 25,
            neededGigabytes: 6
        )
    ]

    public static func recipe(forAddon name: String) -> NativePartRecipe? {
        known.first { $0.addonName.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Guarda las librerías nativas de macOS ya conseguidas, para no volver a compilarlas.
///
/// La clave es el nombre exacto del `.dylib` que pide el `.gdextension`. Es la identidad que de
/// verdad importa —lleva dentro complemento, plataforma, perfil y arquitectura— y sirve igual
/// para un archivo compilado aquí que para uno que el usuario deje caer a mano en la carpeta.
public final class PortLibrary: @unchecked Sendable {
    public static let shared = PortLibrary()

    private let fileManager: FileManager
    private let customRoot: URL?

    /// - Parameter root: carpeta base. Solo se cambia en las pruebas, para que no dependan de lo
    ///   que el usuario tenga guardado de verdad ni se lo ensucien.
    public init(fileManager: FileManager = .default, root: URL? = nil) {
        self.fileManager = fileManager
        self.customRoot = root
    }

    private var root: URL {
        if let customRoot { return customRoot }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Lever/godot", isDirectory: true)
    }

    public var folderURL: URL {
        root.appendingPathComponent("gdextensions", isDirectory: true)
    }

    /// Carpeta donde se guardan las plantillas del motor, una por versión. La segunda vez que se
    /// traslada un juego de la misma versión ya no hay que descargar nada.
    public var templatesFolderURL: URL {
        root.appendingPathComponent("templates", isDirectory: true)
    }

    public func templateURL(for version: GodotVersion) -> URL {
        templatesFolderURL.appendingPathComponent(version.releaseTag, isDirectory: true)
            .appendingPathComponent("macos_template.app", isDirectory: true)
    }

    public func hasTemplate(for version: GodotVersion) -> Bool {
        let binary = templateURL(for: version)
            .appendingPathComponent("Contents/MacOS/godot_macos_release.universal")
        return fileManager.fileExists(atPath: binary.path)
    }

    /// Binarios de macOS del intérprete de Ren'Py, una carpeta por versión. Ren'Py empareja el
    /// intérprete compilado con el código Python de `renpy/`, así que no se pueden mezclar.
    public func renpyRuntimeURL(version: String) -> URL {
        root.appendingPathComponent("renpy", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    public func hasRenpyRuntime(version: String) -> Bool {
        let folder = renpyRuntimeURL(version: version)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.contains { RenpyInspector.isMacLibraryFolder($0) }
    }

    /// El `love.app` que publica LÖVE, una carpeta por versión. El motor y el juego no van
    /// emparejados como en Ren'Py, pero la API cambió mucho entre la 0.10 y la 11: abrir un
    /// juego con el motor equivocado da una ventana en negro y un error de Lua.
    public func loveRuntimeURL(version: String) -> URL {
        root.appendingPathComponent("love", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    public func hasLoveRuntime(version: String) -> Bool {
        let binary = loveRuntimeURL(version: version)
            .appendingPathComponent("love.app/Contents/MacOS/love")
        return fileManager.fileExists(atPath: binary.path)
    }

    /// El `nwjs.app` que publica NW.js, una carpeta por versión. Son trescientos megas cada una,
    /// así que reutilizarla entre juegos de la misma versión no es un lujo.
    public func nwjsRuntimeURL(version: String) -> URL {
        root.appendingPathComponent("nwjs", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    public func hasNwjsRuntime(version: String) -> Bool {
        let binary = nwjsRuntimeURL(version: version)
            .appendingPathComponent("nwjs.app/Contents/MacOS/nwjs")
        return fileManager.fileExists(atPath: binary.path)
    }

    /// Las partes nativas ya conseguidas, una carpeta por identidad completa —nombre, versión,
    /// plataforma y ABI—. Es la primera de las tres estrategias: lo que ya se bajó una vez no se
    /// vuelve a bajar, y da igual para qué motor fuera.
    public func nativePartURL(key: String) -> URL {
        root.appendingPathComponent("partes", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// El `Electron.app` que publica Electron, una carpeta por versión. Son doscientos cincuenta
    /// megas desplegados, así que reutilizarlo entre juegos de la misma versión importa.
    public func electronRuntimeURL(version: String) -> URL {
        root.appendingPathComponent("electron", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    public func hasElectronRuntime(version: String) -> Bool {
        let binario = electronRuntimeURL(version: version)
            .appendingPathComponent("Electron.app/Contents/MacOS/Electron")
        return fileManager.fileExists(atPath: binario.path)
    }

    /// Los JRE de Temurin, una carpeta por versión y arquitectura. Las dos cosas hacen falta en
    /// la clave: un juego de Java 8 baja el de Intel y uno de Java 17 el de ARM, y los dos pueden
    /// convivir en el mismo Mac.
    public func javaRuntimeURL(feature: String, architecture: String) -> URL {
        root.appendingPathComponent("java", isDirectory: true)
            .appendingPathComponent("\(feature)-\(architecture)", isDirectory: true)
    }

    public func hasJavaRuntime(feature: String, architecture: String) -> Bool {
        let java = javaRuntimeURL(feature: feature, architecture: architecture)
            .appendingPathComponent("Contents/Home/bin/java")
        return fileManager.fileExists(atPath: java.path)
    }

    /// Las herramientas de Android que Lever se baja cuando el Mac no las tiene. Van juntas en
    /// una carpeta propia porque no son de ningún juego: se bajan una vez y sirven para todos.
    private var androidToolsURL: URL {
        root.appendingPathComponent("android", isDirectory: true)
    }

    public func bundletoolURL(version: String) -> URL {
        androidToolsURL.appendingPathComponent("bundletool-\(version).jar")
    }

    public func buildToolsURL(release: String) -> URL {
        androidToolsURL.appendingPathComponent("build-tools-\(release)", isDirectory: true)
    }

    /// La clave con la que Lever firma los `.apk` que llegan sin firma. Una sola para todos: si
    /// cambiara, un juego firmado ayer no podría actualizarse con el de hoy.
    public var androidKeysURL: URL {
        androidToolsURL.appendingPathComponent("claves", isDirectory: true)
    }

    /// Los núcleos de libretro, una carpeta por arquitectura.
    ///
    /// La arquitectura va en la ruta y no es cosmética: un núcleo lo carga RetroArch dentro de su
    /// propio proceso, así que tiene que ser de la suya, no de la del Mac. Un Mac puede acabar con
    /// las dos carpetas si el usuario cambia de RetroArch, y mezclarlas es justo lo que rompe.
    public func retroCoreURL(architecture: String) -> URL {
        root.appendingPathComponent("nucleos", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
    }

    public func hasRetroCore(_ core: String, architecture: String) -> Bool {
        let archivo = retroCoreURL(architecture: architecture)
            .appendingPathComponent("\(core)_libretro.dylib")
        return fileManager.fileExists(atPath: archivo.path)
    }

    /// Donde van las partidas guardadas, los estados y las BIOS que ponga el usuario. Aparte de
    /// las de su RetroArch a propósito: Lever no le toca lo suyo.
    public var retroDataURL: URL {
        root.appendingPathComponent("emulacion", isDirectory: true)
    }

    public func url(forLibraryNamed name: String) -> URL? {
        let candidate = folderURL.appendingPathComponent(name)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Copia una librería recién conseguida a la biblioteca. Sobrescribe a propósito: si se
    /// vuelve a compilar es porque la anterior no servía.
    public func store(_ source: URL, as name: String) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let destination = folderURL.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Lo que hay guardado, para poder enseñarlo.
    public func storedLibraryNames() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? [])
            .filter { $0.hasSuffix(".dylib") }
            .sorted()
    }
}
