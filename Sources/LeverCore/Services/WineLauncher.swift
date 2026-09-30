import Foundation

/// Construye las órdenes que hacen falta para que Wine funcione al abrirse desde el Finder.
///
/// Dos detalles importantes:
/// 1. Una app lanzada desde el Finder recibe un `PATH` mínimo; hay que rehacerlo o Wine no
///    encuentra `wineserver`.
/// 2. La app usa su propio prefijo de Windows, para no tocar un `~/.wine` que el usuario ya tenga.
public enum WineLauncher {
    /// Carpeta donde la app guarda su "disco C:" de Windows.
    public static var prefixURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Lever/wine", isDirectory: true)
    }

    /// `true` cuando el prefijo no existe **o quedó a medias**.
    ///
    /// Mirar solo `system.reg` no basta: si `wineboot` se interrumpe, deja los registros escritos
    /// pero sin las DLL del sistema, y a partir de ahí Wine falla con «could not load kernel32.dll».
    /// La prueba fiable es que exista esa misma DLL.
    public static func needsFirstRunSetup(fileManager: FileManager = .default) -> Bool {
        let kernel = prefixURL.appendingPathComponent("drive_c/windows/system32/kernel32.dll")
        return !fileManager.fileExists(atPath: kernel.path)
    }

    /// Borra el prefijo para volver a crearlo desde cero.
    public static func resetPrefix(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: prefixURL.path) else { return }
        try fileManager.removeItem(at: prefixURL)
    }

    public static func environment(wine: URL, prefix: URL = prefixURL) -> [String: String] {
        let wineBinDirectory = wine.deletingLastPathComponent().path
        let path = ([wineBinDirectory] + RuntimeLocator.searchPathDirectories)
            .reduce(into: [String]()) { result, directory in
                if !result.contains(directory) { result.append(directory) }
            }
            .joined(separator: ":")

        var environment = [
            "WINEPREFIX": prefix.path,
            "PATH": path,
            // Silencia los avisos "fixme", que son ruido; los errores reales se siguen viendo.
            "WINEDEBUG": "fixme-all",
            // Evita el diálogo de Wine ofreciendo instalar Mono/Gecko en cada arranque.
            "WINEDLLOVERRIDES": "mscoree,mshtml="
        ]
        let libraries = libraryDirectories(wine: wine)
        if let external = libraries.first {
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = (libraries.map(\.path) + ["/usr/lib"]).joined(separator: ":")
            environment["DYLD_FRAMEWORK_PATH"] = external.path
            environment["WINEDLLOVERRIDES"] = "mscoree,mshtml=;d3d11,d3d12,dxgi=b"
            environment["WINEDEBUG"] = "fixme-all,err-hid"
            environment["MVK_CONFIG_LOG_LEVEL"] = "1"
            environment["MTL_HUD_ENABLED"] = "0"
            environment["MTL_HUD_LOG_ENABLED"] = "0"
            for (name, value) in WindowsSteam.synchronization { environment[name] = value }
        }
        return environment
    }

    /// Dependencias del motor con D3DMetal. En Safe Mode todas se copian dentro del motor
    /// temporal: no se concede al juego acceso a la instalación original ni a la de Steam.
    static func libraryDirectories(wine: URL) -> [URL] {
        let engine = wine.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let external = engine.appendingPathComponent("lib/external", isDirectory: true)
        guard FileManager.default.isReadableFile(atPath: external.appendingPathComponent("D3DMetal.framework/D3DMetal").path)
        else { return [] }
        var directories = [external]
        let runtimes = engine.deletingLastPathComponent().deletingLastPathComponent()
        if runtimes.lastPathComponent == "runtimes" {
            let frameworks = WindowsSteam(root: runtimes.deletingLastPathComponent()).frameworksURL
            if FileManager.default.isReadableFile(atPath: frameworks.appendingPathComponent("libinotify.0.dylib").path) {
                directories.append(frameworks)
            }
        }
        return directories
    }

    /// Prepara el prefijo por primera vez. Tarda, así que se muestra como paso propio.
    public static func bootCommand(wine: URL, prefix: URL = prefixURL) -> ProcessCommand {
        ProcessCommand(
            executableURL: wine,
            arguments: ["wineboot", "--init"],
            currentDirectoryURL: nil,
            environment: environment(wine: wine, prefix: prefix)
        )
    }

    /// Abre el panel de configuración de Wine.
    public static func configCommand(wine: URL, prefix: URL = prefixURL) -> ProcessCommand {
        ProcessCommand(
            executableURL: wine,
            arguments: ["winecfg"],
            currentDirectoryURL: nil,
            environment: environment(wine: wine, prefix: prefix)
        )
    }

    /// Orden para lanzar el programa. Los `.msi` van por `msiexec`, no directos.
    public static func runCommand(
        wine: URL,
        program: URL,
        prefix: URL = prefixURL
    ) -> ProcessCommand {
        let isInstaller = program.pathExtension.caseInsensitiveCompare("msi") == .orderedSame
        let arguments = isInstaller
            ? ["msiexec", "/i", program.path]
            : [program.path]

        return ProcessCommand(
            executableURL: wine,
            arguments: arguments,
            currentDirectoryURL: program.deletingLastPathComponent(),
            environment: environment(wine: wine, prefix: prefix)
        )
    }

    /// Cierra todos los procesos de Windows abiertos en el prefijo.
    public static func killCommand(wine: URL, prefix: URL = prefixURL) -> ProcessCommand {
        ProcessCommand(
            executableURL: wine,
            arguments: ["wineboot", "--kill"],
            currentDirectoryURL: nil,
            environment: environment(wine: wine, prefix: prefix)
        )
    }
}
