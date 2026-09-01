import Foundation

/// Reconoce los juegos hechos con Ren'Py y averigua qué versión necesitan.
public enum RenpyInspector {
    /// Devuelve el retrato del juego, o `nil` si el `.exe` no es de Ren'Py.
    public static func inspect(program: URL, fileManager: FileManager = .default) -> RenpyGame? {
        let root = program.deletingLastPathComponent()

        // La firma de Ren'Py: `renpy/` (el intérprete en Python) junto a `game/` (el juego).
        // Las dos a la vez, porque `game/` sola la tienen muchas cosas.
        var isDirectory: ObjCBool = false
        let hasRenpy = fileManager.fileExists(atPath: root.appendingPathComponent("renpy").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let hasGame = fileManager.fileExists(atPath: root.appendingPathComponent("game").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        guard hasRenpy, hasGame else { return nil }

        guard let version = readVersion(root: root, fileManager: fileManager) else { return nil }

        let libraries = (try? fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("lib").path)) ?? []

        return RenpyGame(
            executable: program,
            root: root,
            fullVersion: version,
            pythonLibraryName: libraries.first { $0.hasPrefix("python") },
            carriesMacRuntime: libraries.contains { isMacLibraryFolder($0) },
            iconRelativePath: findIcon(root: root, fileManager: fileManager)
        )
    }

    /// La versión sale de `renpy/vc_version.py`, que es donde Ren'Py la sella al compilarse.
    ///
    /// Si un juego lo ha borrado —hay quien poda la carpeta `renpy/`— queda `script_version.txt`,
    /// que Ren'Py escribe dentro de `game/` con la tupla `(8, 6, 0)`. No sirve mirar
    /// `renpy/__init__.py`: ahí la versión se importa de `vc_version`, no hay número que leer.
    public static func readVersion(root: URL, fileManager: FileManager = .default) -> String? {
        let stamped = root.appendingPathComponent("renpy/vc_version.py")
        if let text = try? String(contentsOf: stamped, encoding: .utf8),
           let version = firstMatch(in: text, pattern: #"version\s*=\s*['"]([0-9][0-9.]*)['"]"#) {
            return version
        }

        let script = root.appendingPathComponent("game/script_version.txt")
        if let text = try? String(contentsOf: script, encoding: .utf8),
           let tuple = firstMatch(in: text, pattern: #"\(\s*(\d+\s*,\s*\d+\s*,\s*\d+)\s*\)"#) {
            return tuple.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
        }
        return nil
    }

    /// Los binarios de macOS han cambiado de nombre con los años: `darwin-x86_64` en Ren'Py 6 y 7
    /// tempranas, `py2-mac-x86_64` después, y `py3-mac-universal` en la 8.
    public static func isMacLibraryFolder(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("mac") || lowered.contains("darwin")
    }

    /// Ren'Py deja el icono de ventana en un sitio fijo de la plantilla. Si el juego lo cambió de
    /// sitio no pasa nada: el `.app` sale con el icono genérico y funciona igual.
    private static func findIcon(root: URL, fileManager: FileManager) -> String? {
        let candidates = [
            "game/gui/window_icon.png",
            "game/window_icon.png",
            "game/gui/icon.png",
            "icon.png"
        ]
        return candidates.first { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
