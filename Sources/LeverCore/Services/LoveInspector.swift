import Foundation

/// Reconoce los juegos hechos con LÖVE y averigua qué versión del motor necesitan.
///
/// La firma son dos cosas a la vez: un `.love` —que es un ZIP con `main.lua` en la raíz, pegado
/// al final del `.exe` o suelto al lado— y la `love.dll` de la carpeta, que es de donde sale la
/// versión. Sin la DLL no hay distribución de LÖVE para Windows que valga: el `.exe` la importa
/// por nombre y sin ella no arranca ni en Windows.
public enum LoveInspector {
    /// Devuelve el retrato del juego, o `nil` si el `.exe` no es de LÖVE.
    public static func inspect(program: URL, fileManager: FileManager = .default) -> LoveGame? {
        let root = program.deletingLastPathComponent()

        guard let version = engineVersion(in: root, fileManager: fileManager) else { return nil }
        guard let (payload, bytes) = locatePayload(for: program, in: root, fileManager: fileManager) else { return nil }

        return LoveGame(
            executable: program,
            root: root,
            engineVersion: version,
            payload: payload,
            payloadBytes: bytes,
            windowsLibraries: foreignLibraries(in: root, fileManager: fileManager)
        )
    }

    // MARK: - Versión del motor

    /// La versión sale del recurso `VS_VERSION_INFO` de `love.dll`.
    public static func engineVersion(in folder: URL, fileManager: FileManager = .default) -> LoveVersion? {
        let dll = folder.appendingPathComponent("love.dll")
        guard fileManager.fileExists(atPath: dll.path) else { return nil }
        guard let version = WindowsVersionResource.productVersion(of: dll) else { return nil }
        return LoveVersion(major: version.major, minor: version.minor, patch: version.patch)
    }

    // MARK: - Localizar el juego

    /// Busca el `.love`: primero pegado al final del `.exe`, y si no, suelto en la carpeta.
    public static func locatePayload(
        for program: URL,
        in folder: URL,
        fileManager: FileManager = .default
    ) -> (LovePayload, Int64)? {
        if let start = ZipTrailer.archiveStart(of: program), start > 0,
           ZipTrailer.containsMainLua(in: program, archiveStart: start) {
            let total = (try? fileManager.attributesOfItem(atPath: program.path)[.size] as? Int64) ?? nil
            return (.fused(program, offset: start), (total ?? 0) - Int64(start))
        }

        // Reparto sin fusionar: `love.exe` con el `juego.love` al lado. Solo vale si hay uno,
        // porque con dos no hay forma de saber cuál quería el desarrollador.
        let loves = ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "love" }
        if loves.count == 1, let start = ZipTrailer.archiveStart(of: loves[0]),
           ZipTrailer.containsMainLua(in: loves[0], archiveStart: start) {
            let size = (try? fileManager.attributesOfItem(atPath: loves[0].path)[.size] as? Int64) ?? nil
            return (.sibling(loves[0]), size ?? 0)
        }
        return nil
    }

    // MARK: - Librerías del juego

    /// DLL de la carpeta que no vienen del motor.
    ///
    /// Cada una es un módulo de Lua compilado —`https`, `luasocket`, `sqlite3`, un binding de
    /// ImGui— que el juego carga con `require`. No hay ningún sitio de donde bajar la versión de
    /// macOS, así que lo único honesto es nombrarlas y decir que lo que dependa de ellas fallará.
    public static func foreignLibraries(in folder: URL, fileManager: FileManager = .default) -> [String] {
        guard let walker = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: Set<String> = []
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants() }
            guard url.pathExtension.lowercased() == "dll" else { continue }
            let name = url.lastPathComponent
            if !isEngineLibrary(name) { found.insert(name) }
        }
        return found.sorted()
    }

    /// Las DLL que trae el propio LÖVE, más la biblioteca de C de Visual Studio que las acompaña.
    public static func isEngineLibrary(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let engine: Set<String> = [
            "love.dll", "lua51.dll", "sdl2.dll", "openal32.dll", "mpg123.dll",
            "libogg.dll", "libvorbis.dll", "libtheora.dll", "libmodplug.dll", "freetype.dll"
        ]
        if engine.contains(lowered) { return true }
        // El redistribuible de Visual C++ viaja en piezas con nombres muy variados.
        let runtimePrefixes = ["msvcp", "msvcr", "vcruntime", "concrt", "ucrtbase", "api-ms-win-"]
        return runtimePrefixes.contains { lowered.hasPrefix($0) }
    }
}
