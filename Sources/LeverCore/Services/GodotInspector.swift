import Foundation

/// Averigua si un `.exe` es en realidad un juego de Godot, y qué necesita para correr en Mac.
///
/// La idea de fondo: en Godot el `.exe` es solo el motor compilado para Windows. El juego vive
/// en el `.pck`, que no depende de la plataforma. Si se identifica la versión del motor se puede
/// emparejar ese mismo `.pck` con el motor de macOS y saltarse Wine entero.
public enum GodotInspector {
    private static let packMagic: UInt32 = 0x4350_4447 // "GDPC" en little-endian

    // MARK: - Entrada

    /// Devuelve el retrato del juego, o `nil` si el archivo no es un juego de Godot.
    ///
    /// No lanza: que un `.exe` no sea de Godot es lo normal, no un error.
    public static func inspect(
        program: URL,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default
    ) -> GodotGame? {
        guard let location = locatePack(for: program, fileManager: fileManager) else { return nil }
        guard let pack = try? Pack(location: location) else { return nil }

        let extensions = pack.extensionConfigPaths.map { path -> GodotExtension in
            let text = pack.text(at: path) ?? ""
            let macPath = macLibraryPath(inConfig: text)
            let addon = addonName(fromConfigPath: path)
            return GodotExtension(
                configPath: path,
                addonName: addon,
                macLibraryPath: macPath,
                isSatisfied: isSatisfied(macPath, near: program, library: library, fileManager: fileManager)
            )
        }

        let settings = pack.projectSettings()

        return GodotGame(
            executable: program,
            version: pack.version,
            pack: location,
            packFormat: pack.format,
            projectName: settings["application/config/name"],
            iconPath: settings["application/config/icon"],
            extensions: extensions
        )
    }

    /// Saca del `.pck` un archivo suelto y lo escribe en disco. Se usa para el icono.
    public static func extract(path: String, from game: GodotGame, to destination: URL) -> Bool {
        guard let pack = try? Pack(location: game.pack), let data = pack.data(at: path) else { return false }
        return (try? data.write(to: destination)) != nil
    }

    // MARK: - Localizar el paquete

    /// Busca el `.pck`: primero al lado del `.exe`, y si no, pegado al final del propio `.exe`.
    public static func locatePack(for program: URL, fileManager: FileManager) -> GodotPackLocation? {
        let folder = program.deletingLastPathComponent()
        let baseName = program.deletingPathExtension().lastPathComponent

        // El caso normal: `Juego.exe` junto a `Juego.pck`.
        let twin = folder.appendingPathComponent(baseName + ".pck")
        if fileManager.fileExists(atPath: twin.path), hasPackMagic(at: twin, offset: 0) {
            return .sibling(twin)
        }

        // Algunos exportan con otro nombre. Si en la carpeta hay un único `.pck`, es ese.
        let packs = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "pck" } ?? []
        if packs.count == 1, hasPackMagic(at: packs[0], offset: 0) {
            return .sibling(packs[0])
        }

        if let offset = embeddedPackOffset(in: program) {
            return .embedded(program, offset: offset)
        }
        return nil
    }

    /// Exportación de un solo archivo: el `.pck` va al final del `.exe` con un pie de doce bytes
    /// —`GDPC` al final del todo y, antes, el tamaño del bloque— que permite retroceder hasta él.
    public static func embeddedPackOffset(in executable: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > 16 else { return nil }

        try? handle.seek(toOffset: total - 4)
        guard let tail = try? handle.read(upToCount: 4), readUInt32(tail, at: 0) == packMagic else { return nil }

        try? handle.seek(toOffset: total - 12)
        guard let sizeBytes = try? handle.read(upToCount: 8) else { return nil }
        let blockSize = readUInt64(sizeBytes, at: 0)
        guard blockSize > 0, blockSize + 12 <= total else { return nil }

        let start = total - 12 - blockSize
        return hasPackMagic(at: executable, offset: start) ? start : nil
    }

    private static func hasPackMagic(at url: URL, offset: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return readUInt32(head, at: 0) == packMagic
    }

    // MARK: - Complementos nativos

    /// Saca del `.gdextension` la ruta de la librería de macOS para esta máquina.
    ///
    /// Las claves son listas de etiquetas separadas por puntos (`macos.release.arm64`). Se
    /// descartan las de depuración y las de otra arquitectura; una clave sin arquitectura
    /// (`macos.release`) vale para cualquiera.
    public static func macLibraryPath(inConfig text: String, hostArchitecture: String = hostArch) -> String? {
        var inLibraries = false
        var fallback: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inLibraries = line.lowercased().hasPrefix("[libraries")
                continue
            }
            guard inLibraries, let equals = line.firstIndex(of: "=") else { continue }

            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { continue }

            let tags = key.split(separator: ".").map(String.init)
            guard tags.contains("macos") else { continue }
            guard !tags.contains("debug"), !tags.contains("template_debug") else { continue }

            let architectures = ["arm64", "x86_64", "universal"]
            let declared = tags.first { architectures.contains($0) }
            if declared == hostArchitecture || declared == "universal" { return value }
            if declared == nil { fallback = value }
        }
        return fallback
    }

    /// `addons/gde_gozen/gozen.gdextension` -> `gde_gozen`.
    public static func addonName(fromConfigPath path: String) -> String {
        let parts = path.split(separator: "/")
        if let index = parts.firstIndex(of: "addons"), parts.index(after: index) < parts.endIndex {
            return String(parts[parts.index(after: index)])
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// ¿Tenemos ya ese `.dylib`? Puede venir en la propia carpeta del juego —hay quien exporta
    /// para varias plataformas a la vez— o estar guardado de una vez anterior.
    private static func isSatisfied(
        _ macPath: String?,
        near program: URL,
        library: PortLibrary,
        fileManager: FileManager
    ) -> Bool {
        guard let macPath else { return false }
        let fileName = URL(fileURLWithPath: macPath).lastPathComponent
        let besideExecutable = program.deletingLastPathComponent().appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: besideExecutable.path) { return true }
        return library.url(forLibraryNamed: fileName) != nil
    }

    /// Arquitectura de este Mac, con los nombres que usa Godot.
    public static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    // MARK: - Lectura del .pck

    /// Índice de un paquete de Godot, leído sin cargar el archivo entero en memoria.
    ///
    /// Soporta los formatos 2 (Godot 4.0–4.4) y 3 (4.5 en adelante, que mueve el índice al final
    /// del archivo). El formato 1 es de Godot 3: se lee la versión para poder avisar, pero su
    /// índice no se recorre porque el traslado no lo contempla.
    final class Pack {
        let version: GodotVersion
        let format: Int
        private let handle: FileHandle
        private var entries: [String: (offset: UInt64, size: UInt64)] = [:]

        var extensionConfigPaths: [String] {
            entries.keys.filter { $0.hasSuffix(".gdextension") }.sorted()
        }

        init(location: GodotPackLocation) throws {
            handle = try FileHandle(forReadingFrom: location.container)
            let start = location.startOffset
            try handle.seek(toOffset: start)

            guard let header = try handle.read(upToCount: 40), header.count == 40 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            format = Int(readUInt32(header, at: 4))
            version = GodotVersion(
                major: Int(readUInt32(header, at: 8)),
                minor: Int(readUInt32(header, at: 12)),
                patch: Int(readUInt32(header, at: 16))
            )
            guard version.major == 4, format == 2 || format == 3 else { return }

            let flags = readUInt32(header, at: 20)
            var fileBase = readUInt64(header, at: 24)
            // Desde el formato 3 el desplazamiento base puede ser relativo al inicio del paquete,
            // que es lo que permite incrustarlo dentro del `.exe`.
            if flags & 0b10 != 0 { fileBase += start }

            let directoryStart: UInt64
            if format == 3 {
                directoryStart = start + readUInt64(header, at: 32)
            } else {
                // En el formato 2 el índice va justo detrás de la cabecera y sus 16 enteros
                // reservados: 4 (magia) + 4·4 (versiones) + 4 (banderas) + 8 (base) + 64.
                directoryStart = start + 96
            }
            try readDirectory(startingAt: directoryStart, fileBase: fileBase)
        }

        deinit { try? handle.close() }

        private func readDirectory(startingAt offset: UInt64, fileBase: UInt64) throws {
            try handle.seek(toOffset: offset)
            guard let countBytes = try handle.read(upToCount: 4) else { return }
            let count = readUInt32(countBytes, at: 0)
            guard count > 0, count < 1_000_000 else { return }

            for _ in 0..<count {
                guard let lengthBytes = try handle.read(upToCount: 4) else { return }
                let length = Int(readUInt32(lengthBytes, at: 0))
                guard length > 0, length < 4096, let pathBytes = try handle.read(upToCount: length) else { return }
                guard let tail = try handle.read(upToCount: format >= 2 ? 36 : 32) else { return }

                let path = String(decoding: pathBytes, as: UTF8.self)
                    .replacingOccurrences(of: "\0", with: "")
                    .replacingOccurrences(of: "res://", with: "")
                entries[path] = (fileBase + readUInt64(tail, at: 0), readUInt64(tail, at: 8))
            }
        }

        func data(at path: String) -> Data? {
            guard let entry = entries[path], entry.size > 0, entry.size < 64_000_000 else { return nil }
            try? handle.seek(toOffset: entry.offset)
            return try? handle.read(upToCount: Int(entry.size))
        }

        func text(at path: String) -> String? {
            data(at: path).map { String(decoding: $0, as: UTF8.self) }
        }

        /// Lee los ajustes del proyecto. `project.binary` es una tabla de clave y valor con la
        /// cadena en formato Variant: un entero de tipo, la longitud y los bytes.
        func projectSettings() -> [String: String] {
            guard let data = data(at: "project.binary"), data.count > 8,
                  data.prefix(4) == Data("ECFG".utf8) else { return [:] }

            var result: [String: String] = [:]
            var cursor = 4
            let count = Int(readUInt32(data, at: cursor))
            cursor += 4
            guard count > 0, count < 10_000 else { return [:] }

            for _ in 0..<count {
                guard cursor + 4 <= data.count else { break }
                let keyLength = Int(readUInt32(data, at: cursor))
                cursor += 4
                guard keyLength > 0, cursor + keyLength <= data.count else { break }
                let key = String(decoding: data[data.startIndex + cursor ..< data.startIndex + cursor + keyLength], as: UTF8.self)
                cursor += keyLength

                guard cursor + 4 <= data.count else { break }
                let valueLength = Int(readUInt32(data, at: cursor))
                cursor += 4
                guard valueLength >= 0, cursor + valueLength <= data.count else { break }

                if valueLength >= 8, readUInt32(data, at: cursor) == 4 { // 4 = String
                    let textLength = Int(readUInt32(data, at: cursor + 4))
                    if textLength > 0, cursor + 8 + textLength <= data.count {
                        result[key] = String(
                            decoding: data[data.startIndex + cursor + 8 ..< data.startIndex + cursor + 8 + textLength],
                            as: UTF8.self
                        )
                    }
                }
                cursor += valueLength
            }
            return result
        }
    }
}

// MARK: - Lectura de enteros

/// Los paquetes de Godot van en little-endian. Se leen a mano porque `Data` no garantiza que sus
/// índices empiecen en cero cuando viene de un troceado.
func readUInt32(_ data: Data?, at offset: Int) -> UInt32 {
    guard let data, offset >= 0, offset + 4 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[base + $1]) << (8 * UInt32($1))) }
}

func readUInt64(_ data: Data?, at offset: Int) -> UInt64 {
    guard let data, offset >= 0, offset + 8 <= data.count else { return 0 }
    let base = data.startIndex + offset
    return (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[base + $1]) << (8 * UInt64($1))) }
}
