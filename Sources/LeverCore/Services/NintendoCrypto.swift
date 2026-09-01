import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Los dos modos de AES con los que la consola híbrida cifra sus archivos.
///
/// No los trae ni CryptoKit ni el sistema: CryptoKit solo da los modos autenticados —GCM y
/// ChaCha— y aquí hacen falta los de disco, que no autentican nada porque tienen que poder leerse
/// por el medio. Así que se montan sobre el AES de bloque de CommonCrypto, que sí está.
///
/// **XTS es donde está la trampa.** El estándar numera cada sector con el byte de menos peso
/// primero; Nintendo lo numera al revés. Es la única diferencia entre las dos versiones, no da
/// ningún error, y lo que sale son 3072 bytes de basura con la pinta exacta de una cabecera
/// cifrada. Por eso el orden es un parámetro y no una suposición.
public enum NintendoCrypto {
    /// Lo que mide un sector en los formatos de esta consola.
    public static let sectorSize = 0x200

    /// AES de bloque, que es la pieza sobre la que se montan los dos modos.
    ///
    /// Guarda el contexto abierto en vez de abrir uno por bloque: un `.ncz` de ocho gigas son
    /// quinientos millones de bloques, y abrir y cerrar el cifrador en cada uno cuesta más que
    /// cifrar. Cifra el búfer entero de una vez —en ECB cada bloque va por su cuenta, así que se
    /// puede— y eso es lo que lo hace utilizable con archivos de verdad.
    public final class Block {
        private let context: CCCryptorRef?

        /// - Parameter forDecryption: ECB no es simétrico, así que hay que decir para qué lado.
        ///   Un modo montado encima —CTR— solo usa el de cifrar, incluso para descifrar.
        public init?(key: [UInt8], forDecryption: Bool = false) {
            guard key.count == 16 || key.count == 32 else { return nil }
            var creado: CCCryptorRef?
            let estado = key.withUnsafeBytes { llave in
                CCCryptorCreate(
                    CCOperation(forDecryption ? kCCDecrypt : kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    llave.baseAddress, key.count, nil, &creado
                )
            }
            guard estado == kCCSuccess, creado != nil else { return nil }
            context = creado
        }

        deinit { if let context { CCCryptorRelease(context) } }

        /// Cifra —o descifra— un múltiplo de dieciséis bytes, en el sitio.
        @discardableResult
        public func process(_ bytes: inout [UInt8]) -> Bool {
            guard !bytes.isEmpty, bytes.count % 16 == 0, let context else { return false }
            var salida = [UInt8](repeating: 0, count: bytes.count)
            var movidos = 0
            let estado = bytes.withUnsafeBytes { entrada in
                salida.withUnsafeMutableBytes { destino in
                    CCCryptorUpdate(
                        context, entrada.baseAddress, bytes.count,
                        destino.baseAddress, destino.count, &movidos
                    )
                }
            }
            guard estado == kCCSuccess, movidos == bytes.count else { return false }
            bytes = salida
            return true
        }
    }

    // MARK: - XTS

    /// Descifra en modo XTS, que es con el que va la cabecera de una pieza de contenido.
    ///
    /// - Parameters:
    ///   - key: treinta y dos bytes: los dieciséis primeros cifran y los otros dieciséis hacen el
    ///     ajuste. Partirlos al revés descifra sin quejarse y devuelve basura.
    ///   - firstSector: el número del sector en el que empieza `data`. La cabecera de una pieza
    ///     empieza en el cero.
    ///   - bigEndianTweak: el orden con el que se escribe ese número. Nintendo usa el de más peso
    ///     primero, que **no** es el del estándar.
    public static func xtsDecrypt(
        _ data: [UInt8], key: [UInt8], sectorSize: Int = NintendoCrypto.sectorSize,
        firstSector: Int = 0, bigEndianTweak: Bool = true
    ) -> [UInt8]? {
        transformXts(data, key: key, sectorSize: sectorSize, firstSector: firstSector,
                     bigEndianTweak: bigEndianTweak, decrypting: true)
    }

    /// Cifra en modo XTS. Hace falta para poder fabricar una cabecera en las pruebas: sin esto no
    /// habría forma de comprobar el descifrado sin el archivo de alguien.
    public static func xtsEncrypt(
        _ data: [UInt8], key: [UInt8], sectorSize: Int = NintendoCrypto.sectorSize,
        firstSector: Int = 0, bigEndianTweak: Bool = true
    ) -> [UInt8]? {
        transformXts(data, key: key, sectorSize: sectorSize, firstSector: firstSector,
                     bigEndianTweak: bigEndianTweak, decrypting: false)
    }

    private static func transformXts(
        _ data: [UInt8], key: [UInt8], sectorSize: Int, firstSector: Int,
        bigEndianTweak: Bool, decrypting: Bool
    ) -> [UInt8]? {
        guard key.count == 32, sectorSize > 0, sectorSize % 16 == 0,
              !data.isEmpty, data.count % sectorSize == 0,
              let datos = Block(key: Array(key[0..<16]), forDecryption: decrypting),
              let ajuste = Block(key: Array(key[16..<32]))
        else { return nil }

        var salida = data
        for sector in 0..<(data.count / sectorSize) {
            var marca = tweakBytes(firstSector + sector, bigEndian: bigEndianTweak)
            // La marca del sector se cifra siempre, se descifre o no el contenido: es un valor
            // derivado del número de sector, no parte del mensaje.
            guard ajuste.process(&marca) else { return nil }

            let base = sector * sectorSize
            for bloque in stride(from: 0, to: sectorSize, by: 16) {
                let desde = base + bloque
                var trozo = [UInt8](salida[desde..<desde + 16])
                for índice in 0..<16 { trozo[índice] ^= marca[índice] }
                guard datos.process(&trozo) else { return nil }
                for índice in 0..<16 { trozo[índice] ^= marca[índice] }
                salida.replaceSubrange(desde..<desde + 16, with: trozo)
                marca = multiplyByX(marca)
            }
        }
        return salida
    }

    /// El número de sector escrito en dieciséis bytes.
    public static func tweakBytes(_ sector: Int, bigEndian: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let valor = UInt64(bitPattern: Int64(sector))
        for índice in 0..<8 {
            let byte = UInt8((valor >> (8 * índice)) & 0xFF)
            bytes[bigEndian ? 15 - índice : índice] = byte
        }
        return bytes
    }

    /// Multiplica la marca por x en el cuerpo de Galois de 128 bits, que es como XTS pasa de un
    /// bloque al siguiente. Es un desplazamiento de un bit hacia arriba y, si se sale por arriba,
    /// el polinomio reductor: `x¹²⁸ + x⁷ + x² + x + 1`, o sea 0x87 sobre el primer byte.
    public static func multiplyByX(_ tweak: [UInt8]) -> [UInt8] {
        var salida = tweak
        var acarreo: UInt8 = 0
        for índice in 0..<16 {
            let siguiente = (salida[índice] >> 7) & 1
            salida[índice] = (salida[índice] << 1) | acarreo
            acarreo = siguiente
        }
        if acarreo != 0 { salida[0] ^= 0x87 }
        return salida
    }

    // MARK: - CTR

    /// Cifra —o descifra, que es lo mismo— en modo contador.
    ///
    /// En CTR no se cifra el mensaje: se cifra una cuenta y se hace un XOR con el mensaje. Por eso
    /// la misma función sirve para los dos sentidos, y por eso rehacer un `.ncz` es exactamente el
    /// mismo trabajo que abrirlo.
    ///
    /// - Parameter counter: los dieciséis bytes de la cuenta inicial. Los ocho últimos son el
    ///   número de bloque y suben de uno en uno; los ocho primeros no se tocan.
    public static func ctr(_ data: [UInt8], key: [UInt8], counter: [UInt8]) -> [UInt8]? {
        guard counter.count == 16, let cifrador = Block(key: key) else { return nil }
        var salida = data
        var cuenta = counter
        var hecho = 0

        // Se preparan muchas cuentas de golpe y se cifran de una vez. Con un archivo de gigas,
        // una llamada por bloque de dieciséis bytes es la diferencia entre segundos y minutos.
        let porTanda = 4096
        while hecho < salida.count {
            let bloques = min(porTanda, (salida.count - hecho + 15) / 16)
            var flujo = [UInt8](repeating: 0, count: bloques * 16)
            for bloque in 0..<bloques {
                flujo.replaceSubrange(bloque * 16..<bloque * 16 + 16, with: cuenta)
                cuenta = increment(cuenta)
            }
            guard cifrador.process(&flujo) else { return nil }

            let cuántos = min(flujo.count, salida.count - hecho)
            for índice in 0..<cuántos { salida[hecho + índice] ^= flujo[índice] }
            hecho += cuántos
        }
        return salida
    }

    /// Suma uno a la cuenta, por la parte de abajo y hacia arriba.
    public static func increment(_ counter: [UInt8]) -> [UInt8] {
        var salida = counter
        for índice in (8..<16).reversed() {
            salida[índice] &+= 1
            if salida[índice] != 0 { break }
        }
        return salida
    }

    /// La cuenta con la que empieza una sección de una pieza de contenido.
    ///
    /// Los ocho primeros bytes salen de la propia sección; los ocho últimos son el desplazamiento
    /// dentro de ella, dividido entre dieciséis, con el byte de más peso primero. Un desplazamiento
    /// mal puesto no da error: descifra desde el sitio equivocado.
    public static func counter(prefix: [UInt8], offset: Int64) -> [UInt8]? {
        guard prefix.count >= 8 else { return nil }
        var cuenta = Array(prefix[0..<8]) + [UInt8](repeating: 0, count: 8)
        let bloque = UInt64(bitPattern: offset) >> 4
        for índice in 0..<8 { cuenta[15 - índice] = UInt8((bloque >> (8 * índice)) & 0xFF) }
        return cuenta
    }
}
