import Compression
import Foundation

/// Fabrica comprimidos hostiles para las pruebas de Safe Mode. Todo se escribe a mano, byte a byte:
/// las herramientas normales se niegan a crear entradas con `../` o enlaces que salgan fuera, que
/// es exactamente lo que hay que probar.
enum SafeModeFixtures {
    struct ZipEntry {
        let name: String
        let data: Data
        var mode: UInt16 = 0o100644
        var deflated = false

        static func file(_ name: String, _ text: String, mode: UInt16 = 0o100644) -> ZipEntry {
            ZipEntry(name: name, data: Data(text.utf8), mode: mode)
        }

        static func symlink(_ name: String, to target: String) -> ZipEntry {
            ZipEntry(name: name, data: Data(target.utf8), mode: 0o120777)
        }
    }

    /// Zip con permisos de Unix en los atributos externos, que es donde viaja un enlace simbólico.
    static func zip(_ entries: [ZipEntry]) -> Data {
        var output = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let payload = entry.deflated ? deflate(entry.data) : entry.data
            let method: UInt16 = entry.deflated ? 8 : 0
            let crc = crc32(entry.data)
            let offset = UInt32(output.count)
            output += le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
            output += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(entry.data.count))
            output += le16(UInt16(name.count)) + le16(0) + name + payload

            directory += le32(0x0201_4B50) + le16(0x031E) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
            directory += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(entry.data.count))
            directory += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            directory += le32(UInt32(entry.mode) << 16) + le32(offset) + name
        }
        let directoryOffset = UInt32(output.count)
        output += directory
        output += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        output += le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0)
        return output
    }

    enum TarEntry {
        case file(String, String, mode: Int = 0o644)
        case symlink(String, target: String)
        case hardlink(String, target: String)
    }

    /// Tar ustar: bloques de 512 bytes, campos en octal y la suma de control con su hueco en blanco.
    static func tar(_ entries: [TarEntry]) -> Data {
        var output = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int, length: Int) {
                let bytes = Array(text.utf8.prefix(length))
                header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
            func octal(_ value: Int, at offset: Int, length: Int) {
                put(String(format: "%0\(length - 1)o", value), at: offset, length: length - 1)
            }
            var body = Data()
            switch entry {
            case .file(let name, let text, let mode):
                body = Data(text.utf8)
                put(name, at: 0, length: 100); octal(mode, at: 100, length: 8); put("0", at: 156, length: 1)
            case .symlink(let name, let target):
                put(name, at: 0, length: 100); octal(0o777, at: 100, length: 8); put("2", at: 156, length: 1)
                put(target, at: 157, length: 100)
            case .hardlink(let name, let target):
                put(name, at: 0, length: 100); octal(0o644, at: 100, length: 8); put("1", at: 156, length: 1)
                put(target, at: 157, length: 100)
            }
            octal(0, at: 108, length: 8); octal(0, at: 116, length: 8)
            octal(body.count, at: 124, length: 12); octal(1_700_000_000, at: 136, length: 12)
            put("ustar", at: 257, length: 6); put("00", at: 263, length: 2)
            put("        ", at: 148, length: 8)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", checksum) + "\0 ", at: 148, length: 8)
            output += Data(header) + body
            let padding = (512 - body.count % 512) % 512
            output += Data(repeating: 0, count: padding)
        }
        output += Data(repeating: 0, count: 1024)
        return output
    }

    /// Lo justo para que un lector de PE lo reconozca: cabecera DOS, «PE», máquina x64 y la
    /// cabecera opcional de PE32+ con 16 directorios. `signed` rellena la tabla de certificados.
    static func peExecutable(isDLL: Bool = false, signed: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4D; bytes[1] = 0x5A
        bytes[0x3C] = 0x80
        let pe = 0x80
        bytes.replaceSubrange(pe..<(pe + 4), with: [0x50, 0x45, 0, 0])
        bytes[pe + 4] = 0x64; bytes[pe + 5] = 0x86
        bytes[pe + 20] = 0xF0
        let characteristics: UInt16 = isDLL ? 0x2022 : 0x0022
        bytes[pe + 22] = UInt8(characteristics & 0xFF); bytes[pe + 23] = UInt8(characteristics >> 8)
        let optional = pe + 24
        bytes[optional] = 0x0B; bytes[optional + 1] = 0x02
        bytes[optional + 108] = 16
        if signed {
            let certificateSize = optional + 112 + 4 * 8 + 4
            bytes[certificateSize] = 0x10
        }
        return Data(bytes)
    }

    // MARK: - Bytes

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func deflate(_ data: Data) -> Data {
        let capacity = max(data.count / 2, 4096)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return output.prefix(written)
    }
}
