import Foundation

/// Reconoce los juegos hechos con NW.js —RPG Maker MV y MZ son los que más— y averigua qué
/// versión del motor piden.
///
/// La firma son dos cosas a la vez: `nw.dll` en la carpeta, que es de donde sale la versión, y un
/// `package.json` con `main`, que es el manifiesto sin el cual NW.js no sabe qué abrir. Ninguna de
/// las dos por separado dice gran cosa: `package.json` lo tiene medio mundo.
public enum NwjsInspector {
    /// Devuelve el retrato del juego, o `nil` si el `.exe` no es de NW.js.
    public static func inspect(program: URL, fileManager: FileManager = .default) -> NwjsGame? {
        let root = program.deletingLastPathComponent()

        guard let version = engineVersion(in: root, fileManager: fileManager) else { return nil }
        guard let manifest = readManifest(in: root, fileManager: fileManager) else { return nil }

        let entries = gameEntries(in: root, executable: program, fileManager: fileManager)
        guard !entries.isEmpty else { return nil }

        return NwjsGame(
            executable: program,
            root: root,
            engineVersion: version,
            manifest: manifest,
            gameEntries: entries,
            gameBytes: size(of: entries, in: root, fileManager: fileManager),
            windowsModules: foreignModules(in: root, entries: entries, fileManager: fileManager),
            appleSilicon: GodotInspector.hostArch == "arm64"
        )
    }

    // MARK: - Versión del motor

    public static func engineVersion(in folder: URL, fileManager: FileManager = .default) -> NwjsVersion? {
        let dll = folder.appendingPathComponent("nw.dll")
        guard fileManager.fileExists(atPath: dll.path) else { return nil }
        guard let version = WindowsVersionResource.productVersion(of: dll) else { return nil }
        return NwjsVersion(major: version.major, minor: version.minor, patch: version.patch)
    }

    // MARK: - Manifiesto

    /// Lee el `package.json` del juego. Sin `main` no es un manifiesto de NW.js.
    public static func readManifest(in folder: URL, fileManager: FileManager = .default) -> NwjsManifest? {
        let file = folder.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parseManifest(data)
    }

    public static func parseManifest(_ data: Data) -> NwjsManifest? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = raw["main"] as? String, !main.isEmpty else { return nil }
        let window = raw["window"] as? [String: Any]
        return NwjsManifest(
            main: main,
            name: raw["name"] as? String,
            title: window?["title"] as? String,
            icon: window?["icon"] as? String
        )
    }

    // MARK: - Separar el juego del motor

    /// Lo que hay en la carpeta y no es del motor: eso es el juego.
    ///
    /// Se hace por descarte y no al revés porque los repartos no se parecen entre sí —RPG Maker MV
    /// mete todo en `www/` y MZ lo deja suelto en la raíz—, mientras que la lista de archivos que
    /// pone NW.js sí es fija y conocida.
    public static func gameEntries(
        in folder: URL,
        executable: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix("."), name != executable.lastPathComponent else { return false }
            return !isEngineFile(name)
        }.sorted()
    }

    /// Los archivos que reparte NW.js, incluidos los de versiones viejas que ya no existen.
    public static func isEngineFile(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let engine: Set<String> = [
            "nw.exe", "nwjs.exe", "nw.dll", "nw_elf.dll", "node.dll", "ffmpeg.dll", "ffmpegsumo.dll",
            "libegl.dll", "libglesv2.dll", "d3dcompiler_47.dll", "d3dcompiler_43.dll", "pdf.dll",
            "icudtl.dat", "icudt.dll", "credits.html", "notification_helper.exe", "chromedriver.exe",
            "nw_100_percent.pak", "nw_200_percent.pak", "resources.pak", "nw.pak",
            "v8_context_snapshot.bin", "natives_blob.bin", "snapshot_blob.bin",
            "libwidevinecdm.dll", "widevinecdmadapter.dll", "locales", "swiftshader", "nacl64.exe"
        ]
        if engine.contains(lowered) { return true }
        // Los módulos de Native Client viajaban con nombres numerados.
        return lowered.hasPrefix("nacl_irt_") || lowered.hasPrefix("api-ms-win-")
            || lowered.hasPrefix("msvcp") || lowered.hasPrefix("msvcr") || lowered.hasPrefix("vcruntime")
    }

    /// Módulos compilados que el juego trae solo para Windows.
    ///
    /// Los `.node` son extensiones de Node —`greenworks` para los logros de Steam es el caso
    /// típico— y las `.dll` que quedan, librerías que carga el juego. Ninguna tiene un sitio
    /// público de donde bajar su versión de macOS, así que se nombran y se avisa.
    public static func foreignModules(
        in folder: URL,
        entries: [String],
        fileManager: FileManager = .default
    ) -> [String] {
        var found: Set<String> = []
        for entry in entries {
            let url = folder.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if !isDirectory.boolValue {
                if esModuloNativo(entry) { found.insert(entry) }
                continue
            }
            guard let walker = fileManager.enumerator(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let child as URL in walker {
                if walker.level > 4 { walker.skipDescendants() }
                if esModuloNativo(child.lastPathComponent) { found.insert(child.lastPathComponent) }
            }
        }
        return found.sorted()
    }

    private static func esModuloNativo(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".node") || (lowered.hasSuffix(".dll") && !isEngineFile(name))
    }

    /// Lo que ocupa el juego. Se necesita para avisar antes de empezar si no cabe.
    static func size(of entries: [String], in folder: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        var visitados = 0
        for entry in entries {
            let url = folder.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                total += (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0) ?? 0
                continue
            }
            guard let walker = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let child as URL in walker {
                // Un juego de RPG Maker son miles de archivos pequeños; con un tope el cálculo
                // deja de ser exacto pero sigue sirviendo para el aviso, que es a lo que va.
                visitados += 1
                if visitados > 50_000 { return total }
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
