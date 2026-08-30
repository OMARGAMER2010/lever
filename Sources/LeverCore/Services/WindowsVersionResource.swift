import Foundation

/// Los cuatro números del recurso de versión de un binario de Windows.
///
/// Sirve para cualquier motor que reparta su runtime como DLL: LÖVE lo pone en `love.dll` y NW.js
/// en `nw.dll`. En los dos casos es la fuente fiable, porque las herramientas que empaquetan
/// juegos reescriben el recurso del `.exe` con el nombre y la versión del juego y dejan la DLL en
/// paz.
public struct WindowsFileVersion: Equatable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int

    public init(major: Int, minor: Int, patch: Int, build: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    public static func < (left: WindowsFileVersion, right: WindowsFileVersion) -> Bool {
        (left.major, left.minor, left.patch, left.build) < (right.major, right.minor, right.patch, right.build)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Lee el `VS_VERSION_INFO` de un PE (`.exe` o `.dll`).
///
/// Solo interesa el bloque binario `VS_FIXEDFILEINFO`, que trae la versión como cuatro enteros en
/// un sitio fijo. La tabla de cadenas del mismo recurso diría lo mismo, pero está en UTF-16 con
/// relleno a cuatro bytes entre campos y no aporta nada que no esté ya en los enteros.
public enum WindowsVersionResource {
    private static let versionResourceType: UInt32 = 16   // RT_VERSION
    private static let fixedInfoSignature: UInt32 = 0xFEEF_04BD

    public static func productVersion(of file: URL) -> WindowsFileVersion? {
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
    private static func fixedFileInfo(_ data: Data, from start: Int, length: Int) -> WindowsFileVersion? {
        var cursor = start
        let end = min(start + length, data.count) - 24
        while cursor <= end {
            if data.u32(cursor) == fixedInfoSignature {
                guard let productMS = data.u32(cursor + 16), let productLS = data.u32(cursor + 20) else { return nil }
                return WindowsFileVersion(
                    major: Int(productMS >> 16),
                    minor: Int(productMS & 0xFFFF),
                    patch: Int(productLS >> 16),
                    build: Int(productLS & 0xFFFF)
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
