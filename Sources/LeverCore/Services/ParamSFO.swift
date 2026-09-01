import Foundation

/// El archivo de metadatos que llevan dentro **todos** los juegos de la familia PlayStation desde
/// la PSP: PS3, PS4, PSP y Vita.
///
/// Es el hallazgo que hace posible este sprint. Donde la consola híbrida necesita las llaves del
/// usuario para llegar al nombre del juego, aquí no hace falta ninguna: el `PARAM.SFO` va **sin
/// cifrar**, dentro del propio juego, y lleva el título de verdad, la versión y qué es el
/// contenido. Un solo formato, cuatro máquinas, cero llaves.
///
/// Por dentro es una tabla de claves y una tabla de valores, y los desplazamientos de cada entrada
/// son relativos a **su** tabla, no al principio del archivo. Es el mismo error que en los
/// paquetes de la consola híbrida y con el mismo síntoma: nombres que salen cortados o vacíos, sin
/// que nada falle.
public struct ParamSFO: Equatable, Sendable {
    /// Lo que puede haber en un valor: texto o un número de 32 bits.
    public enum Value: Equatable, Sendable {
        case text(String)
        case number(UInt32)

        public var text: String? {
            switch self {
            case .text(let cadena): return cadena
            case .number(let número): return String(número)
            }
        }
    }

    private let values: [String: Value]

    /// Lo justo que hay que leer para tener un `PARAM.SFO` entero. El más grande que existe no
    /// llega a los diez kilobytes; el tope está para no reservar por lo que diga un archivo roto.
    public static let maximumLength = 1024 * 1024

    public init(values: [String: Value]) { self.values = values }

    public init?(_ bytes: [UInt8]) {
        // «\0PSF»: el cero delante es parte de la marca y se olvida con facilidad.
        guard bytes.count >= 0x14, PartitionFileSystem.matches(bytes, at: 0, [0x00, 0x50, 0x53, 0x46]) else {
            return nil
        }
        let dóndeLasClaves = Int(readUInt32(bytes, 0x08))
        let dóndeLosValores = Int(readUInt32(bytes, 0x0C))
        let cuántas = Int(readUInt32(bytes, 0x10))
        guard cuántas >= 0, cuántas <= 4096,
              dóndeLasClaves >= 0x14, dóndeLosValores >= dóndeLasClaves,
              dóndeLosValores <= bytes.count
        else { return nil }

        var leídas: [String: Value] = [:]
        for índice in 0..<cuántas {
            let entrada = 0x14 + índice * 0x10
            guard entrada + 0x10 <= bytes.count else { break }
            let dóndeLaClave = dóndeLasClaves + Int(readUInt16(bytes, entrada))
            let formato = readUInt16(bytes, entrada + 0x02)
            let cuánto = Int(readUInt32(bytes, entrada + 0x04))
            let dóndeElValor = dóndeLosValores + Int(readUInt32(bytes, entrada + 0x0C))

            guard let clave = ParamSFO.text(bytes, from: dóndeLaClave, limit: dóndeLosValores),
                  cuánto >= 0, dóndeElValor >= 0, dóndeElValor + cuánto <= bytes.count
            else { continue }

            switch formato {
            // 0x0404 es un entero de cuatro bytes. Los otros dos son texto: uno acaba en cero y el
            // otro no, y por eso el final se recorta en vez de darlo por hecho.
            case 0x0404:
                leídas[clave] = .number(readUInt32(bytes, dóndeElValor))
            default:
                let crudo = bytes[dóndeElValor..<dóndeElValor + cuánto].prefix { $0 != 0 }
                let valor = String(decoding: crudo, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !valor.isEmpty { leídas[clave] = .text(valor) }
            }
        }
        guard !leídas.isEmpty else { return nil }
        values = leídas
    }

    /// Lee el `PARAM.SFO` de un archivo suelto.
    public static func load(from url: URL) -> ParamSFO? {
        guard let datos = try? Data(contentsOf: url), datos.count <= maximumLength else { return nil }
        return ParamSFO([UInt8](datos))
    }

    // MARK: - Lo que se le pregunta

    public subscript(_ key: String) -> String? { values[key]?.text }
    public func number(_ key: String) -> UInt32? {
        if case .number(let valor) = values[key] { return valor }
        return nil
    }

    public var keys: [String] { values.keys.sorted() }
    public var isEmpty: Bool { values.isEmpty }

    /// El nombre del juego tal como lo escribió quien lo hizo. **No** el del archivo, que lo pone
    /// quien lo comparte y suele traer media docena de etiquetas entre corchetes.
    public var title: String? { self["TITLE"] }

    /// El identificador: `BLUS30443` en PS3, `CUSA01234` en PS4, `PCSE00123` en Vita. Es la
    /// identidad de verdad y con la que se busca cualquier cosa del juego.
    public var titleId: String? { self["TITLE_ID"] }

    /// La versión de la aplicación, `01.03`. En un parche es la que deja instalada.
    public var version: String? { self["APP_VER"] ?? self["VERSION"] }

    public var category: String? { self["CATEGORY"] }

    /// Qué es este contenido, traducido del campo de dos letras que usa Sony.
    ///
    /// Los códigos no son evidentes y conviene tenerlos escritos: `DG` es un juego de disco, `HG`
    /// uno bajado de la tienda, y **`GD` no es un juego: es un parche**. Confundir ese es fácil
    /// —parece «game data»— y deja al usuario intentando arrancar una actualización suelta, que no
    /// arranca porque no es un juego.
    public var kind: ContentKind {
        guard let bruto = category else { return .application }

        // **La caja de las letras decide, y decide cosas contrarias.** En PS3 y PSP los códigos van
        // en mayúscula y `GD` es un parche; en PS4 y Vita van en minúscula y `gd` es el juego. Es el
        // mismo par de letras significando lo contrario, y lo único que los separa en el archivo es
        // esto. Por eso se mira el valor tal cual llega y no una versión normalizada.
        switch bruto {
        case "gd", "gda", "gde": return .application   // PS4 y Vita: el juego
        case "gp": return .patch                       // PS4 y Vita: el parche
        case "ac": return .addOn
        default: break
        }

        switch bruto.uppercased() {
        // Juego, según de dónde salió: disco de PS3, descarga de la tienda, UMD de PSP.
        case "DG", "HG", "MG", "UG", "EG", "WG": return .application
        // `GD` **no** es un juego: es «game data», o sea una actualización. Parece lo contrario y
        // es el error fácil, que deja a alguien intentando arrancar un parche suelto.
        case "GD", "GP": return .patch
        case "AC": return .addOn
        default: return .other
        }
    }

    /// De qué máquina es, por la forma del identificador. Sony les puso prefijos distintos a cada
    /// generación, y eso identifica la consola sin mirar nada más.
    public var machineId: String? { ParamSFO.machineId(forTitleId: titleId) }

    /// - `BLUS`, `BLES`, `BCUS`, `NPUB`, `NPEB`… → PS3
    /// - `CUSA` → PS4
    /// - `PPSA` → PS5
    /// - `PCSE`, `PCSB`, `PCSA`, `PCSG`, `VLUS`, `VCJS`… → Vita
    /// - `UCUS`, `ULUS`, `ULES`, `NPUG`… → PSP
    public static func machineId(forTitleId titleId: String?) -> String? {
        guard let titleId, titleId.count >= 4 else { return nil }
        let prefijo = String(titleId.prefix(4)).uppercased()
        if prefijo == "CUSA" { return "ps4" }
        if prefijo == "PPSA" { return "ps5" }
        if prefijo.hasPrefix("PCS") || prefijo.hasPrefix("VLU") || prefijo.hasPrefix("VCJ") { return "vita" }
        if ["UCUS", "ULUS", "ULES", "UCES", "ULJM", "NPUG", "NPEG", "NPHG", "NPJG"].contains(prefijo) {
            return "psp"
        }
        if prefijo.hasPrefix("B") || prefijo.hasPrefix("NP") { return "ps3" }
        return nil
    }

    // MARK: - Lectura

    /// Una clave de la tabla: acaba en cero y no puede salirse de su tabla.
    private static func text(_ bytes: [UInt8], from offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < min(limit, bytes.count) else { return nil }
        let fin = min(limit, bytes.count)
        var final = offset
        while final < fin, bytes[final] != 0 { final += 1 }
        guard final > offset else { return nil }
        return String(decoding: bytes[offset..<final], as: UTF8.self)
    }
}
