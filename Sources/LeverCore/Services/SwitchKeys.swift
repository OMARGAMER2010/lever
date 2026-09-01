import Foundation

/// Los archivos de llaves que hace falta tener y que Lever no puede darte.
///
/// Es el mismo caso que la BIOS de PlayStation, y se trata igual: se dice antes, con el nombre
/// exacto del archivo, en vez de dejar que el emulador arranque y se quede en negro. La diferencia
/// es que aquí ni siquiera existe una descarga que ofrecer: estas llaves salen de una consola, se
/// sacan con la consola en la mano, y no hay ninguna copia legítima circulando.
public enum SwitchKeyFile {
    /// Sin esto no se puede leer nada cifrado. Es el archivo grande, el de las llaves del sistema.
    public static let required = ["prod.keys"]
    /// Opcional: llaves de títulos concretos. Los volcados modernos las traen en su ticket, así
    /// que casi nunca hace falta.
    public static let optional = ["title.keys"]
    public static let all = required + optional
}

/// Las llaves del sistema, leídas del archivo del usuario.
///
/// **Nunca viajan dentro de Lever y nunca se copian a ningún sitio de Lever.** Se leen del archivo
/// que el usuario señale, se usan en memoria y se olvidan al cerrar. Por eso este tipo no se puede
/// codificar ni imprimir: su `description` enseña cuántas llaves hay y cómo se llaman, jamás lo que
/// valen. Un valor en el registro de actividad —que el usuario copia y pega para pedir ayuda— sería
/// justo la forma de que estas llaves acabasen publicadas.
public struct SwitchKeys: Sendable, CustomStringConvertible {
    private let values: [String: [UInt8]]

    /// Lee el formato del archivo: una línea por llave, `nombre = valor en hexadecimal`.
    ///
    /// Se ignoran las líneas vacías, los comentarios y las que no cuadren, en vez de rechazar el
    /// archivo entero: estos archivos se editan a mano y se juntan a trozos, y una línea rota no
    /// tiene por qué invalidar las trescientas buenas.
    public init(text: String) {
        var leídas: [String: [UInt8]] = [:]
        for línea in text.split(whereSeparator: \.isNewline) {
            let limpia = línea.trimmingCharacters(in: .whitespaces)
            guard !limpia.isEmpty, !limpia.hasPrefix("#"), !limpia.hasPrefix(";") else { continue }
            let partes = limpia.split(separator: "=", maxSplits: 1)
            guard partes.count == 2 else { continue }
            let nombre = partes[0].trimmingCharacters(in: .whitespaces).lowercased()
            let valor = partes[1].trimmingCharacters(in: .whitespaces)
            guard !nombre.isEmpty, let bytes = SwitchKeys.hex(valor) else { continue }
            leídas[nombre] = bytes
        }
        values = leídas
    }

    public init(values: [String: [UInt8]]) { self.values = values }

    public static func load(from url: URL) -> SwitchKeys? {
        guard let datos = try? Data(contentsOf: url), datos.count < 4 * 1024 * 1024 else { return nil }
        let llaves = SwitchKeys(text: String(decoding: datos, as: UTF8.self))
        return llaves.isEmpty ? nil : llaves
    }

    // MARK: - Las llaves que se usan

    /// La que descifra la cabecera de una pieza de contenido. Mide 32 bytes porque son dos: la de
    /// cifrado y la del ajuste, que es como funciona el modo XTS.
    public var headerKey: [UInt8]? { key("header_key", length: 32) }

    /// La que envuelve la llave de contenido de un título de la tienda.
    ///
    /// Hay una por generación de llaves y por índice de aplicación, y la generación sale de la
    /// propia pieza. Coger la equivocada no da error: da bytes descifrados que no son nada.
    public func keyAreaKey(applicationIndex: Int, generation: Int) -> [UInt8]? {
        let familia = ["application", "ocean", "system"]
        guard applicationIndex >= 0, applicationIndex < familia.count else { return nil }
        return key(String(format: "key_area_key_%@_%02x", familia[applicationIndex], generation), length: 16)
    }

    /// La que descifra la llave de título que viene dentro del ticket.
    public func titleKek(generation: Int) -> [UInt8]? {
        key(String(format: "titlekek_%02x", generation), length: 16)
    }

    public func key(_ name: String, length: Int) -> [UInt8]? {
        guard let valor = values[name.lowercased()], valor.count == length else { return nil }
        return valor
    }

    public var isEmpty: Bool { values.isEmpty }
    /// Si sirven para lo mínimo. Un archivo con doscientas llaves pero sin `header_key` no permite
    /// leer nada, y eso hay que poder decirlo antes de intentarlo.
    public var isUsable: Bool { headerKey != nil }
    /// Cuántas generaciones de llaves de contenido trae, que es lo que marca hasta qué versión del
    /// sistema se puede abrir un juego. Un archivo viejo abre los juegos viejos y nada más.
    public var keyGenerations: Int {
        (0..<0x20).filter { keyAreaKey(applicationIndex: 0, generation: $0) != nil }.count
    }

    /// Los nombres, ordenados. **Nunca los valores.**
    public var names: [String] { values.keys.sorted() }

    public var description: String { "SwitchKeys(\(values.count) llaves)" }

    // MARK: - Dónde están

    /// Las carpetas donde los emuladores de esta consola guardan sus llaves en un Mac.
    ///
    /// Se mira ahí antes de pedirle nada al usuario: quien ya tiene el emulador funcionando ya las
    /// puso en su sitio, y volver a pedírselas sería no haber mirado.
    public static func searchFolders(fileManager: FileManager = .default) -> [URL] {
        let soporte = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        // La línea de Ryujinx y sus bifurcaciones guarda en `system`; la de yuzu en `keys`. Se
        // prueban las dos porque el usuario puede tener cualquiera de las que siguen vivas.
        return [
            soporte.appendingPathComponent("Ryujinx/system", isDirectory: true),
            soporte.appendingPathComponent("Ryubing/system", isDirectory: true),
            soporte.appendingPathComponent("Sudachi/keys", isDirectory: true),
            soporte.appendingPathComponent("Citron/keys", isDirectory: true),
            soporte.appendingPathComponent("Eden/keys", isDirectory: true),
            soporte.appendingPathComponent("yuzu/keys", isDirectory: true)
        ]
    }

    /// El `prod.keys` que haya, mirando primero donde el usuario lo señalara.
    public static func locate(
        preferring custom: URL? = nil, fileManager: FileManager = .default
    ) -> URL? {
        if let custom, fileManager.isReadableFile(atPath: custom.path) { return custom }
        for carpeta in searchFolders(fileManager: fileManager) {
            let archivo = carpeta.appendingPathComponent("prod.keys")
            if fileManager.isReadableFile(atPath: archivo.path) { return archivo }
        }
        return nil
    }

    // MARK: - Hexadecimal

    /// Convierte el texto de una llave a bytes. Devuelve `nil` si sobra algo que no sea un dígito
    /// hexadecimal: un valor a medio copiar es peor que ninguno, porque descifra y da basura.
    public static func hex(_ text: String) -> [UInt8]? {
        let dígitos = Array(text.utf8)
        guard dígitos.count >= 2, dígitos.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(dígitos.count / 2)
        var índice = 0
        while índice < dígitos.count {
            guard let alto = nibble(dígitos[índice]), let bajo = nibble(dígitos[índice + 1]) else { return nil }
            bytes.append(alto << 4 | bajo)
            índice += 2
        }
        return bytes
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30            // 0-9
        case 0x61...0x66: return byte - 0x61 + 10       // a-f
        case 0x41...0x46: return byte - 0x41 + 10       // A-F
        default: return nil
        }
    }
}
