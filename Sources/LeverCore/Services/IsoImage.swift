import Foundation

/// Lo justo del sistema de archivos de un CD o un DVD para encontrar un archivo dentro y sacarlo.
///
/// Hace falta porque casi toda la familia PlayStation viaja en imágenes de disco: el `SYSTEM.CNF`
/// que identifica un juego de PS2, el `PARAM.SFO` de uno de PS3 o de PSP. Sin entrar en la imagen,
/// de un `.iso` de cuatro gigas solo se sabe que pesa cuatro gigas.
///
/// **Un sector no siempre mide 2048 bytes.** Un `.iso` sí, pero un volcado en crudo —los `.bin` que
/// vienen con su `.cue`— guarda 2352 por sector: 2048 de datos y el resto de sincronismo y
/// corrección de errores. Leer uno de esos como si fuera lo otro no da ningún error: da bytes
/// desplazados que no son nada. Por eso el tamaño se detecta y no se supone.
public final class IsoImage {
    /// Lo que de verdad son datos dentro de un sector, mida lo que mida el sector.
    public static let userDataSize = 2048
    /// El descriptor de volumen está siempre en el sector 16. Antes van dieciséis sectores en
    /// blanco que el estándar reserva para el arranque.
    public static let primaryVolumeSector = 16

    /// Cuánto ocupa un sector entero en el archivo.
    public let sectorSize: Int
    /// A cuántos bytes del principio de cada sector empiezan los datos.
    public let dataOffset: Int

    private let handle: FileHandle

    /// Un archivo dentro de la imagen.
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// En qué sector empieza.
        public let sector: UInt32
        public let size: Int64
        public let isDirectory: Bool
    }

    /// Abre la imagen, si lo es. Devuelve `nil` cuando no aparece el descriptor de volumen en
    /// ninguna de las tres formas conocidas.
    public init?(url: URL) {
        guard let abierto = try? FileHandle(forReadingFrom: url) else { return nil }
        // Las tres formas en las que puede venir un sector: un `.iso` normal, y un volcado en crudo
        // en modo 1 o en modo 2 forma 1, que solo se diferencian en cuánta cabecera va delante.
        let formas: [(sector: Int, datos: Int)] = [(2048, 0), (2352, 16), (2352, 24)]
        for forma in formas {
            let dónde = UInt64(IsoImage.primaryVolumeSector * forma.sector + forma.datos)
            guard (try? abierto.seek(toOffset: dónde)) != nil,
                  let cabecera = try? abierto.read(upToCount: 6), cabecera.count == 6
            else { continue }
            let bytes = [UInt8](cabecera)
            // Tipo 1 —descriptor primario— y la marca del estándar justo detrás.
            guard bytes[0] == 0x01, PartitionFileSystem.matches(bytes, at: 1, Array("CD001".utf8)) else {
                continue
            }
            handle = abierto
            sectorSize = forma.sector
            dataOffset = forma.datos
            return
        }
        try? abierto.close()
        return nil
    }

    deinit { try? handle.close() }

    // MARK: - Leer

    /// Lee bytes a partir de un sector, saltándose las cabeceras de los sectores por el camino.
    ///
    /// Sector a sector y no de una tirada: en un volcado en crudo los datos **no son contiguos**,
    /// van en trozos de 2048 con 304 bytes de relleno entre medias. Leer de una tirada funciona en
    /// un `.iso` y devuelve basura mezclada en el otro.
    public func read(sector: UInt32, length: Int) -> [UInt8]? {
        guard length > 0, length <= 16 * 1024 * 1024 else { return nil }
        var salida: [UInt8] = []
        salida.reserveCapacity(length)
        var actual = Int(sector)
        while salida.count < length {
            let dónde = UInt64(actual * sectorSize + dataOffset)
            guard (try? handle.seek(toOffset: dónde)) != nil,
                  let trozo = try? handle.read(upToCount: IsoImage.userDataSize), !trozo.isEmpty
            else { break }
            salida += [UInt8](trozo)
            actual += 1
        }
        guard !salida.isEmpty else { return nil }
        return Array(salida.prefix(length))
    }

    /// La carpeta raíz, que va escrita dentro del descriptor de volumen.
    public var rootDirectory: Entry? {
        guard let descriptor = read(sector: UInt32(IsoImage.primaryVolumeSector), length: IsoImage.userDataSize)
        else { return nil }
        // El registro de la raíz ocupa 34 bytes fijos dentro del descriptor, a partir de 156.
        return IsoImage.entry(in: descriptor, at: 156)
    }

    /// Lo que hay dentro de una carpeta.
    public func entries(in directory: Entry) -> [Entry] {
        guard directory.isDirectory, directory.size > 0,
              let datos = read(sector: directory.sector, length: Int(min(directory.size, 4 * 1024 * 1024)))
        else { return [] }

        var encontradas: [Entry] = []
        var posición = 0
        while posición < datos.count {
            let medida = Int(datos[posición])
            // Un cero significa que en este sector ya no quedan registros: los que falten empiezan
            // en el siguiente. **Los registros no cruzan de sector**, así que hay que saltar hasta
            // el borde en vez de darlo por terminado, o la mitad del disco se queda sin listar.
            if medida == 0 {
                let siguiente = ((posición / IsoImage.userDataSize) + 1) * IsoImage.userDataSize
                if siguiente >= datos.count { break }
                posición = siguiente
                continue
            }
            guard posición + medida <= datos.count else { break }
            if let entrada = IsoImage.entry(in: datos, at: posición),
               entrada.name != ".", entrada.name != ".." {
                encontradas.append(entrada)
            }
            posición += medida
        }
        return encontradas
    }

    /// Un archivo por su ruta dentro de la imagen: `PS3_GAME/PARAM.SFO`.
    public func entry(atPath path: String) -> Entry? {
        guard var actual = rootDirectory else { return nil }
        let partes = path.split(separator: "/").map(String.init)
        for (índice, parte) in partes.enumerated() {
            guard let siguiente = entries(in: actual).first(where: { IsoImage.matches($0.name, parte) })
            else { return nil }
            // Las de en medio tienen que ser carpetas; la última puede ser lo que sea.
            if índice < partes.count - 1, !siguiente.isDirectory { return nil }
            actual = siguiente
        }
        return actual
    }

    public func contents(of entry: Entry, limit: Int = 1024 * 1024) -> Data? {
        guard !entry.isDirectory, entry.size > 0 else { return nil }
        guard let bytes = read(sector: entry.sector, length: Int(min(entry.size, Int64(limit)))) else {
            return nil
        }
        return Data(bytes)
    }

    // MARK: - Los registros

    /// Un registro de carpeta: dónde empieza el archivo, cuánto mide y cómo se llama.
    static func entry(in bytes: [UInt8], at offset: Int) -> Entry? {
        guard offset >= 0, offset + 33 <= bytes.count else { return nil }
        let medida = Int(bytes[offset])
        guard medida >= 34 else { return nil }
        let cuántoElNombre = Int(bytes[offset + 32])
        guard cuántoElNombre > 0, offset + 33 + cuántoElNombre <= bytes.count else { return nil }

        // Cada número va escrito dos veces, en los dos órdenes de bytes, para que el disco valga
        // en cualquier máquina. Se lee el del orden del procesador y se ignora el otro.
        let sector = readUInt32(bytes, offset + 2)
        let tamaño = Int64(readUInt32(bytes, offset + 10))
        let esCarpeta = bytes[offset + 25] & 0x02 != 0

        let crudo = Array(bytes[(offset + 33)..<(offset + 33 + cuántoElNombre)])
        // «esta carpeta» y «la de arriba» no se llaman `.` y `..`: se llaman con un solo byte, 0 y
        // 1. Se traducen aquí y se descartan al listar, **no al leer el registro**: el registro de
        // la carpeta raíz usa ese mismo byte cero, así que descartarlo aquí deja la imagen entera
        // sin raíz y sin poder entrar a ningún sitio.
        let nombre: String
        if cuántoElNombre == 1, crudo[0] <= 1 {
            nombre = crudo[0] == 0 ? "." : ".."
        } else {
            nombre = String(decoding: crudo, as: UTF8.self)
        }
        return Entry(name: nombre, sector: sector, size: tamaño, isDirectory: esCarpeta)
    }

    /// Compara dos nombres como los compara un disco: sin distinguir mayúsculas y sin el número de
    /// versión que el estándar le pega detrás a cada archivo (`SYSTEM.CNF;1`). Buscar con el `;1`
    /// no encuentra nada y buscar sin él tampoco, si no se recorta.
    static func matches(_ name: String, _ wanted: String) -> Bool {
        let limpio = name.split(separator: ";").first.map(String.init) ?? name
        return limpio.caseInsensitiveCompare(wanted) == .orderedSame
    }
}
