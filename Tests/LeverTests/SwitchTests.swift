import Foundation
import LeverCore

/// Pruebas del reconocimiento de los paquetes de la consola híbrida.
///
/// Los paquetes se fabrican byte a byte, como las cabeceras de `EmulationTests`: la marca `PFS0`,
/// la tabla de entradas con sus desplazamientos, la tabla de nombres, la cabecera `HEAD` de un
/// cartucho con su partición `secure` dentro, y un ticket con su firma delante. Son los formatos de
/// verdad, y por eso no hace falta el juego de nadie para comprobar que se leen.
enum SwitchTests {
    static func run() throws {
        try testClassifiesTitleIdsTheWayTheConsoleDoes()
        try testReadsAPackageFromTheStore()
        try testReadsACartridgeThroughItsSecurePartition()
        try testTellsATrimmedCartridgeFromOneCarryingFirmware()
        try testReadsWhatTheEmulatorIsSetUpToPlayWith()
        try testTellsACompressedPackageFromItsName()
        try testReadsTheTitleFromATicket()
        try testReadsATicketWhoseSignatureIsAnotherSize()
        try testReadsTheVersionFromTheMetaXml()
        try testPrefersTheXmlOverTheTicket()
        try testDoesNotInventAPackage()
        try testRefusesAnImpossibleEntryCount()
        try testReadsTheKeyFileAndNeverShowsWhatIsInIt()
        try testARoundedHexValueIsRejected()
        try testSaysWhichKeysAreMissing()
        try testTheBlockCipherMatchesTheStandardVector()
        try testTheGaloisCarryAppliesThePolynomial()
        try testNintendoNumbersItsSectorsBackwards()
        try testTheCounterModeUndoesItself()
        try testReadsTheHeaderOfAContentPiece()
        try testTheWrongKeyIsCaughtByTheMagic()
        try testWithKeysTheHeaderWins()
        try testACompressedPackageStillShowsItsHeaders()
        try testTheDecompressCommandPutsItsArgumentsInOrder()
        try testTheHeaderItWritesIsTheOneItReads()
        try testFindsAnEmulatorAndTakesOneChosenByHand()
        try testTheHybridPackagesAreAcceptedAsGames()
    }

    // MARK: - Los identificadores

    /// Los últimos tres dígitos dicen qué es cada cosa, y de ahí sale a qué juego pertenece. Sin
    /// esto, un DLC parecería un juego suelto y un parche no se podría emparejar con nada.
    private static func testClassifiesTitleIdsTheWayTheConsoleDoes() throws {
        let juego = SwitchTitle(titleId: 0x0100_0000_0001_0000)
        try expect(juego.kind == .application, "un identificador acabado en 000 es el juego")
        try expect(juego.baseTitleId == juego.titleId, "y es su propia base")

        let parche = SwitchTitle(titleId: 0x0100_0000_0001_0800)
        try expect(parche.kind == .patch, "acabado en 800 es una actualización")
        try expect(parche.baseTitleId == 0x0100_0000_0001_0000, "y apunta al juego que parchea")

        // Los DLC empiezan un bloque de 0x1000 por encima del juego: sin restarlo, la base saldría
        // 0x…11000, que es un juego que no existe.
        let añadido = SwitchTitle(titleId: 0x0100_0000_0001_1001)
        try expect(añadido.kind == .addOn, "lo demás es contenido añadido")
        try expect(añadido.baseTitleId == 0x0100_0000_0001_0000, "que también apunta al juego")

        try expect(juego.formattedId == "0100000000010000", "se escriben en mayúsculas y a dieciséis")
        try expect(SwitchTitle(titleId: 1, version: 196_608).displayVersion == "v3",
                   "la consola cuenta 65536 por versión: 196608 es la 3")
    }

    // MARK: - Los paquetes

    private static func testReadsAPackageFromTheStore() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("juego.nsp")
        try paquete([
            ("0123456789abcdef0123456789abcdef.nca", Data(repeating: 0xAA, count: 64)),
            ("0100000000010000.cnmt.xml", Data(metaXml(id: "0x0100000000010000", tipo: "Application", versión: 0).utf8))
        ]).write(to: archivo)

        let hechos = SwitchInspector.inspect(archivo)
        try expect(hechos.container == .nsp, "un PFS0 con piezas .nca es un paquete de la tienda")
        try expect(hechos.entries.count == 2, "tiene que ver las dos piezas")
        try expect(hechos.needsDecompression == false, "y no hay nada que descomprimir")

        // Lo importante del formato: el desplazamiento de una entrada es desde donde acaba la
        // cabecera, no desde el principio del archivo. Si se sumara mal, aquí saldría basura.
        let pieza = hechos.entries[0]
        let datos = try Data(contentsOf: archivo)
        try expect(datos[Int(pieza.offset)] == 0xAA, "la pieza tiene que empezar donde se dice")
        try expect(pieza.size == 64, "y medir lo que se dice")
    }

    /// Un cartucho no lista archivos en su raíz: lista particiones. El juego está dentro de
    /// `secure`, una partición más adentro, y quedarse en la raíz da tres entradas que no son
    /// archivos y parece un paquete vacío.
    private static func testReadsACartridgeThroughItsSecurePartition() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("cartucho.xci")
        let dentro = partición(.hfs0, [
            ("fedcba9876543210fedcba9876543210.nca", Data(repeating: 0xBB, count: 32))
        ])
        try cartucho([("update", Data()), ("secure", dentro)]).write(to: archivo)

        let hechos = SwitchInspector.inspect(archivo)
        try expect(hechos.container == .xci, "la marca HEAD en 0x100 es un cartucho")
        try expect(hechos.entries.count == 1, "y dentro de secure va la pieza")
        try expect(hechos.entries[0].name.hasSuffix(".nca"), "que es una pieza de contenido")

        let datos = try Data(contentsOf: archivo)
        try expect(datos[Int(hechos.entries[0].offset)] == 0xBB,
                   "los desplazamientos de dentro se suman a los de fuera")
    }

    /// Lo que separa un `.nsp` de un `.nsz` está dentro, no en el nombre: en el comprimido las
    /// piezas se llaman `.ncz`. Un archivo renombrado tiene que descubrirse aquí.
    private static func testTellsACompressedPackageFromItsName() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("mentiroso.nsp")
        try paquete([("0123456789abcdef0123456789abcdef.ncz", Data(repeating: 0xCC, count: 16))])
            .write(to: archivo)

        let hechos = SwitchInspector.inspect(archivo)
        try expect(hechos.container == .nsz, "con piezas .ncz es un paquete comprimido")
        try expect(hechos.needsDecompression, "y hay que rehacerlo antes de jugar")
        try expect(hechos.evidence == .container, "sin ticket ni xml solo se reconoce el envoltorio")
    }

    // MARK: - Los tickets

    private static func testReadsTheTitleFromATicket() throws {
        let bytes = ticket(firma: 0x0001_0004, título: 0x0100_0000_0001_0000)
        let título = SwitchInspector.title(fromTicket: bytes)
        try expect(título?.titleId == 0x0100_0000_0001_0000,
                   "el identificador son los ocho primeros bytes del rights id")
        // Y van con el byte de más peso primero, al revés que el resto del formato: leerlos en el
        // otro orden da 0x0000010000000001, que no es ningún título.
        try expect(título?.kind == .application, "y ese es el juego base")
    }

    /// El tamaño de la firma cambia con el algoritmo, así que los datos no empiezan siempre en el
    /// mismo sitio. Dar por hecho el caso normal funciona con casi todos y falla en silencio con
    /// los demás.
    private static func testReadsATicketWhoseSignatureIsAnotherSize() throws {
        let bytes = ticket(firma: 0x0001_0002, título: 0x0100_0000_0002_0800)
        try expect(SwitchInspector.ticketDataOffset(bytes) == 0x80,
                   "una firma de curva elíptica deja los datos en 0x80")
        try expect(SwitchInspector.title(fromTicket: bytes)?.kind == .patch,
                   "y aun así se lee que es una actualización")

        var roto = ticket(firma: 0x0001_0004, título: 1)
        roto[0] = 0x99
        try expect(SwitchInspector.title(fromTicket: roto) == nil,
                   "una firma que no se conoce no se adivina")
    }

    // MARK: - El cnmt.xml

    private static func testReadsTheVersionFromTheMetaXml() throws {
        let xml = metaXml(id: "0x0100000000010800", tipo: "Patch", versión: 196_608)
        let título = SwitchInspector.title(fromMetaXml: xml)
        try expect(título?.titleId == 0x0100_0000_0001_0800, "el Id viene en hexadecimal con 0x delante")
        try expect(título?.version == 196_608, "y la versión en decimal")
        try expect(título?.displayVersion == "v3", "que son tres versiones de las que cuenta la gente")
        try expect(SwitchInspector.value(ofTag: "Type", in: xml) == "Patch", "y el tipo tal cual")
        try expect(SwitchInspector.title(fromMetaXml: "<ContentMeta></ContentMeta>") == nil,
                   "sin Id no hay título que leer")
    }

    /// Los dos dicen el identificador, pero solo el xml dice la versión. Si mandara el ticket, la
    /// versión se perdería sin que nada lo explicara.
    private static func testPrefersTheXmlOverTheTicket() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("completo.nsp")
        let identificador: UInt64 = 0x0100_0000_0001_0000
        try paquete([
            ("0100000000010000.cnmt.xml",
             Data(metaXml(id: "0x0100000000010000", tipo: "Application", versión: 0).utf8)),
            ("0123456789abcdef.tik", Data(ticket(firma: 0x0001_0004, título: identificador)))
        ]).write(to: archivo)

        let hechos = SwitchInspector.inspect(archivo)
        try expect(hechos.evidence == .metaXml, "manda el xml, que dice más")
        try expect(hechos.titles.count == 1, "y el mismo título no se cuenta dos veces")
        try expect(hechos.application?.version == 0, "con su versión leída")

        // Y sin xml, el ticket sirve igual para saber qué hay.
        let soloTicket = fixture.directoryURL.appendingPathComponent("solo.nsp")
        try paquete([("0123456789abcdef.tik", Data(ticket(firma: 0x0001_0004, título: identificador)))])
            .write(to: soloTicket)
        try expect(SwitchInspector.inspect(soloTicket).evidence == .ticket, "sin xml manda el ticket")
    }

    // MARK: - Lo que no es

    private static func testDoesNotInventAPackage() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("cualquiera.nsp")
        try Data(repeating: 0x41, count: 4096).write(to: archivo)
        let hechos = SwitchInspector.inspect(archivo)
        try expect(!hechos.isRecognised, "llamarse .nsp no convierte un archivo en un paquete")
        try expect(hechos.titles.isEmpty, "y no se inventa nada de dentro")
    }

    /// El recuento de entradas sale del propio archivo. Uno mal formado —o preparado a mala idea—
    /// puede decir que trae cuatro mil millones, y reservar esa cabecera son cien gigabytes de
    /// memoria antes de darse cuenta de nada.
    private static func testRefusesAnImpossibleEntryCount() throws {
        try expect(PartitionFileSystem.headerSize(kind: .pfs0, count: 3, stringTable: 64) == 0x10 + 3 * 0x18 + 64,
                   "una cabecera normal mide lo que suman sus partes")
        try expect(PartitionFileSystem.headerSize(kind: .pfs0, count: 0x7FFF_FFFF, stringTable: 0) == nil,
                   "un recuento imposible se rechaza antes de reservar nada")
        try expect(PartitionFileSystem.headerSize(kind: .hfs0, count: 1, stringTable: -1) == nil,
                   "y una tabla de nombres negativa también")
    }

    // MARK: - Las llaves

    private static func testReadsTheKeyFileAndNeverShowsWhatIsInIt() throws {
        let llaves = SwitchKeys(text: """
            # un comentario
            header_key = \(String(repeating: "ab", count: 32))
            key_area_key_application_00 = \(String(repeating: "cd", count: 16))
            titlekek_00 = \(String(repeating: "ef", count: 16))

            esto no es una linea valida
            """)
        try expect(llaves.headerKey?.count == 32, "la llave de cabecera son 32 bytes: dos de 16")
        try expect(llaves.keyAreaKey(applicationIndex: 0, generation: 0)?.count == 16, "las demás, 16")
        try expect(llaves.titleKek(generation: 0)?.count == 16, "y la de los tickets también")
        try expect(llaves.isUsable, "con header_key ya se puede leer una cabecera")
        try expect(llaves.keyGenerations == 1, "y trae una sola generación")
        try expect(llaves.names.count == 3, "las líneas rotas se saltan, no tumban el archivo")

        // Lo que de verdad importa: un valor no puede salir por ningún sitio. El registro de
        // actividad lo copia y lo pega la gente para pedir ayuda.
        try expect(!llaves.description.contains("abab"), "la descripción no puede llevar el valor")
        try expect(!llaves.names.joined().contains("abab"), "ni la lista de nombres")
        try expect(llaves.description == "SwitchKeys(3 llaves)", "solo dice cuántas hay")
    }

    /// Un valor a medio copiar es peor que ninguno: descifra igual y lo que sale es basura, sin
    /// ningún error que diga por qué.
    private static func testARoundedHexValueIsRejected() throws {
        try expect(SwitchKeys(text: "header_key = abcdefg0").headerKey == nil, "una letra que no es hex no vale")
        try expect(SwitchKeys(text: "header_key = abc").headerKey == nil, "ni un número impar de dígitos")
        try expect(SwitchKeys(text: "header_key = " + String(repeating: "ab", count: 8)).headerKey == nil,
                   "ni una llave de la longitud equivocada")
    }

    private static func testSaysWhichKeysAreMissing() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("juego.nsp")
        try paquete([("0123456789abcdef.tik", Data(ticket(firma: 0x0001_0004, título: 0x0100_0000_0001_0000)))])
            .write(to: archivo)
        let hechos = SwitchInspector.inspect(archivo)
        try expect(hechos.missingKeys == ["prod.keys"],
                   "sin llegar a la cabecera cifrada, hay que decir qué archivo falta")
        try expect(SwitchKeyFile.required == ["prod.keys"], "y ese archivo tiene nombre")
    }

    // MARK: - La criptografía

    /// El AES de bloque, contra el vector de prueba del propio estándar. Si esto falla, todo lo
    /// que va encima descifra basura sin quejarse.
    private static func testTheBlockCipherMatchesTheStandardVector() throws {
        let llave = SwitchKeys.hex("000102030405060708090a0b0c0d0e0f")!
        var bloque = SwitchKeys.hex("00112233445566778899aabbccddeeff")!
        let cifrador = NintendoCrypto.Block(key: llave)
        try expect(cifrador != nil, "el cifrador tiene que abrirse")
        try expect(cifrador!.process(&bloque), "y cifrar el bloque")
        try expect(bloque == SwitchKeys.hex("69c4e0d86a7b0430d8cdb78070b4c55a")!,
                   "el vector del FIPS-197 para AES de 128 bits")

        let descifrador = NintendoCrypto.Block(key: llave, forDecryption: true)!
        try expect(descifrador.process(&bloque), "y se deshace")
        try expect(bloque == SwitchKeys.hex("00112233445566778899aabbccddeeff")!, "volviendo al original")

        try expect(NintendoCrypto.Block(key: [1, 2, 3]) == nil, "una llave de otro tamaño no vale")
    }

    /// La multiplicación por x del cuerpo de Galois: un desplazamiento, y si se sale por arriba,
    /// el polinomio reductor sobre el primer byte. Olvidar el 0x87 es el error clásico y solo se
    /// nota a partir del bloque en el que hay acarreo, o sea nunca en una prueba corta.
    private static func testTheGaloisCarryAppliesThePolynomial() throws {
        var marca = [UInt8](repeating: 0, count: 16)
        marca[0] = 1
        try expect(NintendoCrypto.multiplyByX(marca)[0] == 2, "sin acarreo es duplicar")

        // Con el bit de más peso del último byte puesto, el acarreo sale por arriba y vuelve.
        var alDesbordar = [UInt8](repeating: 0, count: 16)
        alDesbordar[15] = 0x80
        let resultado = NintendoCrypto.multiplyByX(alDesbordar)
        try expect(resultado[0] == 0x87, "al desbordar, el polinomio reductor sobre el primer byte")
        try expect(resultado[15] == 0, "y el bit que se fue ya no está")
    }

    /// **La diferencia que no da ningún error.** El estándar numera los sectores con el byte de
    /// menos peso primero y Nintendo al revés. Con el orden equivocado se descifra igual de bien y
    /// salen tres mil bytes de basura con la pinta exacta de una cabecera cifrada.
    private static func testNintendoNumbersItsSectorsBackwards() throws {
        try expect(NintendoCrypto.tweakBytes(1, bigEndian: true)[15] == 1,
                   "Nintendo pone el número al final")
        try expect(NintendoCrypto.tweakBytes(1, bigEndian: false)[0] == 1,
                   "y el estándar al principio")

        let llave = [UInt8](repeating: 0x5A, count: 32)
        let claro = [UInt8](repeating: 0x11, count: 0x400)
        let comoNintendo = NintendoCrypto.xtsEncrypt(claro, key: llave, firstSector: 0, bigEndianTweak: true)!
        let comoElEstándar = NintendoCrypto.xtsEncrypt(claro, key: llave, firstSector: 0, bigEndianTweak: false)!

        // El sector cero sale igual con los dos órdenes —cero es cero en cualquier orden—, así que
        // la prueba está en el segundo sector: ahí es donde el número deja de ser simétrico.
        try expect(Array(comoNintendo[0..<0x200]) == Array(comoElEstándar[0..<0x200]),
                   "el sector cero no distingue los dos órdenes")
        try expect(Array(comoNintendo[0x200..<0x400]) != Array(comoElEstándar[0x200..<0x400]),
                   "el segundo sí, y por eso el orden no se puede suponer")

        let vuelta = NintendoCrypto.xtsDecrypt(comoNintendo, key: llave, firstSector: 0, bigEndianTweak: true)
        try expect(vuelta == claro, "y con el orden bueno se vuelve al original")
        try expect(NintendoCrypto.xtsDecrypt(claro, key: [UInt8](repeating: 0, count: 16)) == nil,
                   "XTS son dos llaves de dieciséis: con una sola no se puede")
        try expect(NintendoCrypto.xtsDecrypt([1, 2, 3], key: llave) == nil,
                   "y los datos tienen que venir en sectores enteros")
    }

    /// En modo contador no se cifra el mensaje: se cifra una cuenta y se hace XOR. Por eso la misma
    /// función sirve para los dos sentidos, y por eso rehacer un `.ncz` es el mismo trabajo que
    /// abrirlo.
    private static func testTheCounterModeUndoesItself() throws {
        let llave = [UInt8](repeating: 0x33, count: 16)
        let cuenta = [UInt8](repeating: 0x44, count: 16)
        // Un tamaño que no es múltiplo de bloque, a propósito: el último trozo se queda corto y es
        // donde se rompen las implementaciones que dan por hecho bloques enteros.
        let claro = (0..<(4096 + 7)).map { UInt8($0 & 0xFF) }

        let cifrado = NintendoCrypto.ctr(claro, key: llave, counter: cuenta)!
        try expect(cifrado.count == claro.count, "no cambia de tamaño")
        try expect(cifrado != claro, "y cifra de verdad")
        try expect(NintendoCrypto.ctr(cifrado, key: llave, counter: cuenta) == claro,
                   "pasarlo dos veces devuelve el original")

        // La cuenta sube por la parte de abajo. Sin el acarreo, a partir del bloque 256 se
        // repetiría el flujo, y un flujo repetido en un cifrado por XOR es lo que lo rompe.
        var alBorde = [UInt8](repeating: 0, count: 16)
        alBorde[15] = 0xFF
        let subida = NintendoCrypto.increment(alBorde)
        try expect(subida[15] == 0 && subida[14] == 1, "el acarreo pasa al byte de al lado")
        try expect(NintendoCrypto.increment([UInt8](repeating: 0, count: 16))[15] == 1, "y suma por el final")

        // El desplazamiento se cuenta en bloques de dieciséis, no en bytes.
        let desde = NintendoCrypto.counter(prefix: [UInt8](repeating: 0xAB, count: 8), offset: 0x20)!
        try expect(desde[0] == 0xAB, "los ocho primeros bytes salen de la sección")
        try expect(desde[15] == 2, "y los ocho últimos son el desplazamiento entre dieciséis")
    }

    // MARK: - La cabecera cifrada

    private static func testReadsTheHeaderOfAContentPiece() throws {
        let llave = [UInt8](repeating: 0x7C, count: 32)
        let cifrada = NintendoCrypto.xtsEncrypt(
            cabeceraNca(título: 0x0100_0000_0001_0000, tipo: 0, tamaño: 1_234_567,
                        generaciónVieja: 0, generaciónNueva: 0x10, sdk: 0x1105_0000),
            key: llave, firstSector: 0, bigEndianTweak: true
        )!

        let cabecera = NcaHeader.read(encrypted: cifrada, headerKey: llave)
        try expect(cabecera?.titleId == 0x0100_0000_0001_0000, "el título va en 0x210")
        try expect(cabecera?.contentType == .program, "y lo que es la pieza en 0x205")
        try expect(cabecera?.contentSize == 1_234_567, "con lo que ocupa de verdad")
        try expect(cabecera?.version == 3, "la versión sale del último carácter de la marca")
        try expect(cabecera?.sdkVersionText == "17.5.0.0", "el kit va empaquetado en cuatro números")

        // La generación se guarda en dos campos por razones históricas y manda el mayor, con un
        // desplazamiento de uno. Leyendo solo el viejo saldría 0 en todo lo publicado desde 2018.
        try expect(cabecera?.keyGeneration == 15, "manda el campo nuevo, y va desplazada en uno")
        try expect(cabecera?.hasRightsId == false, "esta pieza no lleva llave de título")
    }

    /// Descifrar con la llave equivocada no falla: devuelve bytes. Lo que lo delata es que en 0x200
    /// no aparece la marca, y por eso la marca se comprueba en vez de dar la cabecera por buena.
    private static func testTheWrongKeyIsCaughtByTheMagic() throws {
        let buena = [UInt8](repeating: 0x7C, count: 32)
        let cifrada = NintendoCrypto.xtsEncrypt(
            cabeceraNca(título: 1, tipo: 0, tamaño: 16, generaciónVieja: 0, generaciónNueva: 0, sdk: 0),
            key: buena, firstSector: 0, bigEndianTweak: true
        )!
        try expect(NcaHeader.read(encrypted: cifrada, headerKey: [UInt8](repeating: 0x7D, count: 32)) == nil,
                   "con otra llave no aparece la marca y no se da por buena")
        try expect(NcaHeader.decode([UInt8](repeating: 0, count: 0x340)) == nil,
                   "y una cabecera en blanco tampoco")
    }

    /// Con las llaves delante, lo que manda es la cabecera: da el tamaño de verdad de cada
    /// contenido, la generación de llaves y cuál es la pieza del nombre y el icono.
    private static func testWithKeysTheHeaderWins() throws {
        let fixture = try TemporaryFixture()
        let llave = [UInt8](repeating: 0x7C, count: 32)
        let llaves = SwitchKeys(values: ["header_key": llave])

        func pieza(tipo: UInt8, tamaño: Int64, generación: UInt8) -> Data {
            Data(NintendoCrypto.xtsEncrypt(
                cabeceraNca(título: 0x0100_0000_0001_0000, tipo: tipo, tamaño: tamaño,
                            generaciónVieja: 0, generaciónNueva: generación, sdk: 0),
                key: llave, firstSector: 0, bigEndianTweak: true
            )!)
        }

        let archivo = fixture.directoryURL.appendingPathComponent("con-llaves.nsp")
        try paquete([
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.nca", pieza(tipo: 0, tamaño: 1000, generación: 0x0A)),
            ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.nca", pieza(tipo: 2, tamaño: 500, generación: 0x03)),
            ("0100000000010000.cnmt.xml",
             Data(metaXml(id: "0x0100000000010000", tipo: "Application", versión: 131_072).utf8))
        ]).write(to: archivo)

        // Sin llaves se lee lo que va en claro y se dice qué falta.
        let sinLlaves = SwitchInspector.inspect(archivo)
        try expect(sinLlaves.evidence == .metaXml, "sin llaves manda el xml")
        try expect(sinLlaves.missingKeys == ["prod.keys"], "y se dice qué hace falta para saber más")
        try expect(sinLlaves.requiredKeyGeneration == nil, "la generación está dentro de lo cifrado")

        let conLlaves = SwitchInspector.inspect(archivo, keys: llaves)
        try expect(conLlaves.evidence == .ncaHeader, "con llaves manda la cabecera")
        try expect(conLlaves.missingKeys.isEmpty, "y ya no falta nada")
        try expect(conLlaves.application?.bytes == 1500, "los tamaños de las piezas se suman")
        try expect(conLlaves.application?.version == 131_072, "y la versión sigue viniendo del xml")
        try expect(conLlaves.controlContent?.name.hasPrefix("bbbb") == true,
                   "la pieza de control es la que lleva el nombre y el icono")

        // La generación más alta de las piezas es la que decide si un prod.keys sirve.
        try expect(conLlaves.requiredKeyGeneration == 9, "manda la más alta de las piezas, desplazada")
        try expect(conLlaves.keysAreTooOld(available: 5), "con cinco generaciones no llega")
        try expect(!conLlaves.keysAreTooOld(available: 20), "con veinte sí")
    }

    /// El compresor deja intactos los primeros 0x4000 bytes de cada pieza, y la cabecera cabe
    /// entera ahí. Así que de un paquete comprimido se sabe exactamente lo mismo que de uno normal
    /// sin descomprimir ni un byte.
    private static func testACompressedPackageStillShowsItsHeaders() throws {
        let fixture = try TemporaryFixture()
        let llave = [UInt8](repeating: 0x7C, count: 32)
        let cabecera = Data(NintendoCrypto.xtsEncrypt(
            cabeceraNca(título: 0x0100_0000_0002_0000, tipo: 0, tamaño: 42,
                        generaciónVieja: 0, generaciónNueva: 0, sdk: 0),
            key: llave, firstSector: 0, bigEndianTweak: true
        )!)

        let archivo = fixture.directoryURL.appendingPathComponent("comprimido.nsz")
        try paquete([("cccccccccccccccccccccccccccccccc.ncz", cabecera)]).write(to: archivo)

        let hechos = SwitchInspector.inspect(archivo, keys: SwitchKeys(values: ["header_key": llave]))
        try expect(hechos.container == .nsz, "sigue siendo un paquete comprimido")
        try expect(hechos.needsDecompression, "y sigue habiendo que rehacerlo")
        try expect(hechos.application?.titleId == 0x0100_0000_0002_0000,
                   "pero su cabecera se lee igual, sin descomprimir nada")
    }

    /// Una cabecera de pieza tal como la escribe la consola, antes de cifrarla. La marca está en
    /// 0x200 porque delante van dos firmas de 256 bytes.
    private static func cabeceraNca(
        título: UInt64, tipo: UInt8, tamaño: Int64,
        generaciónVieja: UInt8, generaciónNueva: UInt8, sdk: UInt32
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: NcaHeader.length)
        for (índice, byte) in Array("NCA3".utf8).enumerated() { bytes[0x200 + índice] = byte }
        bytes[0x204] = 0
        bytes[0x205] = tipo
        bytes[0x206] = generaciónVieja
        for (índice, byte) in le64(UInt64(bitPattern: tamaño)).enumerated() { bytes[0x208 + índice] = byte }
        for (índice, byte) in le64(título).enumerated() { bytes[0x210 + índice] = byte }
        for (índice, byte) in le32(sdk).enumerated() { bytes[0x21C + índice] = byte }
        bytes[0x220] = generaciónNueva
        return bytes
    }

    // MARK: - Rehacer y lanzar

    /// **Los parámetros posicionales de un guion no se comprueban solos.** Con el orden cambiado,
    /// `head` recibía una ruta donde esperaba un número de bytes: el guion se ejecutaba, no daba
    /// ningún error que dijera nada, y `zstd` se atragantaba veinte minutos después. Por eso el
    /// orden se prueba en vez de leerse.
    private static func testTheDecompressCommandPutsItsArgumentsInOrder() throws {
        let orden = SwitchTools.decompressCommand(
            package: URL(fileURLWithPath: "/tmp/juego con espacios.nsz"),
            from: 4096, length: 1_000_000,
            into: URL(fileURLWithPath: "/tmp/salida.nsp"),
            zstd: URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
        )
        try expect(orden.executableURL.lastPathComponent == "bash", "va por un guion")
        let argumentos = orden.arguments
        try expect(argumentos.first == "-c", "que se le pasa en línea")

        // `bash -c guion nombre arg1 arg2…`: el primero de después del guion es `$0`, así que los
        // parámetros empiezan en el siguiente.
        let parámetros = Array(argumentos.dropFirst(3))
        try expect(parámetros.count == 5, "cinco parámetros: desde, archivo, cuántos, zstd y destino")
        try expect(parámetros[0] == "4097", "`tail -c +N` cuenta desde uno, no desde cero")
        try expect(parámetros[1] == "/tmp/juego con espacios.nsz", "el segundo es el archivo de entrada")
        try expect(parámetros[2] == "1000000", "el tercero, cuántos bytes coger")
        try expect(parámetros[3].hasSuffix("zstd"), "el cuarto, el descompresor")
        try expect(parámetros[4] == "/tmp/salida.nsp", "y el quinto, dónde va lo descomprimido")

        // Y el guion tiene que usarlos en ese mismo orden.
        let guion = argumentos[1]
        try expect(guion.contains(#"tail -c "+$1" "$2""#), "tail: desde `$1`, sobre `$2`")
        try expect(guion.contains(#"head -c "$3""#), "head corta en `$3`")
        try expect(guion.contains(#""$4" -d -c -q >> "$5""#), "y zstd escribe añadiendo al final")
        // Las rutas van por parámetro y no metidas en el texto: una con comillas dentro no puede
        // cambiar lo que se ejecuta.
        try expect(!guion.contains("/tmp/"), "ninguna ruta viaja dentro del guion")
    }

    /// La cabecera que Lever escribe al rehacer un paquete tiene que ser la que Lever sabe leer.
    /// Si no, el paquete rehecho lo abriría el emulador y no Lever, y el fallo se vería tarde.
    private static func testTheHeaderItWritesIsTheOneItReads() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("escrito.nsp")

        var datos = PartitionFileSystem.makeHeader(files: [
            ("primera.nca", 40), ("un nombre bastante largo.tik", 8)
        ])
        try expect(datos.count % 16 == 0, "la tabla de nombres se rellena hasta un múltiplo de 16")
        datos.append(Data(repeating: 0xD1, count: 40))
        datos.append(Data(repeating: 0xD2, count: 8))
        try datos.write(to: archivo)

        let hechos = SwitchInspector.inspect(archivo)
        try expect(hechos.container == .nsp, "lo escrito se reconoce como un paquete")
        try expect(hechos.entries.map(\.name) == ["primera.nca", "un nombre bastante largo.tik"],
                   "con los nombres en su sitio")
        try expect(hechos.entries[1].size == 8, "y los tamaños")
        try expect(datos[Int(hechos.entries[1].offset)] == 0xD2, "y los desplazamientos apuntan bien")
    }

    /// Se busca el que haya instalado, y el que el usuario señale a mano vale aunque no esté en la
    /// lista: la lista sirve para encontrarlo solo, no para decidir qué puede usar.
    private static func testFindsAnEmulatorAndTakesOneChosenByHand() throws {
        try expect(!SwitchTools.known.isEmpty, "tiene que haber emuladores que buscar")
        for emulador in SwitchTools.known {
            try expect(!emulador.bundleNames.isEmpty, "\(emulador.id) necesita el nombre de su .app")
            try expect(emulador.bundleNames.allSatisfy { $0.hasSuffix(".app") },
                       "\(emulador.id): un emulador de Mac es un .app")
        }

        let fixture = try TemporaryFixture()
        let app = fixture.directoryURL.appendingPathComponent("Ryujinx.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let elegido = SwitchTools.locate(preferring: app)
        try expect(elegido?.emulator.id == "ryujinx", "por el nombre se reconoce cuál es")
        try expect(elegido?.app == app, "y se usa el que se ha señalado")

        let raro = fixture.directoryURL.appendingPathComponent("Otro Emulador.app", isDirectory: true)
        try FileManager.default.createDirectory(at: raro, withIntermediateDirectories: true)
        try expect(SwitchTools.locate(preferring: raro)?.app == raro,
                   "uno que no está en la lista vale igual si el usuario lo elige")
        try expect(SwitchTools.locate(preferring: fixture.directoryURL.appendingPathComponent("No.app")) != nil
                   || SwitchTools.locate() == nil,
                   "y una ruta que no existe no se toma por buena")
    }

    /// Los cuatro envoltorios tienen que entrar por la misma puerta que las ROMs: es la pestaña de
    /// consolas, aunque por dentro vayan por otro camino.
    private static func testTheHybridPackagesAreAcceptedAsGames() throws {
        for envoltorio in SwitchContainer.allCases {
            let url = URL(fileURLWithPath: "/tmp/juego.\(envoltorio.fileExtension)")
            try expect(SupportedFileKind.rom.accepts(url), "un .\(envoltorio.fileExtension) es un juego")
        }
        try expect(SwitchContainer.nsz.decompressed == .nsp, "un .nsz descomprimido es un .nsp")
        try expect(SwitchContainer.xcz.decompressed == .xci, "y un .xcz, un .xci")
        try expect(SwitchContainer.xci.isCartridge, "un .xci viene de un cartucho")
        try expect(!SwitchContainer.nsp.isCartridge, "y un .nsp de la tienda")
    }

    /// Se lee con qué se juega, y se distingue «no tiene nada» de «no lo sé».
    ///
    /// La distinción no es un tecnicismo: sin ningún control configurado el juego arranca y no
    /// responde a nada —el peor fallo, porque no da ningún error—, mientras que no saber leer la
    /// configuración de un emulador cualquiera no dice nada del usuario. Enseñar lo segundo como si
    /// fuera lo primero sería alarmar por un archivo que ni siquiera se entiende.
    private static func testReadsWhatTheEmulatorIsSetUpToPlayWith() throws {
        let dos = Data("""
        {"input_config":[
          {"backend":"WindowKeyboard","name":"Keyboard","player_index":"Handheld"},
          {"backend":"GamepadSDL2","name":"DualSense Wireless Controller","player_index":"Player1"}
        ]}
        """.utf8)
        guard let leído = EmulatorInputReader.parse(dos) else {
            throw TestFailure(description: "un Config.json con input_config tiene que leerse")
        }
        try expect(leído.devices.count == 2, "los dos aparatos")
        try expect(leído.hasKeyboard && leído.hasGamepad, "un teclado y un mando")
        try expect(!leído.isEmpty, "y por tanto no está sin configurar")
        try expect(leído.devices.first { $0.kind == .gamepad }?.slot == "Player1",
                   "el mando lleva el jugador al que está asignado")

        // Sin ningún perfil: configurado a cero. Es un hecho, no un desconocimiento.
        guard let vacío = EmulatorInputReader.parse(Data(#"{"input_config":[]}"#.utf8)) else {
            throw TestFailure(description: "una lista vacía sigue siendo una respuesta")
        }
        try expect(vacío.isEmpty, "sin perfiles no hay con qué jugar")

        // Y un archivo que no es de esto: no se sabe, y eso se dice con `nil`.
        try expect(EmulatorInputReader.parse(Data(#"{"otra_cosa":1}"#.utf8)) == nil,
                   "sin input_config no se sabe: nil, no «vacío»")
        try expect(EmulatorInputReader.parse(Data("no soy json".utf8)) == nil,
                   "y un archivo ilegible tampoco se inventa")

        // Un motor que no se conoce cuenta como mando en vez de desaparecer: la familia habla con
        // cualquier mando por SDL, y perder uno de la lista sin avisar sería peor que clasificarlo
        // de más.
        let raro = Data(#"{"input_config":[{"backend":"GamepadNuevo","name":"X","player_index":"Player2"}]}"#.utf8)
        try expect(EmulatorInputReader.parse(raro)?.hasGamepad == true,
                   "un motor nuevo no puede desaparecer de la lista")
    }

    /// Un cartucho entero y uno recortado se distinguen, y por el tamaño y no por la existencia.
    ///
    /// El matiz es el que hace útil la comprobación: al recortar un `.xci` la entrada `update`
    /// **se queda** en la tabla de particiones y lo que desaparece es su contenido. Mirar solo si
    /// la partición está declarada daría por bueno cualquier volcado recortado, que son casi todos
    /// los que circulan.
    private static func testTellsATrimmedCartridgeFromOneCarryingFirmware() throws {
        let fixture = try TemporaryFixture()
        let juego = partición(.hfs0, [
            ("fedcba9876543210fedcba9876543210.nca", Data(repeating: 0xBB, count: 32))
        ])

        // Entero: la partición de actualización trae el firmware con el que salió el cartucho.
        let firmware = partición(.hfs0, [
            ("0123456789abcdef0123456789abcdef.nca", Data(repeating: 0xCC, count: 256)),
            ("fedcba9876543210fedcba9876543210.nca", Data(repeating: 0xDD, count: 128))
        ])
        let entero = fixture.directoryURL.appendingPathComponent("entero.xci")
        try cartucho([("update", firmware), ("normal", Data()), ("secure", juego)]).write(to: entero)

        let hechosEntero = SwitchInspector.inspect(entero)
        try expect(hechosEntero.container == .xci, "sigue siendo un cartucho")
        // Lo que se cuenta son las piezas, no la partición: la partición lleva además su cabecera
        // y su relleno, y quien pregunta quiere saber cuánto firmware hay, no cuánto ocupa la caja.
        try expect(
            hechosEntero.cartridgeUpdate == .included(bytes: 256 + 128),
            "y trae el firmware dentro, midiendo lo que suman sus piezas"
        )
        try expect(
            Int64(firmware.count) > 256 + 128,
            "la partición mide más que sus piezas, que es lo que hace distinguibles las dos cuentas"
        )
        try expect(hechosEntero.cartridgeUpdate?.hasFirmware == true, "y lo dice también así")

        // Recortado, en las dos formas que se dan de verdad. La segunda es la que importa y la que
        // engaña: recortar no borra la partición, la **vacía**, y deja una cabecera HFS0 válida de
        // cero archivos que por tamaño parece contenido. Un volcado real es justo así.
        for (nombre, vacía) in [("recortado.xci", Data()), ("recortado-hfs0.xci", partición(.hfs0, []))] {
            let recortado = fixture.directoryURL.appendingPathComponent(nombre)
            try cartucho([("update", vacía), ("normal", Data()), ("secure", juego)]).write(to: recortado)

            let hechos = SwitchInspector.inspect(recortado)
            try expect(hechos.container == .xci, "\(nombre): un recortado sigue siendo un cartucho válido")
            try expect(hechos.entries.count == 1, "\(nombre): y el juego sigue entero dentro de secure")
            try expect(hechos.cartridgeUpdate == .trimmed,
                       "\(nombre): sin piezas dentro no hay firmware que sacar")
            try expect(hechos.cartridgeUpdate?.hasFirmware == false, "\(nombre): y no al revés")
        }

        // Y un paquete de la tienda no tiene de esto: preguntarlo no significa nada.
        let tienda = fixture.directoryURL.appendingPathComponent("tienda.nsp")
        try paquete([("0123456789abcdef0123456789abcdef.nca", Data(repeating: 0xAA, count: 16))])
            .write(to: tienda)
        try expect(SwitchInspector.inspect(tienda).container == .nsp, "esto es un paquete")
        try expect(SwitchInspector.inspect(tienda).cartridgeUpdate == nil,
                   "y un paquete no tiene partición de actualización que mirar")
    }

    // MARK: - Fabricar los formatos

    /// Una partición: marca, cuántos archivos, tabla de nombres, una entrada por archivo y los
    /// datos detrás. Los desplazamientos van desde donde acaba la cabecera.
    private static func partición(_ kind: PartitionFileSystem.Kind, _ archivos: [(String, Data)]) -> Data {
        let tamañoDeEntrada = kind == .pfs0 ? 0x18 : 0x40
        var nombres = Data()
        var dóndeCadaNombre: [Int] = []
        for (nombre, _) in archivos {
            dóndeCadaNombre.append(nombres.count)
            nombres.append(Data(nombre.utf8))
            nombres.append(0)
        }
        // La tabla se rellena hasta un múltiplo de 16, que es lo que hacen las herramientas.
        while nombres.count % 16 != 0 { nombres.append(0) }

        var cabecera = Data(kind == .pfs0 ? "PFS0".utf8 : "HFS0".utf8)
        cabecera.append(le32(UInt32(archivos.count)))
        cabecera.append(le32(UInt32(nombres.count)))
        cabecera.append(le32(0))

        var datos = Data()
        for (índice, (_, contenido)) in archivos.enumerated() {
            var entrada = Data()
            entrada.append(le64(UInt64(datos.count)))
            entrada.append(le64(UInt64(contenido.count)))
            entrada.append(le32(UInt32(dóndeCadaNombre[índice])))
            entrada.append(le32(0))
            if kind == .hfs0 {
                entrada.append(Data(repeating: 0, count: 8))    // reservado
                entrada.append(Data(repeating: 0, count: 32))   // hash del principio
            }
            precondition(entrada.count == tamañoDeEntrada)
            cabecera.append(entrada)
            datos.append(contenido)
        }
        return cabecera + nombres + datos
    }

    private static func paquete(_ archivos: [(String, Data)]) -> Data {
        partición(.pfs0, archivos)
    }

    /// Un cartucho: 256 bytes de firma, la marca `HEAD`, y en 0x130 dónde está la tabla de
    /// particiones. La marca **no** está al principio del archivo, y buscarla ahí es el error que
    /// hace que ningún `.xci` se reconozca.
    private static func cartucho(_ particiones: [(String, Data)]) -> Data {
        let raízEn: UInt64 = 0x200
        var datos = Data(repeating: 0, count: Int(raízEn))
        datos.replaceSubrange(0x100..<0x104, with: Data("HEAD".utf8))
        datos.replaceSubrange(0x130..<0x138, with: le64(raízEn))
        datos.append(partición(.hfs0, particiones))
        return datos
    }

    /// Un ticket: el tipo de firma delante, la firma, y los datos detrás. El identificador del
    /// título va en 0x160 de los datos, con el byte de más peso primero.
    private static func ticket(firma: UInt32, título: UInt64) -> [UInt8] {
        let dóndeLosDatos: Int
        switch firma {
        case 0x0001_0000, 0x0001_0003: dóndeLosDatos = 0x240
        case 0x0001_0002, 0x0001_0005: dóndeLosDatos = 0x080
        default: dóndeLosDatos = 0x140
        }
        var bytes = [UInt8](repeating: 0, count: dóndeLosDatos + 0x180)
        for (índice, byte) in le32(firma).enumerated() { bytes[índice] = byte }
        for índice in 0..<8 {
            bytes[dóndeLosDatos + 0x160 + índice] = UInt8((título >> (8 * (7 - índice))) & 0xFF)
        }
        return bytes
    }

    private static func metaXml(id: String, tipo: String, versión: Int) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <ContentMeta>
          <Type>\(tipo)</Type>
          <Id>\(id)</Id>
          <Version>\(versión)</Version>
        </ContentMeta>
        """
    }

    private static func le32(_ valor: UInt32) -> Data {
        Data((0..<4).map { UInt8((valor >> (8 * $0)) & 0xFF) })
    }

    private static func le64(_ valor: UInt64) -> Data {
        Data((0..<8).map { UInt8((valor >> (8 * $0)) & 0xFF) })
    }
}
