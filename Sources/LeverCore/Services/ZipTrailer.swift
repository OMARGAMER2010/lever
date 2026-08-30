import Foundation

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
