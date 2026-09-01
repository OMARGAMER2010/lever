import Foundation

/// El sistema de particiones con el que la consola híbrida empaqueta un juego.
///
/// Son dos formatos que en realidad son el mismo con dos tamaños de entrada: `PFS0` para lo que se
/// baja de la tienda y `HFS0` para la copia de un cartucho, que guarda además el hash de cada
/// trozo porque un cartucho puede leerse mal. La cabecera es idéntica —marca, cuántos archivos,
/// cuánto ocupa la tabla de nombres— y detrás va una entrada por archivo y la tabla de nombres.
///
/// **Los desplazamientos no son desde el principio del archivo.** Son desde donde acaba la
/// cabecera, y eso incluye la tabla de nombres con su relleno. Sumar mal ese origen da un archivo
/// que parece bien formado y del que sale basura, sin ningún error que lo diga: es el fallo que
/// hay que tener presente al leer esto.
public enum PartitionFileSystem {
    /// Cuál de los dos, que es lo que fija el tamaño de cada entrada.
    public enum Kind: String, Equatable, Sendable {
        /// Paquete de la tienda. Entradas de 0x18: desplazamiento, tamaño y nombre.
        case pfs0
        /// Copia de cartucho. Entradas de 0x40: lo mismo más el hash del principio del archivo.
        case hfs0

        var magic: [UInt8] { Array(rawValue.uppercased().utf8) }
        var entrySize: Int { self == .pfs0 ? 0x18 : 0x40 }
    }

    /// Una partición ya leída: qué trae y dónde empieza cada cosa **en el archivo**.
    public struct Partition: Equatable, Sendable {
        public let kind: Kind
        public let entries: [SwitchEntry]

        public init(kind: Kind, entries: [SwitchEntry]) {
            self.kind = kind
            self.entries = entries
        }

        public func entry(named name: String) -> SwitchEntry? {
            entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Lo que hay que leer para saber el tamaño de la cabecera entera: marca, cuántos y la tabla.
    private static let preludeSize = 0x10

    // MARK: - Leer del archivo

    /// Lee la partición que empieza en `offset`.
    ///
    /// En dos pasos a propósito: primero dieciséis bytes para saber cuánto mide la cabecera y
    /// luego la cabecera entera. Un `.xci` de cuarenta gigas no se puede mapear entero para
    /// mirarle una tabla de cien bytes, y un recuento corrupto pediría una lectura de varios
    /// gigabytes si no se comprobara antes.
    public static func read(_ handle: FileHandle, at offset: UInt64, expecting kind: Kind? = nil) -> Partition? {
        guard let prólogo = bytes(handle, at: offset, count: preludeSize), prólogo.count == preludeSize else {
            return nil
        }
        guard let clase = identify(prólogo, expecting: kind) else { return nil }
        let cuántos = Int(readUInt32(prólogo, 0x04))
        let tablaDeNombres = Int(readUInt32(prólogo, 0x08))
        guard let medida = headerSize(kind: clase, count: cuántos, stringTable: tablaDeNombres) else { return nil }

        guard let cabecera = bytes(handle, at: offset, count: medida), cabecera.count == medida else { return nil }
        // El origen de los datos es donde acaba la cabecera, ya en coordenadas del archivo.
        return parse(header: cabecera, dataOrigin: Int64(offset) + Int64(medida), expecting: clase)
    }

    /// Lee la partición raíz de una copia de cartucho, que no está al principio del archivo.
    ///
    /// Un `.xci` empieza por su firma y su cabecera propia; la tabla de particiones está donde esa
    /// cabecera diga —normalmente en 0xF000, pero eso no se supone: se lee del campo—.
    public static func readCartridgeRoot(_ handle: FileHandle) -> Partition? {
        guard let cabecera = bytes(handle, at: 0, count: 0x200), cabecera.count == 0x200 else { return nil }
        guard let dónde = cartridgeRootOffset(header: cabecera) else { return nil }
        return read(handle, at: dónde, expecting: .hfs0)
    }

    /// Dónde dice la cabecera de un cartucho que está su tabla de particiones.
    ///
    /// La marca `HEAD` va en 0x100 y no en cero: delante lleva 256 bytes de firma. Buscarla al
    /// principio es el error natural y hace que ningún `.xci` se reconozca.
    public static func cartridgeRootOffset(header: [UInt8]) -> UInt64? {
        guard matches(header, at: 0x100, Array("HEAD".utf8)) else { return nil }
        let dónde = readUInt64(header, 0x130)
        // Un valor imposible significa cabecera rota; devolver `nil` es mejor que ir a leer a un
        // sitio cualquiera del disco.
        guard dónde > 0, dónde < 0x1_0000_0000_0000 else { return nil }
        return dónde
    }

    // MARK: - Interpretar los bytes

    /// Interpreta una cabecera ya leída. Separada de la lectura para poder probarla con una
    /// cabecera fabricada, sin ningún archivo de nadie.
    ///
    /// - Parameter dataOrigin: dónde empiezan los datos **en el archivo**. Los desplazamientos de
    ///   las entradas son relativos a ese punto, no al principio del archivo.
    public static func parse(header: [UInt8], dataOrigin: Int64, expecting kind: Kind? = nil) -> Partition? {
        guard header.count >= preludeSize, let clase = identify(header, expecting: kind) else { return nil }
        let cuántos = Int(readUInt32(header, 0x04))
        let tablaDeNombres = Int(readUInt32(header, 0x08))
        guard let medida = headerSize(kind: clase, count: cuántos, stringTable: tablaDeNombres),
              header.count >= medida else { return nil }

        let inicioDeLaTabla = preludeSize + cuántos * clase.entrySize
        var entradas: [SwitchEntry] = []
        entradas.reserveCapacity(cuántos)

        for índice in 0..<cuántos {
            let base = preludeSize + índice * clase.entrySize
            let desplazamiento = Int64(bitPattern: readUInt64(header, base))
            let tamaño = Int64(bitPattern: readUInt64(header, base + 0x08))
            let dóndeElNombre = Int(readUInt32(header, base + 0x10))
            // Una entrada con números imposibles se salta en vez de tumbar la lectura entera: el
            // resto del paquete sigue sirviendo, y quedarse sin nada por una entrada rota sería
            // peor que enseñar las buenas.
            guard desplazamiento >= 0, tamaño >= 0, dóndeElNombre >= 0,
                  let nombre = text(header, from: inicioDeLaTabla + dóndeElNombre, limit: inicioDeLaTabla + tablaDeNombres)
            else { continue }
            entradas.append(
                SwitchEntry(name: nombre, offset: dataOrigin + desplazamiento, size: tamaño)
            )
        }
        return Partition(kind: clase, entries: entradas)
    }

    /// Cuánto mide la cabecera entera. Devuelve `nil` cuando los números no son creíbles.
    ///
    /// El tope no es un capricho: el recuento sale del propio archivo, y un archivo mal formado
    /// —o preparado a mala idea— puede decir que trae cuatro mil millones de entradas. Sin este
    /// límite eso son cien gigabytes de reserva de memoria antes de darse cuenta de nada.
    public static func headerSize(kind: Kind, count: Int, stringTable: Int) -> Int? {
        guard count >= 0, count <= 0x10000, stringTable >= 0, stringTable <= 0x100000 else { return nil }
        return preludeSize + count * kind.entrySize + stringTable
    }

    private static func identify(_ header: [UInt8], expecting kind: Kind?) -> Kind? {
        for candidata in (kind.map { [$0] } ?? [.pfs0, .hfs0]) where matches(header, at: 0, candidata.magic) {
            return candidata
        }
        return nil
    }

    // MARK: - Escribir

    /// La cabecera de un paquete de la tienda con esos archivos dentro.
    ///
    /// Hace falta para rehacer un paquete comprimido: las piezas se descomprimen una a una y luego
    /// hay que volver a empaquetarlas, y el emulador espera un `PFS0` de verdad, con su tabla de
    /// nombres y sus desplazamientos.
    ///
    /// La tabla de nombres se rellena hasta un múltiplo de dieciséis. No es cosmético: los datos
    /// empiezan justo detrás, y las herramientas de esta consola dan por hecho que empiezan
    /// alineados.
    public static func makeHeader(files: [(name: String, size: Int64)]) -> Data {
        var nombres = Data()
        var dónde: [Int] = []
        for archivo in files {
            dónde.append(nombres.count)
            nombres.append(Data(archivo.name.utf8))
            nombres.append(0)
        }
        while nombres.count % 16 != 0 { nombres.append(0) }

        var cabecera = Data(Kind.pfs0.magic)
        cabecera.append(littleEndian(UInt32(files.count), bytes: 4))
        cabecera.append(littleEndian(UInt32(nombres.count), bytes: 4))
        cabecera.append(littleEndian(0, bytes: 4))

        var desplazamiento: Int64 = 0
        for (índice, archivo) in files.enumerated() {
            cabecera.append(littleEndian(UInt64(bitPattern: desplazamiento), bytes: 8))
            cabecera.append(littleEndian(UInt64(bitPattern: archivo.size), bytes: 8))
            cabecera.append(littleEndian(UInt32(dónde[índice]), bytes: 4))
            cabecera.append(littleEndian(0, bytes: 4))
            desplazamiento += archivo.size
        }
        return cabecera + nombres
    }

    private static func littleEndian<T: FixedWidthInteger>(_ valor: T, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8((UInt64(valor) >> (8 * $0)) & 0xFF) })
    }

    // MARK: - Lectura de bytes

    private static func bytes(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count > 0 else { return nil }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        guard let leído = try? handle.read(upToCount: count) else { return nil }
        return [UInt8](leído)
    }

    static func matches(_ bytes: [UInt8], at offset: Int, _ pattern: [UInt8]) -> Bool {
        guard offset >= 0, offset + pattern.count <= bytes.count else { return false }
        for (índice, esperado) in pattern.enumerated() where bytes[offset + índice] != esperado {
            return false
        }
        return true
    }

    /// Un nombre de la tabla: termina en cero y no puede salirse de la tabla.
    private static func text(_ bytes: [UInt8], from offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < min(limit, bytes.count) else { return nil }
        let fin = min(limit, bytes.count)
        var final = offset
        while final < fin, bytes[final] != 0 { final += 1 }
        guard final > offset else { return nil }
        return String(decoding: bytes[offset..<final], as: UTF8.self)
    }
}

// MARK: - Números

/// Un identificador de título va al revés que el resto de campos de estos formatos: en el ticket
/// viaja con el byte de más peso primero, porque es como se escribe. Los demás enteros van en el
/// orden del procesador y los leen `readUInt32` y `readUInt64`, que ya están en el módulo.
/// Mezclar los dos órdenes da un identificador que no existe y que no se parece a nada.
func readUInt64BigEndian(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
    var valor: UInt64 = 0
    for índice in 0..<8 { valor = (valor << 8) | UInt64(bytes[offset + índice]) }
    return valor
}
