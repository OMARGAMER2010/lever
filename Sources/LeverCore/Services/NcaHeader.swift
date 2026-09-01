import Foundation

/// La cabecera de una pieza de contenido, ya descifrada.
///
/// Es la única fuente que no se puede discutir: la escribió Nintendo y va firmada. El nombre del
/// archivo es un hash, el `cnmt.xml` lo genera una herramienta de terceros y el ticket solo dice a
/// qué título da permiso; esto dice qué **es** la pieza, de qué título, cuánto ocupa y con qué
/// generación de llaves se cifró.
///
/// Va cifrada en AES-XTS con `header_key`, así que sin las llaves del usuario no hay nada que leer
/// aquí. Es la línea exacta entre lo que Lever puede decir con el archivo solo y lo que necesita
/// que el usuario ponga de su parte.
public struct NcaHeader: Equatable, Sendable {
    /// Lo que la pieza contiene. Solo `control` lleva el nombre y el icono del juego; `meta` lleva
    /// la lista de piezas, y `program` el juego en sí.
    public enum ContentType: UInt8, Equatable, Sendable {
        case program = 0
        case meta = 1
        case control = 2
        case manual = 3
        case data = 4
        case publicData = 5
    }

    /// La versión del formato: 3 en todo lo moderno, 2 y 0 en cosas de los primeros años.
    public let version: Int
    /// De dónde salió: 0 la tienda, 1 un cartucho. Distinto contenido, distinto envoltorio.
    public let distributionType: UInt8
    public let contentType: ContentType
    public let contentSize: Int64
    public let titleId: UInt64
    public let contentIndex: UInt32
    /// La versión del kit de desarrollo con el que se compiló, empaquetada en cuatro números.
    public let sdkVersion: UInt32
    /// Con qué generación de llaves se cifró. **Este es el número que decide si un `prod.keys`
    /// sirve para un juego**: uno de hace dos años abre los juegos de hace dos años y nada más, y
    /// el síntoma de quedarse corto es un emulador que no arranca sin decir por qué.
    public let keyGeneration: Int
    /// Los dieciséis bytes que dicen que el contenido va cifrado con una llave de título, que sale
    /// del ticket. En cero cuando la pieza va con llave de sistema.
    public let rightsId: [UInt8]

    /// Lo que ocupa la cabecera entera: el bloque firmado y las cuatro cabeceras de sistema de
    /// archivos que van detrás. Se descifra de una vez porque es un solo flujo XTS.
    public static let length = 0xC00

    public var hasRightsId: Bool { rightsId.contains { $0 != 0 } }

    /// La versión del kit tal como se escribe: `17.5.0.0`.
    public var sdkVersionText: String {
        "\(sdkVersion >> 24).\((sdkVersion >> 16) & 0xFF).\((sdkVersion >> 8) & 0xFF).\(sdkVersion & 0xFF)"
    }

    // MARK: - Leer

    /// Lee y descifra la cabecera de la pieza que empieza en `offset`.
    public static func read(_ handle: FileHandle, at offset: Int64, keys: SwitchKeys) -> NcaHeader? {
        guard offset >= 0, let llave = keys.headerKey else { return nil }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let datos = try? handle.read(upToCount: length), datos.count == length
        else { return nil }
        return read(encrypted: [UInt8](datos), headerKey: llave)
    }

    public static func read(encrypted: [UInt8], headerKey: [UInt8]) -> NcaHeader? {
        // Sectores de 0x200 numerados desde cero, y con el número escrito al revés de como lo
        // escribe el estándar. Con el orden del estándar esto descifra igual y sale basura.
        guard let claro = NintendoCrypto.xtsDecrypt(
            encrypted, key: headerKey, firstSector: 0, bigEndianTweak: true
        ) else { return nil }
        return decode(claro)
    }

    /// Interpreta una cabecera ya descifrada. Aparte del descifrado para poder probar las dos
    /// cosas por separado.
    public static func decode(_ header: [UInt8]) -> NcaHeader? {
        guard header.count >= 0x340 else { return nil }
        // La marca está en 0x200 y no al principio: delante van dos firmas de 256 bytes. Es el
        // único sitio donde se puede comprobar que las llaves eran las buenas —si no lo son, aquí
        // no hay ninguna marca— y por eso descifrar con la llave equivocada se nota, en vez de
        // devolver una cabecera inventada.
        guard PartitionFileSystem.matches(header, at: 0x200, Array("NCA".utf8)) else { return nil }
        guard let versión = Int(String(UnicodeScalar(header[0x203]))), (0...3).contains(versión) else {
            return nil
        }
        guard let tipo = ContentType(rawValue: header[0x205]) else { return nil }

        // La generación de llaves se guarda en dos sitios por razones históricas: el campo viejo se
        // quedó pequeño y añadieron otro. Manda el mayor de los dos, y a partir del uno va
        // desplazada en uno. Leer solo uno de los campos da la generación equivocada en todo lo
        // publicado desde 2018.
        let vieja = Int(header[0x206])
        let nueva = Int(header[0x220])
        var generación = max(vieja, nueva)
        if generación > 0 { generación -= 1 }

        return NcaHeader(
            version: versión,
            distributionType: header[0x204],
            contentType: tipo,
            contentSize: Int64(bitPattern: readUInt64(header, 0x208)),
            titleId: readUInt64(header, 0x210),
            contentIndex: readUInt32(header, 0x218),
            sdkVersion: readUInt32(header, 0x21C),
            keyGeneration: generación,
            rightsId: Array(header[0x230..<0x240])
        )
    }

    public init(
        version: Int, distributionType: UInt8, contentType: ContentType, contentSize: Int64,
        titleId: UInt64, contentIndex: UInt32, sdkVersion: UInt32, keyGeneration: Int,
        rightsId: [UInt8]
    ) {
        self.version = version
        self.distributionType = distributionType
        self.contentType = contentType
        self.contentSize = contentSize
        self.titleId = titleId
        self.contentIndex = contentIndex
        self.sdkVersion = sdkVersion
        self.keyGeneration = keyGeneration
        self.rightsId = rightsId
    }
}
