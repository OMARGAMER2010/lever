import Foundation

/// Arquitectura de un ejecutable de Windows, leída de su cabecera PE.
///
/// Importa de verdad: los Wine que hoy funcionan en Mac con chip Apple (Game Porting Toolkit,
/// CrossOver) son solo de 64 bits. Un `.exe` de 32 bits no arrancará, y es mejor decirlo antes
/// de que el usuario espere dos minutos a que se cree el entorno para nada.
public enum ProgramArchitecture: Equatable, Sendable {
    case bits32
    case bits64
    case arm64
    case unknown

    public var textKey: TextKey {
        switch self {
        case .bits32: return .arch32
        case .bits64: return .arch64
        case .arm64: return .archArm
        case .unknown: return .archUnknown
        }
    }

    /// Solo los de 32 bits dan problema con los Wine de 64 bits que hay hoy en Apple Silicon.
    public var warnsAboutWine: Bool { self == .bits32 }
}

public enum ProgramInspector {
    /// Lee la cabecera PE del ejecutable. Devuelve `.unknown` si el archivo no es un PE
    /// —un `.msi`, por ejemplo, es un contenedor OLE, no un ejecutable.
    public static func architecture(of url: URL) -> ProgramArchitecture {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }

        // "MZ" al principio marca un ejecutable de DOS/Windows.
        guard let dosHeader = try? handle.read(upToCount: 64), dosHeader.count == 64 else { return .unknown }
        guard dosHeader[0] == 0x4D, dosHeader[1] == 0x5A else { return .unknown }

        // En el offset 0x3C hay un entero de 4 bytes que apunta a la cabecera PE.
        let peOffset = dosHeader[0x3C..<0x40].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard peOffset > 0, peOffset < 0x1000_0000 else { return .unknown }

        try? handle.seek(toOffset: UInt64(peOffset))
        guard let peHeader = try? handle.read(upToCount: 6), peHeader.count == 6 else { return .unknown }

        let bytes = [UInt8](peHeader)
        // "PE\0\0" y, justo detrás, el campo Machine en little-endian.
        guard bytes[0] == 0x50, bytes[1] == 0x45, bytes[2] == 0, bytes[3] == 0 else { return .unknown }

        let machine = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        switch machine {
        case 0x014C: return .bits32
        case 0x8664: return .bits64
        case 0xAA64: return .arm64
        default: return .unknown
        }
    }
}
