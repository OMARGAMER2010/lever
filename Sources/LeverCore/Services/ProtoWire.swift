import Foundation

/// Lo mínimo de protobuf para hablar con el emulador: escribir campos y leerlos por número.
///
/// No hay generador de código ni biblioteca. Son cinco mensajes pequeños, el formato está
/// documentado y no cambia, y una biblioteca entera para esto pesaría más que lo que resuelve.
public enum ProtoWire {
    public static func varint(_ value: UInt64) -> Data {
        var bytes = Data()
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
        return bytes
    }

    /// Un entero (`int32`, `uint32`, `bool` o `enum`). Los negativos van en complemento a dos de
    /// 64 bits y ocupan diez bytes: así los escribe cualquier implementación y así los espera el
    /// emulador.
    public static func field(_ number: Int, int value: Int) -> Data {
        key(number, wireType: 0) + varint(UInt64(bitPattern: Int64(value)))
    }

    /// Texto, bytes o un mensaje dentro de otro: todos van con su longitud delante.
    public static func field(_ number: Int, bytes value: Data) -> Data {
        key(number, wireType: 2) + varint(UInt64(value.count)) + value
    }

    private static func key(_ number: Int, wireType: UInt64) -> Data {
        varint(UInt64(number) << 3 | wireType)
    }
}

/// Un mensaje protobuf leído: sus campos, en orden y sin interpretar.
public struct ProtoMessage: Sendable {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let value: Value
    }

    public let fields: [Field]

    /// `nil` si el mensaje está mal formado: mejor no leer nada que leer un número equivocado.
    public init?(_ data: Data) {
        var fields: [Field] = []
        var index = data.startIndex

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex, shift < 64 {
                let byte = data[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        func readLittleEndian(_ count: Int) -> UInt64? {
            guard data.endIndex - index >= count else { return nil }
            var value: UInt64 = 0
            for offset in 0..<count {
                value |= UInt64(data[index + offset]) << (8 * UInt64(offset))
            }
            index += count
            return value
        }

        while index < data.endIndex {
            guard let key = readVarint() else { return nil }
            let value: Value
            switch key & 7 {
            case 0:
                guard let number = readVarint() else { return nil }
                value = .varint(number)
            case 1:
                guard let number = readLittleEndian(8) else { return nil }
                value = .fixed64(number)
            case 2:
                guard let length = readVarint(), UInt64(data.endIndex - index) >= length else { return nil }
                let end = index + Int(length)
                value = .bytes(data.subdata(in: index..<end))
                index = end
            case 5:
                guard let number = readLittleEndian(4) else { return nil }
                value = .fixed32(UInt32(number))
            default:
                return nil
            }
            fields.append(Field(number: Int(key >> 3), value: value))
        }
        self.fields = fields
    }

    /// Si un campo se repite, manda el último: es la regla de protobuf.
    public func varint(_ number: Int) -> UInt64? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    public func bytes(_ number: Int) -> Data? {
        for field in fields.reversed() where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    public func message(_ number: Int) -> ProtoMessage? {
        bytes(number).flatMap { ProtoMessage($0) }
    }

    public func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }
}
