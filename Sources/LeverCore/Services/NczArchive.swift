import Foundation

/// Una sección de la pieza original, con la llave que la volvía a dejar como estaba.
///
/// El compresor de la comunidad no comprime la pieza tal cual: primero la **descifra**, porque los
/// bytes cifrados no se parecen a nada y no hay compresor que los encoja. Al hacerlo se guarda la
/// llave de cada sección dentro del propio archivo, así que rehacer la pieza no necesita las llaves
/// del usuario para nada: la información viaja dentro.
public struct NczSection: Equatable, Sendable {
    /// Dónde empieza la sección dentro de la pieza rehecha.
    public let offset: Int64
    public let size: Int64
    /// Cómo iba cifrada: 3 es el modo contador, que es el de casi todo. 0 y 1 son sin cifrar.
    public let cryptoType: UInt64
    public let key: [UInt8]
    public let counter: [UInt8]

    public init(offset: Int64, size: Int64, cryptoType: UInt64, key: [UInt8], counter: [UInt8]) {
        self.offset = offset
        self.size = size
        self.cryptoType = cryptoType
        self.key = key
        self.counter = counter
    }

    /// Si hay que volver a cifrarla al rehacer la pieza. Las que no lo estaban se copian tal cual.
    public var isEncrypted: Bool { cryptoType == 3 || cryptoType == 4 }

    public var end: Int64 { offset + size }
}

/// Una pieza de contenido comprimida, tal como la deja el compresor de la comunidad.
///
/// Por dentro es: los primeros 0x4000 bytes de la pieza original **sin tocar** —ahí cabe entera la
/// cabecera, y por eso un paquete comprimido se puede leer igual que uno normal—, la tabla de
/// secciones con sus llaves, opcionalmente un índice de bloques, y detrás el flujo de zstd.
///
/// Rehacerla es deshacer eso mismo al revés: descomprimir y volver a cifrar sección por sección.
/// El resultado es idéntico byte a byte a la pieza de la que salió, y eso se puede comprobar
/// porque la cabecera lleva el tamaño y los hashes de la original.
public struct NczArchive: Equatable, Sendable {
    /// Lo que el compresor deja tal cual al principio de cada pieza.
    public static let plainPrefix: Int64 = 0x4000

    public let sections: [NczSection]
    /// El exponente del tamaño de bloque, cuando el archivo va por bloques. `nil` es «sólido»: un
    /// único flujo que hay que leer entero desde el principio, sin poder saltar a la mitad.
    public let blockSizeExponent: Int?
    public let decompressedSize: Int64?
    /// Dónde empieza el flujo comprimido, ya en coordenadas del archivo.
    public let payloadOffset: Int64

    /// Si se puede empezar a leer por la mitad. Los archivos por bloques sí; los sólidos no, y eso
    /// decide si una descompresión se puede reanudar o hay que rehacerla entera.
    public var allowsRandomAccess: Bool { blockSizeExponent != nil }

    /// Lo que va a medir la pieza rehecha.
    ///
    /// **El desplazamiento de una sección ya cuenta desde el principio de la pieza**, trozo intacto
    /// incluido: la primera empieza en 0x4000, no en cero. Sumarle otra vez el trozo intacto da una
    /// pieza 16 KB más larga de lo que toca, y el paquete entero queda descolocado a partir de ahí.
    public var rebuiltSize: Int64 {
        let porLasSecciones = sections.map(\.end).max()
        let porElÍndice = decompressedSize.map { NczArchive.plainPrefix + $0 }
        return max(NczArchive.plainPrefix, porLasSecciones ?? porElÍndice ?? 0)
    }

    // MARK: - Leer la cabecera

    public static func read(_ handle: FileHandle, at offset: Int64) -> NczArchive? {
        guard offset >= 0 else { return nil }
        // La tabla de secciones nunca es grande —son 0x60 bytes por sección y hay cuatro a lo
        // sumo—, pero el índice de bloques sí puede serlo. Se lee un trozo generoso de una vez en
        // vez de ir campo a campo, que serían veinte lecturas.
        guard (try? handle.seek(toOffset: UInt64(offset + plainPrefix))) != nil,
              let datos = try? handle.read(upToCount: 0x10000), datos.count >= 0x10
        else { return nil }
        return parse(header: [UInt8](datos), streamStart: offset + plainPrefix)
    }

    /// Interpreta la cabecera. `streamStart` es dónde empieza la cabecera dentro del archivo, para
    /// poder decir después dónde empiezan los datos comprimidos.
    public static func parse(header: [UInt8], streamStart: Int64) -> NczArchive? {
        guard PartitionFileSystem.matches(header, at: 0, Array("NCZSECTN".utf8)) else { return nil }
        let cuántas = Int(readUInt64(header, 8))
        // Una pieza tiene cuatro secciones como mucho, que son las que caben en su cabecera. Un
        // número mayor es una cabecera rota, y reservar por él es reservar por lo que diga el
        // archivo.
        guard cuántas > 0, cuántas <= 64 else { return nil }

        // Cada sección ocupa 0x40: cuatro enteros de ocho —desplazamiento, tamaño, modo y un
        // relleno— y detrás la llave y la cuenta, de dieciséis cada una.
        let tamañoDeSección = 0x40
        var secciones: [NczSection] = []
        for índice in 0..<cuántas {
            let base = 16 + índice * tamañoDeSección
            guard base + tamañoDeSección <= header.count else { return nil }
            secciones.append(NczSection(
                offset: Int64(bitPattern: readUInt64(header, base)),
                size: Int64(bitPattern: readUInt64(header, base + 0x08)),
                cryptoType: readUInt64(header, base + 0x10),
                // El relleno de 0x18 no se lee: está para alinear la llave a dieciséis.
                key: Array(header[(base + 0x20)..<(base + 0x30)]),
                counter: Array(header[(base + 0x30)..<(base + 0x40)])
            ))
        }

        // Detrás de las secciones puede venir el índice de bloques. Cuando no viene, el flujo es
        // sólido y empieza justo ahí.
        var dónde = 16 + cuántas * tamañoDeSección
        var exponente: Int?
        var tamañoFinal: Int64?
        if PartitionFileSystem.matches(header, at: dónde, Array("NCZBLOCK".utf8)) {
            guard dónde + 0x18 <= header.count else { return nil }
            exponente = Int(header[dónde + 0x0B])
            let cuántosBloques = Int(readUInt32(header, dónde + 0x0C))
            tamañoFinal = Int64(bitPattern: readUInt64(header, dónde + 0x10))
            guard cuántosBloques >= 0, cuántosBloques <= 0x100000 else { return nil }
            dónde += 0x18 + cuántosBloques * 4
        }
        guard dónde <= header.count else { return nil }

        return NczArchive(
            sections: secciones, blockSizeExponent: exponente,
            decompressedSize: tamañoFinal, payloadOffset: streamStart + Int64(dónde)
        )
    }

    public init(sections: [NczSection], blockSizeExponent: Int?, decompressedSize: Int64?, payloadOffset: Int64) {
        self.sections = sections
        self.blockSizeExponent = blockSizeExponent
        self.decompressedSize = decompressedSize
        self.payloadOffset = payloadOffset
    }

    // MARK: - Rehacer

    /// Vuelve a cifrar un trozo de la pieza, sabiendo en qué punto de la pieza está.
    ///
    /// **El trozo puede caer a caballo entre dos secciones**, y cada una tiene su llave: hay que
    /// partirlo por la frontera. Cifrar el trozo entero con la llave de la primera es el fallo que
    /// deja la pieza rehecha correcta hasta la mitad exacta de un juego, que es donde se nota.
    ///
    /// - Parameter offset: dónde empieza `chunk` dentro de la pieza rehecha, contando el trozo
    ///   intacto del principio.
    public func encrypt(_ chunk: [UInt8], at offset: Int64) -> [UInt8] {
        var salida = chunk
        for sección in sections where sección.isEncrypted {
            let desde = max(offset, sección.offset)
            let hasta = min(offset + Int64(chunk.count), sección.end)
            guard desde < hasta else { continue }

            let dentroDelTrozo = Int(desde - offset)
            let cuántos = Int(hasta - desde)
            // La cuenta no empieza en cero: empieza donde esté este trozo dentro de la sección.
            guard let cuenta = NintendoCrypto.counter(prefix: sección.counter, offset: desde),
                  let cifrado = NintendoCrypto.ctr(
                      Array(salida[dentroDelTrozo..<dentroDelTrozo + cuántos]),
                      key: sección.key, counter: cuenta
                  )
            else { continue }
            salida.replaceSubrange(dentroDelTrozo..<dentroDelTrozo + cuántos, with: cifrado)
        }
        return salida
    }
}
