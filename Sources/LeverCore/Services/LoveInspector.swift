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
        return WindowsVersionResource.productVersion(of: dll)
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

// MARK: - Recurso de versión de un binario de Windows

/// Lee el `VS_VERSION_INFO` de un PE (`.exe` o `.dll`).
///
/// Solo interesa el bloque binario `VS_FIXEDFILEINFO`, que trae la versión como cuatro enteros
/// en un sitio fijo. La tabla de cadenas del mismo recurso diría lo mismo, pero está en UTF-16
/// con relleno a cuatro bytes entre campos y no aporta nada que no esté ya en los enteros.
public enum WindowsVersionResource {
    private static let versionResourceType: UInt32 = 16   // RT_VERSION
    private static let fixedInfoSignature: UInt32 = 0xFEEF_04BD

    public static func productVersion(of file: URL) -> LoveVersion? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard let sections = Sections(data: data), let resources = sections.resourceDirectoryOffset else { return nil }

        guard let typeEntry = subdirectory(data, at: resources, base: resources, id: versionResourceType),
              let nameEntry = firstSubdirectory(data, at: typeEntry, base: resources),
              let leaf = firstLeaf(data, at: nameEntry, base: resources) else { return nil }

        // La hoja apunta con una dirección virtual, no con una posición del archivo.
        guard let dataRVA = data.u32(leaf), let size = data.u32(leaf + 4),
              let start = sections.fileOffset(forRVA: dataRVA), size > 0 else { return nil }

        return fixedFileInfo(data, from: start, length: Int(min(size, 8192)))
    }

    /// Recorre el bloque buscando la firma del `VS_FIXEDFILEINFO`. Ir a por la firma en vez de
    /// calcular el desplazamiento evita depender del relleno que Windows mete tras la clave.
    private static func fixedFileInfo(_ data: Data, from start: Int, length: Int) -> LoveVersion? {
        var cursor = start
        let end = min(start + length, data.count) - 20
        while cursor <= end {
            if data.u32(cursor) == fixedInfoSignature {
                guard let productMS = data.u32(cursor + 16), let productLS = data.u32(cursor + 20) else { return nil }
                return LoveVersion(
                    major: Int(productMS >> 16),
                    minor: Int(productMS & 0xFFFF),
                    patch: Int(productLS >> 16)
                )
            }
            cursor += 4   // El bloque va alineado a cuatro bytes.
        }
        return nil
    }

    // MARK: Árbol de recursos

    private static func subdirectory(_ data: Data, at directory: Int, base: Int, id: UInt32) -> Int? {
        entries(data, at: directory).first { $0.name == id && $0.isDirectory }
            .map { base + $0.offset }
    }

    private static func firstSubdirectory(_ data: Data, at directory: Int, base: Int) -> Int? {
        entries(data, at: directory).first { $0.isDirectory }.map { base + $0.offset }
    }

    private static func firstLeaf(_ data: Data, at directory: Int, base: Int) -> Int? {
        entries(data, at: directory).first { !$0.isDirectory }.map { base + $0.offset }
    }

    private static func entries(_ data: Data, at directory: Int) -> [(name: UInt32, offset: Int, isDirectory: Bool)] {
        guard let named = data.u16(directory + 12), let ids = data.u16(directory + 14) else { return [] }
        let total = Int(named) + Int(ids)
        guard total > 0, total < 4096 else { return [] }

        var result: [(UInt32, Int, Bool)] = []
        for index in 0..<total {
            let entry = directory + 16 + index * 8
            guard let name = data.u32(entry), let pointer = data.u32(entry + 4) else { break }
            result.append((name, Int(pointer & 0x7FFF_FFFF), pointer & 0x8000_0000 != 0))
        }
        return result
    }

    /// Las secciones del PE, para traducir direcciones virtuales a posiciones del archivo.
    private struct Sections {
        struct Section { let virtualAddress: UInt32; let virtualSize: UInt32; let rawOffset: UInt32; let rawSize: UInt32 }
        let sections: [Section]
        let resourceRVA: UInt32
        private let data: Data

        init?(data: Data) {
            self.data = data
            guard let headerStart = data.u32(0x3C).map(Int.init), headerStart > 0, headerStart + 24 < data.count,
                  data.u32(headerStart) == 0x0000_4550 else { return nil }   // "PE\0\0"

            guard let sectionCount = data.u16(headerStart + 6),
                  let optionalSize = data.u16(headerStart + 20),
                  let magic = data.u16(headerStart + 24) else { return nil }

            // El directorio de datos empieza donde acaba la parte fija de la cabecera opcional,
            // que mide distinto en PE32 (0x10b) y en PE32+ (0x20b).
            let directories = headerStart + 24 + (magic == 0x10B ? 96 : 112)
            guard let rva = data.u32(directories + 2 * 8) else { return nil }   // entrada 2: recursos
            resourceRVA = rva

            var parsed: [Section] = []
            let table = headerStart + 24 + Int(optionalSize)
            for index in 0..<Int(sectionCount) {
                let entry = table + index * 40
                guard let virtualSize = data.u32(entry + 8), let virtualAddress = data.u32(entry + 12),
                      let rawSize = data.u32(entry + 16), let rawOffset = data.u32(entry + 20) else { break }
                parsed.append(Section(virtualAddress: virtualAddress, virtualSize: virtualSize,
                                      rawOffset: rawOffset, rawSize: rawSize))
            }
            guard !parsed.isEmpty else { return nil }
            sections = parsed
        }

        func fileOffset(forRVA rva: UInt32) -> Int? {
            for section in sections {
                let span = max(section.virtualSize, section.rawSize)
                if rva >= section.virtualAddress, rva < section.virtualAddress &+ span {
                    let offset = Int(section.rawOffset) + Int(rva - section.virtualAddress)
                    return offset < data.count ? offset : nil
                }
            }
            return nil
        }

        var resourceDirectoryOffset: Int? { fileOffset(forRVA: resourceRVA) }
    }
}

// MARK: - Final de un ZIP

/// Localiza el principio de un ZIP dentro de un archivo que puede llevar algo delante.
///
/// Es la misma idea que el pie de doce bytes del `.pck` incrustado de Godot, pero al revés: aquí
/// no hay pie propio, hay que reconstruir dónde empieza el ZIP restando al final del directorio
/// central su tamaño y su desplazamiento declarado. Es lo que hace PhysicsFS, que es la
/// biblioteca con la que LÖVE monta su propio ejecutable.
public enum ZipTrailer {
    private static let endOfCentralDirectory: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let zip64EndOfCentralDirectory: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
    private static let localFileHeader: UInt32 = 0x0403_4B50
    private static let centralFileHeader: UInt32 = 0x0201_4B50

    /// Byte donde empieza el ZIP, o `nil` si el archivo no acaba en uno.
    public static func archiveStart(of file: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total >= 22 else { return nil }

        // El comentario del ZIP mide como mucho 65535 bytes, así que el final del directorio
        // central está siempre dentro de los últimos 64 KB.
        let window = UInt64(min(total, 65_557))
        let windowStart = total - window
        try? handle.seek(toOffset: windowStart)
        guard let tail = try? handle.read(upToCount: Int(window)), tail.count >= 22 else { return nil }

        guard let eocd = lastIndex(of: endOfCentralDirectory, in: tail, minimumTail: 22) else { return nil }
        guard let sizeField = tail.u32(eocd + 12), let offsetField = tail.u32(eocd + 16) else { return nil }

        let start: UInt64
        if sizeField == 0xFFFF_FFFF || offsetField == 0xFFFF_FFFF {
            guard let resolved = zip64Start(in: tail, windowStart: windowStart) else { return nil }
            start = resolved
        } else {
            let end = windowStart + UInt64(eocd)
            let block = UInt64(sizeField) + UInt64(offsetField)
            guard end >= block else { return nil }
            start = end - block
        }

        guard start < total else { return nil }
        return readUInt32(handle, at: start) == localFileHeader ? start : nil
    }

    /// Con más de 65535 archivos o más de 4 GB, las cifras del final del directorio central se
    /// desbordan y las de verdad están en el registro ZIP64. Se busca por su firma en vez de
    /// fiarse del localizador, cuyo desplazamiento también es relativo al ZIP que aún no se sabe
    /// dónde empieza.
    private static func zip64Start(in tail: Data, windowStart: UInt64) -> UInt64? {
        guard let record = lastIndex(of: zip64EndOfCentralDirectory, in: tail, minimumTail: 56) else { return nil }
        guard let size = tail.u64(record + 40), let offset = tail.u64(record + 48) else { return nil }
        let end = windowStart + UInt64(record)
        guard end >= size + offset else { return nil }
        return end - size - offset
    }

    /// `true` si el ZIP lleva `main.lua` en la raíz, que es lo que LÖVE exige para arrancar.
    ///
    /// Sin esta comprobación cualquier `.exe` con un ZIP pegado —un instalador, un autoextraíble—
    /// pasaría por juego de LÖVE.
    public static func containsMainLua(in file: URL, archiveStart: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let total = try? handle.seekToEnd(), total > archiveStart else { return false }

        let window = UInt64(min(total - archiveStart, 65_557))
        let windowStart = total - window
        try? handle.seek(toOffset: windowStart)
        guard let tail = try? handle.read(upToCount: Int(window)),
              let eocd = lastIndex(of: endOfCentralDirectory, in: tail, minimumTail: 22),
              let entries = tail.u16(eocd + 8), let offsetField = tail.u32(eocd + 16) else { return false }

        var cursor = archiveStart + UInt64(offsetField)
        for _ in 0..<min(Int(entries), 20_000) {
            try? handle.seek(toOffset: cursor)
            guard let header = try? handle.read(upToCount: 46), header.count == 46,
                  header.u32(0) == centralFileHeader,
                  let nameLength = header.u16(28), let extraLength = header.u16(30),
                  let commentLength = header.u16(32) else { return false }
            guard let name = try? handle.read(upToCount: Int(nameLength)),
                  let text = String(data: name, encoding: .utf8) else { return false }
            if text == "main.lua" || text == "./main.lua" { return true }
            cursor += 46 + UInt64(nameLength) + UInt64(extraLength) + UInt64(commentLength)
        }
        return false
    }

    private static func lastIndex(of signature: [UInt8], in data: Data, minimumTail: Int) -> Int? {
        guard data.count >= minimumTail else { return nil }
        var index = data.count - minimumTail
        while index >= 0 {
            if data[data.startIndex + index] == signature[0],
               data[data.startIndex + index + 1] == signature[1],
               data[data.startIndex + index + 2] == signature[2],
               data[data.startIndex + index + 3] == signature[3] {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func readUInt32(_ handle: FileHandle, at offset: UInt64) -> UInt32? {
        try? handle.seek(toOffset: offset)
        guard let bytes = try? handle.read(upToCount: 4) else { return nil }
        return bytes.u32(0)
    }
}

// MARK: - Lectura con red de seguridad

/// Enteros en orden de Windows (el byte bajo primero) y sin salirse del archivo. Cualquier
/// desplazamiento fuera de rango devuelve `nil` en vez de reventar: estos datos vienen de
/// archivos ajenos y no hay ninguna garantía de que estén bien formados.
extension Data {
    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }

    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }
}
