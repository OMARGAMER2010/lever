import Foundation

/// Reconoce un juego de la consola híbrida leyendo lo que trae dentro.
///
/// Aquí no vale la cabecera de cuatro bytes que basta para una ROM: un paquete de la tienda no es
/// un juego, es un archivador con el juego, sus actualizaciones y sus DLC, y lo que hay que
/// enseñar es esa lista. La extensión miente el doble que de costumbre —un `.nsp` renombrado a
/// `.nsz` no se distingue por fuera— así que la comprobación es entrar y mirar.
///
/// **Todo esto se sabe sin ninguna llave.** El contenido va cifrado, sí, pero el índice no: los
/// nombres de las piezas, los tickets y el `cnmt.xml` de los volcados van en claro porque la
/// consola los necesita antes de descifrar nada. Con las llaves se sabe más —y para eso está
/// `NcaHeader`— pero sin ellas ya se puede decir qué es el archivo, qué trae y si está comprimido,
/// que es justo lo que hay que saber para no perder una hora con un paquete equivocado.
public enum SwitchInspector {
    /// - Parameter keys: las llaves del usuario, si las tiene. Sin ellas se lee todo lo que va en
    ///   claro, que ya es bastante; con ellas se llega a la cabecera de cada pieza, que es la única
    ///   fuente que no se puede discutir.
    public static func inspect(_ url: URL, keys: SwitchKeys? = nil) -> SwitchFacts {
        let tamaño = url.fileSizeInBytes ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return SwitchFacts(bytes: tamaño) }
        defer { try? handle.close() }

        guard let (envoltorio, contenido) = readContentPartition(handle) else {
            return SwitchFacts(bytes: tamaño)
        }

        // Lo que de verdad separa un `.nsp` de un `.nsz` no es el nombre del archivo: es que las
        // piezas de dentro se llamen `.ncz`. Un paquete renombrado se descubre aquí y no cuando el
        // emulador se atragante con él.
        let comprimido = contenido.entries.contains(where: \.isCompressedContent)
        let real = comprimido ? compressed(envoltorio) : envoltorio.decompressed

        let leído = readTitles(handle, entries: contenido.entries, keys: keys?.isUsable == true ? keys : nil)
        return SwitchFacts(
            container: real,
            evidence: leído.titles.isEmpty ? .container : leído.evidence,
            titles: leído.titles,
            entries: contenido.entries,
            bytes: tamaño,
            // Sin llaves no se puede llegar al nombre ni al icono, que están dentro de una pieza
            // cifrada. Se dice cuál falta en vez de dejar los huecos en blanco sin explicación.
            missingKeys: leído.evidence == .ncaHeader ? [] : SwitchKeyFile.required,
            requiredKeyGeneration: leído.keyGeneration,
            controlContent: leído.control
        )
    }

    /// La partición donde está el contenido, y de qué envoltorio venía.
    ///
    /// En un paquete de la tienda es la única que hay. En un cartucho hay que entrar dos veces: la
    /// raíz solo lista particiones —`update`, `normal`, `secure`— y el juego está en `secure`.
    /// Quedarse en la raíz devuelve tres entradas que no son archivos y parece un paquete vacío.
    static func readContentPartition(_ handle: FileHandle) -> (SwitchContainer, PartitionFileSystem.Partition)? {
        if let paquete = PartitionFileSystem.read(handle, at: 0, expecting: .pfs0) {
            return (.nsp, paquete)
        }
        guard let raíz = PartitionFileSystem.readCartridgeRoot(handle) else { return nil }
        // `secure` es donde va el juego. Si no estuviera, se prueba con `normal`: hay volcados
        // parciales que solo traen esa, y enseñar lo que haya es mejor que no reconocer el archivo.
        for nombre in ["secure", "normal"] {
            guard let partición = raíz.entry(named: nombre),
                  let dentro = PartitionFileSystem.read(handle, at: UInt64(partición.offset), expecting: .hfs0)
            else { continue }
            return (.xci, dentro)
        }
        return nil
    }

    private static func compressed(_ container: SwitchContainer) -> SwitchContainer {
        container.isCartridge ? .xcz : .nsz
    }

    // MARK: - Qué trae dentro

    /// Los contenidos del paquete, de la fuente más floja a la más fiable.
    ///
    /// Tres, y cada una añade algo que la anterior no tiene. El `cnmt.xml` de los volcados es el
    /// único que trae la **versión**. Los tickets están siempre que haya contenido de la tienda y
    /// dan el identificador. Y la cabecera de cada pieza —que hace falta descifrar— da lo demás:
    /// cuánto ocupa de verdad cada contenido, con qué generación de llaves se cifró y cuál de las
    /// piezas lleva el nombre y el icono.
    ///
    /// Se recorren en ese orden y cada una pisa lo que sepa mejor, en vez de quedarse con la
    /// primera que conteste. La versión sale del xml aunque mande la cabecera: la cabecera no la
    /// lleva.
    static func readTitles(
        _ handle: FileHandle, entries: [SwitchEntry], keys: SwitchKeys?
    ) -> (titles: [SwitchTitle], evidence: SwitchEvidence, keyGeneration: Int?, control: SwitchEntry?) {
        var encontrados: [UInt64: SwitchTitle] = [:]
        var prueba = SwitchEvidence.container

        for entrada in entries where entrada.name.lowercased().hasSuffix(".cnmt.xml") {
            guard let datos = read(handle, entry: entrada, limit: 64 * 1024),
                  let título = title(fromMetaXml: String(decoding: datos, as: UTF8.self))
            else { continue }
            encontrados[título.titleId] = título
            prueba = .metaXml
        }

        for entrada in entries where entrada.isTicket {
            guard let datos = read(handle, entry: entrada, limit: 0x400),
                  let título = title(fromTicket: [UInt8](datos)),
                  encontrados[título.titleId] == nil
            else { continue }
            encontrados[título.titleId] = título
            if prueba == .container { prueba = .ticket }
        }

        var generación: Int?
        var control: SwitchEntry?
        if let keys {
            var medidas: [UInt64: Int64] = [:]
            // También en un paquete comprimido: el compresor deja los primeros 0x4000 bytes de
            // cada pieza tal cual, y la cabecera cabe entera ahí dentro. Así que de un `.nsz` se
            // sabe exactamente lo mismo que de un `.nsp`, sin descomprimir nada.
            for entrada in entries where entrada.isContent || entrada.isCompressedContent {
                guard let cabecera = NcaHeader.read(handle, at: entrada.offset, keys: keys) else { continue }
                medidas[cabecera.titleId, default: 0] += cabecera.contentSize
                generación = max(generación ?? 0, cabecera.keyGeneration)
                if cabecera.contentType == .control { control = entrada }
                prueba = .ncaHeader
            }
            for (identificador, bytes) in medidas {
                let anterior = encontrados[identificador]
                encontrados[identificador] = SwitchTitle(
                    titleId: identificador, version: anterior?.version, bytes: bytes
                )
            }
        }

        // Ordenados por lo que son y luego por identificador: primero el juego, después sus
        // actualizaciones y al final los añadidos. Es el orden en el que se entienden.
        let orden: [SwitchContentKind: Int] = [.application: 0, .patch: 1, .addOn: 2]
        let títulos = encontrados.values.sorted {
            (orden[$0.kind] ?? 9, $0.titleId) < (orden[$1.kind] ?? 9, $1.titleId)
        }
        return (títulos, prueba, generación, control)
    }

    /// El contenido descrito por un `cnmt.xml`.
    ///
    /// Lo genera la herramienta que hizo el volcado, no la consola, así que puede faltar o venir
    /// mal. Se acepta porque es lo único que trae la versión sin descifrar nada, y por eso el nivel
    /// de prueba que produce se dice aparte.
    public static func title(fromMetaXml xml: String) -> SwitchTitle? {
        guard let crudo = value(ofTag: "Id", in: xml) else { return nil }
        let dígitos = crudo.hasPrefix("0x") || crudo.hasPrefix("0X") ? String(crudo.dropFirst(2)) : crudo
        guard let identificador = UInt64(dígitos, radix: 16) else { return nil }
        let versión = value(ofTag: "Version", in: xml).flatMap { UInt32($0) }
        return SwitchTitle(titleId: identificador, kind: kind(ofXmlType: value(ofTag: "Type", in: xml)),
                           version: versión)
    }

    /// El tipo tal como lo escribe el `cnmt.xml`. Cuando no venga —o venga uno que no se conoce—
    /// se deduce del identificador, que nunca miente.
    private static func kind(ofXmlType type: String?) -> SwitchContentKind? {
        switch type?.lowercased() {
        case "application": return .application
        case "patch": return .patch
        case "addoncontent": return .addOn
        default: return nil
        }
    }

    /// El contenido al que da permiso un ticket.
    ///
    /// El ticket lleva delante una firma cuyo tamaño depende del algoritmo, así que **los datos no
    /// empiezan siempre en el mismo sitio**: hay que leer el tipo de firma primero. Dar por hecho
    /// el caso normal —el de 0x140— funciona con casi todos y falla en silencio con el resto.
    public static func title(fromTicket bytes: [UInt8]) -> SwitchTitle? {
        guard let datos = ticketDataOffset(bytes) else { return nil }
        // El identificador del título son los primeros ocho bytes del «rights id», y van con el
        // byte de más peso primero, al revés que el resto del formato.
        let identificador = readUInt64BigEndian(bytes, datos + 0x160)
        guard identificador != 0 else { return nil }
        return SwitchTitle(titleId: identificador)
    }

    /// Dónde empiezan los datos de un ticket, según el tipo de firma que lleve delante.
    public static func ticketDataOffset(_ bytes: [UInt8]) -> Int? {
        let tipo = readUInt32(bytes, 0)
        let dónde: Int
        switch tipo {
        case 0x0001_0000, 0x0001_0003: dónde = 0x240   // RSA de 4096 bits
        case 0x0001_0001, 0x0001_0004: dónde = 0x140   // RSA de 2048 bits, que es lo normal
        case 0x0001_0002, 0x0001_0005: dónde = 0x080   // curva elíptica
        default: return nil
        }
        guard bytes.count >= dónde + 0x170 else { return nil }
        return dónde
    }

    // MARK: - Lectura

    private static func read(_ handle: FileHandle, entry: SwitchEntry, limit: Int) -> Data? {
        guard entry.size > 0, entry.offset >= 0 else { return nil }
        guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil else { return nil }
        return try? handle.read(upToCount: min(Int(entry.size), limit))
    }

    /// El contenido de la primera etiqueta con ese nombre.
    ///
    /// A mano y no con un analizador de XML de verdad porque hace falta justo esto —tres etiquetas
    /// planas de un archivo que genera siempre la misma herramienta— y porque un analizador
    /// completo delega en el sistema y falla de formas que aquí no se pueden probar.
    public static func value(ofTag tag: String, in xml: String) -> String? {
        guard let inicio = xml.range(of: "<\(tag)>"),
              let fin = xml.range(of: "</\(tag)>", range: inicio.upperBound..<xml.endIndex)
        else { return nil }
        let contenido = xml[inicio.upperBound..<fin.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return contenido.isEmpty ? nil : contenido
    }
}
