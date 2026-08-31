import Foundation

/// Reconoce de qué máquina es un archivo de juego leyendo su cabecera.
///
/// La extensión es una pista, no una prueba: `.bin` lo usan media docena de consolas, `.chd` otras
/// tantas, y un archivo renombrado se cuela sin que nadie se entere hasta que el emulador se queda
/// en negro. Casi todas las consolas marcan sus ROMs —el «NES» del principio, el logotipo de
/// Nintendo que la Game Boy comprueba al arrancar, el «SEGA» de la Mega Drive—, así que se mira
/// ahí primero y solo se cae en la extensión cuando la máquina no marca nada.
///
/// Es el mismo criterio que con un `.exe` o un `.apk`: lo que decide está dentro del archivo.
public enum RomInspector {
    /// Lo que hay que leer del principio para reconocer cualquiera de las cabeceras contempladas.
    /// La más lejana es la de Master System, a 0x7FF0.
    private static let headerLength = 0x8000 + 0x40

    public static func inspect(_ url: URL) -> RomFacts {
        let bytes = (try? Data(contentsOf: url, options: .mappedIfSafe)).map {
            [UInt8]($0.prefix(headerLength))
        } ?? []
        let tamaño = url.fileSizeInBytes ?? 0
        let extensión = url.pathExtension.lowercased()

        if let (plataforma, nombre) = identify(header: bytes, fileSize: tamaño) {
            return RomFacts(platform: plataforma, evidence: .header, internalName: nombre, bytes: tamaño)
        }

        // Sin marca reconocible queda la extensión. Cuando encaja con más de una máquina no se
        // elige a ciegas: se devuelve la primera y se dice que la prueba es floja, porque es lo
        // que hay que enseñar al usuario para que pueda corregirlo.
        let candidatas = RetroPlatforms.candidates(forExtension: extensión)
        guard let primera = candidatas.first else { return RomFacts(bytes: tamaño) }
        return RomFacts(platform: primera, evidence: .fileExtension, bytes: tamaño)
    }

    /// La máquina y, si la cabecera lo lleva, el nombre que el autor escribió dentro.
    static func identify(header: [UInt8], fileSize: Int64) -> (RetroPlatform, String?)? {
        func plataforma(_ id: String) -> RetroPlatform? { RetroPlatforms.platform(id: id) }

        // ── NES ─────────────────────────────────────────────────────────────
        // «NES» y un fin de fichero. Es la cabecera iNES, que no lleva título dentro.
        if matches(header, at: 0, [0x4E, 0x45, 0x53, 0x1A]), let nes = plataforma("nes") {
            return (nes, nil)
        }

        // ── Game Boy y Game Boy Color ───────────────────────────────────────
        // El logotipo de Nintendo que la consola comprueba al arrancar: si no cuadra, la Game Boy
        // se niega a ejecutar el cartucho. Por eso está en todas las ROMs sin excepción.
        if matches(header, at: 0x104, nintendoLogo), let gb = plataforma("gb") {
            return (gb, text(header, from: 0x134, length: 16))
        }

        // ── Game Boy Advance ────────────────────────────────────────────────
        // Su logotipo va al principio y lleva además una marca fija en 0xB2.
        if matches(header, at: 0x04, gbaLogo), value(header, 0xB2) == 0x96, let gba = plataforma("gba") {
            return (gba, text(header, from: 0xA0, length: 12))
        }

        // ── Nintendo 64 ─────────────────────────────────────────────────────
        // Tres marcas para lo mismo: la ROM circula en tres órdenes de bytes distintos, y el
        // volcado dice cuál es. El núcleo los acepta todos.
        for marca in [[0x80, 0x37, 0x12, 0x40], [0x37, 0x80, 0x40, 0x12], [0x40, 0x12, 0x37, 0x80]]
        where matches(header, at: 0, marca.map(UInt8.init)) {
            guard let n64 = plataforma("n64") else { break }
            return (n64, text(header, from: 0x20, length: 20))
        }

        // ── Mega Drive ──────────────────────────────────────────────────────
        if let mega = plataforma("megadrive"),
           let cabecera = text(header, from: 0x100, length: 16),
           cabecera.hasPrefix("SEGA") {
            return (mega, text(header, from: 0x120, length: 48))
        }

        // ── Master System y Game Gear ───────────────────────────────────────
        // «TMR SEGA», que puede estar en tres sitios según el tamaño del cartucho.
        for sitio in [0x7FF0, 0x3FF0, 0x1FF0]
        where matches(header, at: sitio, Array("TMR SEGA".utf8)) {
            guard let sms = plataforma("sms") else { break }
            return (sms, nil)
        }

        // ── Nintendo DS ─────────────────────────────────────────────────────
        // El CRC del logotipo, que en una ROM buena vale siempre 0xCF56.
        if value(header, 0x15C) == 0x56, value(header, 0x15D) == 0xCF, let nds = plataforma("nds") {
            return (nds, text(header, from: 0x00, length: 12))
        }

        // ── Nintendo 3DS ────────────────────────────────────────────────────
        if matches(header, at: 0x100, Array("NCSD".utf8)), let tres = plataforma("3ds") {
            return (tres, nil)
        }

        // ── Super Nintendo ──────────────────────────────────────────────────
        // No tiene marca: se reconoce por la comprobación que la propia cabecera lleva —la suma y
        // su complemento tienen que sumar 0xFFFF— probada en los dos sitios donde puede estar,
        // que es lo que distingue una ROM con cabecera de volcado de una sin ella.
        if let snes = plataforma("snes") {
            for base in [0x7FC0, 0xFFC0] where hasSnesChecksum(header, at: base) {
                return (snes, text(header, from: base, length: 21))
            }
        }

        return nil
    }

    // MARK: - Lectura

    /// Los primeros ocho bytes del logotipo de Nintendo. Con ocho basta para no confundirse y
    /// evita depender de que el volcado traiga el logotipo entero intacto.
    private static let nintendoLogo: [UInt8] = [0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B]
    private static let gbaLogo: [UInt8] = [0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21]

    private static func matches(_ bytes: [UInt8], at offset: Int, _ pattern: [UInt8]) -> Bool {
        guard offset >= 0, offset + pattern.count <= bytes.count else { return false }
        for (índice, esperado) in pattern.enumerated() where bytes[offset + índice] != esperado {
            return false
        }
        return true
    }

    private static func value(_ bytes: [UInt8], _ offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    /// Un texto de la cabecera, recortado. Vienen rellenos con espacios o con ceros, y a veces con
    /// bytes que no son de ningún alfabeto: esos se descartan en vez de enseñar basura.
    static func text(_ bytes: [UInt8], from offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= bytes.count else { return nil }
        let crudo = bytes[offset..<offset + length].prefix { $0 != 0 }
        guard crudo.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let texto = String(decoding: crudo, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return texto.isEmpty ? nil : texto
    }

    /// La comprobación interna de una ROM de Super Nintendo: en la cabecera van la suma y su
    /// complemento, y sumados dan 0xFFFF. Es lo único que distingue una cabecera de verdad de
    /// veintiún bytes cualesquiera.
    static func hasSnesChecksum(_ bytes: [UInt8], at base: Int) -> Bool {
        let complemento = base + 0x1C
        let suma = base + 0x1E
        guard suma + 1 < bytes.count else { return false }
        let a = Int(bytes[complemento]) | (Int(bytes[complemento + 1]) << 8)
        let b = Int(bytes[suma]) | (Int(bytes[suma + 1]) << 8)
        // Una cabecera vacía cumpliría 0x0000 + 0xFFFF, así que se descarta ese caso.
        return a + b == 0xFFFF && a != 0 && b != 0
    }
}
