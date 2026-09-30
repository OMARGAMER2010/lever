import Foundation

/// Lo que hace falta de HTTP/2 para hablar gRPC con el emulador, y nada más.
///
/// El canal es local y sin cifrar (`h2c` con conocimiento previo): no hay TLS, ni empuje del
/// servidor, ni prioridades. Las cabeceras de la petición van como literales sin Huffman, que
/// todo servidor tiene que aceptar. De las respuestas solo interesa `grpc-status`, que dice si una
/// llamada acabó bien o por qué no.
public enum HTTP2Wire {
    public static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    public enum FrameType: UInt8, Sendable {
        case data = 0, headers = 1, priority = 2, resetStream = 3, settings = 4
        case pushPromise = 5, ping = 6, goAway = 7, windowUpdate = 8, continuation = 9
    }

    public enum Flag {
        public static let endStream: UInt8 = 0x01
        public static let ack: UInt8 = 0x01
        public static let endHeaders: UInt8 = 0x04
        public static let padded: UInt8 = 0x08
        public static let priority: UInt8 = 0x20
    }

    public enum Setting {
        public static let enablePush: UInt16 = 0x2
        public static let initialWindowSize: UInt16 = 0x4
        public static let maxFrameSize: UInt16 = 0x5
    }

    /// La mayor ventana de flujo que admite HTTP/2.
    public static let maxWindow = 0x7FFF_FFFF
    /// El tamaño de trama que todo el mundo acepta sin haberlo negociado.
    public static let defaultMaxFrameSize = 16_384

    public struct FrameHeader: Equatable, Sendable {
        public let length: Int
        public let type: UInt8
        public let flags: UInt8
        public let stream: UInt32

        public init(length: Int, type: UInt8, flags: UInt8, stream: UInt32) {
            self.length = length
            self.type = type
            self.flags = flags
            self.stream = stream
        }

        /// Lee los nueve bytes de cabecera de una trama.
        public init?(_ bytes: Data) {
            guard bytes.count >= 9 else { return nil }
            let b = [UInt8](bytes.prefix(9))
            length = Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2])
            type = b[3]
            flags = b[4]
            stream = (UInt32(b[5]) << 24 | UInt32(b[6]) << 16 | UInt32(b[7]) << 8 | UInt32(b[8])) & 0x7FFF_FFFF
        }
    }

    public static func frame(_ type: FrameType, flags: UInt8 = 0, stream: UInt32, payload: Data = Data()) -> Data {
        var bytes = Data(capacity: 9 + payload.count)
        let length = payload.count
        bytes.append(UInt8((length >> 16) & 0xFF))
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(type.rawValue)
        bytes.append(flags)
        bytes.append(bigEndian(stream & 0x7FFF_FFFF))
        bytes.append(payload)
        return bytes
    }

    public static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    public static func readBigEndian(_ data: Data, at offset: Int) -> UInt32? {
        let start = data.startIndex + offset
        guard offset >= 0, data.endIndex - start >= 4 else { return nil }
        return UInt32(data[start]) << 24 | UInt32(data[start + 1]) << 16
            | UInt32(data[start + 2]) << 8 | UInt32(data[start + 3])
    }

    /// Los ajustes con que abre Lever: sin empuje, la mayor ventana de flujo que se puede pedir y
    /// tramas de hasta 16 MB, para que una imagen de 10 MB llegue en pocas tramas.
    public static func clientSettings() -> Data {
        var payload = Data()
        let pairs: [(UInt16, UInt32)] = [
            (Setting.enablePush, 0),
            (Setting.initialWindowSize, UInt32(maxWindow)),
            (Setting.maxFrameSize, 0x00FF_FFFF)
        ]
        for (id, value) in pairs {
            payload.append(UInt8(id >> 8))
            payload.append(UInt8(id & 0xFF))
            payload.append(bigEndian(value))
        }
        return frame(.settings, stream: 0, payload: payload)
    }

    /// Los pares de un `SETTINGS`: seis bytes cada uno, identificador y valor.
    public static func settings(in payload: Data) -> [(id: UInt16, value: UInt32)] {
        var result: [(id: UInt16, value: UInt32)] = []
        var offset = 0
        while offset + 6 <= payload.count {
            let start = payload.startIndex + offset
            let id = UInt16(payload[start]) << 8 | UInt16(payload[start + 1])
            if let value = readBigEndian(payload, at: offset + 2) { result.append((id, value)) }
            offset += 6
        }
        return result
    }

    public static func windowUpdate(stream: UInt32, increment: Int) -> Data {
        frame(.windowUpdate, stream: stream, payload: bigEndian(UInt32(increment) & 0x7FFF_FFFF))
    }

    /// Quita el relleno —y en `HEADERS`, la prioridad— para quedarse con el contenido. `nil` si el
    /// relleno dice ser más largo que la trama: eso es un error del otro lado.
    public static func content(of payload: Data, flags: UInt8, isHeaders: Bool) -> Data? {
        var start = payload.startIndex
        var end = payload.endIndex
        if flags & Flag.padded != 0 {
            guard start < end else { return nil }
            let padding = Int(payload[start])
            start += 1
            guard end - start >= padding else { return nil }
            end -= padding
        }
        if isHeaders, flags & Flag.priority != 0 {
            guard end - start >= 5 else { return nil }
            start += 5
        }
        return payload.subdata(in: start..<end)
    }

    // MARK: - gRPC

    /// Un mensaje gRPC: un byte de compresión (0, sin comprimir), la longitud en cuatro bytes y el
    /// mensaje.
    public static func grpcMessage(_ message: Data) -> Data {
        Data([0]) + bigEndian(UInt32(message.count)) + message
    }

    // MARK: - HPACK de ida

    public static func hpackInteger(_ value: Int, prefixBits: Int, firstByte: UInt8) -> Data {
        let limit = (1 << prefixBits) - 1
        guard value >= limit else { return Data([firstByte | UInt8(value)]) }
        var bytes = Data([firstByte | UInt8(limit)])
        var rest = value - limit
        while rest >= 128 {
            bytes.append(UInt8(rest % 128 + 128))
            rest /= 128
        }
        bytes.append(UInt8(rest))
        return bytes
    }

    public static func hpackString(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        return hpackInteger(bytes.count, prefixBits: 7, firstByte: 0) + bytes
    }

    /// El bloque de cabeceras de una llamada gRPC. `:method POST` y `:scheme http` van por su
    /// índice de la tabla estática (3 y 6); lo demás, como literales sin indexar.
    public static func requestHeaders(path: String, authority: String, token: String) -> Data {
        var block = Data([0x83, 0x86])
        block += hpackInteger(4, prefixBits: 4, firstByte: 0) + hpackString(path)
        block += hpackInteger(1, prefixBits: 4, firstByte: 0) + hpackString(authority)
        let headers = [
            ("content-type", "application/grpc"),
            ("te", "trailers"),
            ("authorization", "Bearer " + token)
        ]
        for (name, value) in headers {
            block += Data([0x00]) + hpackString(name) + hpackString(value)
        }
        return block
    }
}

/// Lee bloques de cabeceras HPACK y guarda la tabla dinámica entre uno y otro, que es lo que exige
/// el formato: el servidor la va llenando y luego nombra sus entradas por número. El emulador lo
/// hace con `grpc-status`: la primera vez lo escribe entero y las siguientes manda un solo byte.
///
/// No descifra Huffman. Un campo con Huffman se salta; y si además tenía que entrar en la tabla,
/// la tabla deja de ser fiable y ya no se lee nada más: mejor no saber un `grpc-status` que leer
/// el de otra llamada.
public final class HPACKDecoder {
    public private(set) var isReliable = true
    private var dynamicTable: [(name: String, value: String)] = []
    private var dynamicSize = 0
    private var maxSize = 4096

    public init() {}

    public func decode(_ block: Data) -> [(name: String, value: String)]? {
        guard isReliable else { return nil }
        var headers: [(name: String, value: String)] = []
        var index = block.startIndex

        func readInteger(prefixBits: Int) -> Int? {
            guard index < block.endIndex else { return nil }
            let limit = (1 << prefixBits) - 1
            var value = Int(block[index]) & limit
            index += 1
            guard value == limit else { return value }
            var shift = 0
            while index < block.endIndex, shift <= 28 {
                let byte = Int(block[index])
                index += 1
                value += (byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        /// `.some(nil)` es un texto con Huffman: se sabe cuánto mide pero no qué dice.
        func readString() -> String?? {
            guard index < block.endIndex else { return nil }
            let huffman = block[index] & 0x80 != 0
            guard let length = readInteger(prefixBits: 7), block.endIndex - index >= length else { return nil }
            let bytes = block.subdata(in: index..<(index + length))
            index += length
            return huffman ? .some(nil) : .some(String(decoding: bytes, as: UTF8.self))
        }

        func entry(_ position: Int) -> (name: String, value: String)? {
            if position >= 1, position <= Self.staticTable.count { return Self.staticTable[position - 1] }
            let dynamic = position - Self.staticTable.count - 1
            return dynamic >= 0 && dynamic < dynamicTable.count ? dynamicTable[dynamic] : nil
        }

        func readName(prefixBits: Int) -> String?? {
            guard let position = readInteger(prefixBits: prefixBits) else { return nil }
            if position == 0 { return readString() }
            guard let known = entry(position) else { return nil }
            return .some(known.name)
        }

        while index < block.endIndex {
            let byte = block[index]
            if byte & 0x80 != 0 {
                // Campo indexado: todo sale de una tabla.
                guard let position = readInteger(prefixBits: 7), let known = entry(position) else {
                    isReliable = false
                    return nil
                }
                headers.append(known)
            } else if byte & 0xC0 == 0x40 {
                // Literal que entra en la tabla dinámica.
                guard let name = readName(prefixBits: 6), let value = readString() else {
                    isReliable = false
                    return nil
                }
                guard let readableName = name, let readableValue = value else {
                    isReliable = false
                    return nil
                }
                headers.append((readableName, readableValue))
                insert(name: readableName, value: readableValue)
            } else if byte & 0xE0 == 0x20 {
                // Cambio del tamaño de la tabla.
                guard let size = readInteger(prefixBits: 5) else {
                    isReliable = false
                    return nil
                }
                maxSize = size
                evict()
            } else {
                // Literal sin indexar (0000) o que nunca se indexa (0001): no toca la tabla.
                guard let name = readName(prefixBits: 4), let value = readString() else {
                    isReliable = false
                    return nil
                }
                if let readableName = name, let readableValue = value {
                    headers.append((readableName, readableValue))
                }
            }
        }
        return headers
    }

    private func insert(name: String, value: String) {
        dynamicTable.insert((name, value), at: 0)
        dynamicSize += name.utf8.count + value.utf8.count + 32
        evict()
    }

    private func evict() {
        while dynamicSize > maxSize, let last = dynamicTable.popLast() {
            dynamicSize -= last.name.utf8.count + last.value.utf8.count + 32
        }
    }

    /// La tabla estática del RFC 7541, apéndice A.
    private static let staticTable: [(name: String, value: String)] = [
        (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"),
        (":path", "/index.html"), (":scheme", "http"), (":scheme", "https"), (":status", "200"),
        (":status", "204"), (":status", "206"), (":status", "304"), (":status", "400"),
        (":status", "404"), (":status", "500"), ("accept-charset", ""),
        ("accept-encoding", "gzip, deflate"), ("accept-language", ""), ("accept-ranges", ""),
        ("accept", ""), ("access-control-allow-origin", ""), ("age", ""), ("allow", ""),
        ("authorization", ""), ("cache-control", ""), ("content-disposition", ""),
        ("content-encoding", ""), ("content-language", ""), ("content-length", ""),
        ("content-location", ""), ("content-range", ""), ("content-type", ""), ("cookie", ""),
        ("date", ""), ("etag", ""), ("expect", ""), ("expires", ""), ("from", ""), ("host", ""),
        ("if-match", ""), ("if-modified-since", ""), ("if-none-match", ""), ("if-range", ""),
        ("if-unmodified-since", ""), ("last-modified", ""), ("link", ""), ("location", ""),
        ("max-forwards", ""), ("proxy-authenticate", ""), ("proxy-authorization", ""),
        ("range", ""), ("referer", ""), ("refresh", ""), ("retry-after", ""), ("server", ""),
        ("set-cookie", ""), ("strict-transport-security", ""), ("transfer-encoding", ""),
        ("user-agent", ""), ("vary", ""), ("via", ""), ("www-authenticate", "")
    ]
}

/// Junta los trozos que llegan en tramas DATA y devuelve los mensajes gRPC enteros. Una imagen de
/// 10 MB llega partida en muchas tramas, y dos mensajes pequeños pueden venir en una sola.
public struct GrpcMessageReader: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            guard let length = HTTP2Wire.readBigEndian(buffer, at: offset + 1).map({ Int($0) }),
                  buffer.count - offset - 5 >= length else { break }
            let start = buffer.startIndex + offset + 5
            // Un mensaje comprimido no se sabe abrir: Lever no lo pide, así que no debería llegar.
            if buffer[buffer.startIndex + offset] == 0 {
                messages.append(buffer.subdata(in: start..<(start + length)))
            }
            offset += 5 + length
        }
        if offset > 0 {
            buffer = buffer.subdata(in: (buffer.startIndex + offset)..<buffer.endIndex)
        }
        return messages
    }
}
