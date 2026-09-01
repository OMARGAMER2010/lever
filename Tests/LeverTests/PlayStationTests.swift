import Foundation
import LeverCore

/// Pruebas de la familia PlayStation: el `PARAM.SFO` que llevan dentro cuatro máquinas, el sistema
/// de archivos de un disco, la cabecera de un paquete y el arranque de un disco de PS2.
///
/// Todo fabricado byte a byte, como el resto del proyecto: la marca `\0PSF` con sus dos tablas, un
/// disco con su descriptor de volumen en el sector 16 y su carpeta raíz detrás, y el mismo disco
/// otra vez en sectores de 2352 para comprobar que se lee igual.
enum PlayStationTests {
    static func run() throws {
        try testReadsTheMetadataEveryPlayStationCarries()
        try testTheSameTwoLettersMeanOppositeThings()
        try testTheIdentifierSaysWhichMachine()
        try testWalksTheFileSystemOfADisc()
        try testARawDumpReadsTheSame()
        try testReadsTheSerialFromTheBootFile()
        try testReadsThePackageHeaderOfBothGenerations()
        try testSaysPlainlyThatThereIsNoEmulator()
        try testRecognisesAGameFolderAndWhatToLaunch()
        try testTheMachineListIsHonestAboutWhatItCannotDo()
        try testFindsTheFirmwareWhereTheEmulatorKeepsIt()
    }

    // MARK: - PARAM.SFO

    /// El hallazgo del sprint: esto va **sin cifrar** y lo llevan PS3, PS4, PSP y Vita. Lo que en
    /// la consola híbrida costaba un `prod.keys`, aquí sale del propio archivo.
    private static func testReadsTheMetadataEveryPlayStationCarries() throws {
        let sfo = ParamSFO(paramSfo([
            ("APP_VER", .texto("01.03")),
            ("CATEGORY", .texto("DG")),
            ("PARENTAL_LEVEL", .número(5)),
            ("TITLE", .texto("Un juego con acentos: ñ")),
            ("TITLE_ID", .texto("BLUS30443"))
        ]))
        try expect(sfo?.title == "Un juego con acentos: ñ", "el título es el que puso quien lo hizo")
        try expect(sfo?.titleId == "BLUS30443", "y el identificador su identidad de verdad")
        try expect(sfo?.version == "01.03", "la versión sale de APP_VER")
        try expect(sfo?.number("PARENTAL_LEVEL") == 5, "y los enteros se leen como enteros")
        try expect(sfo?["PARENTAL_LEVEL"] == "5", "aunque también se puedan pedir como texto")
        try expect(sfo?.keys.count == 5, "las cinco claves")

        // La marca lleva un cero delante, y olvidarlo es no reconocer ningún archivo.
        var sinCero = paramSfo([("TITLE", .texto("x"))])
        sinCero[0] = 0x20
        try expect(ParamSFO(sinCero) == nil, "sin el cero de la marca no es un PARAM.SFO")
        try expect(ParamSFO([UInt8](repeating: 0, count: 64)) == nil, "y un archivo en blanco tampoco")
    }

    /// **El error que este código existe para evitar.** `GD` en mayúscula es un parche de PS3;
    /// `gd` en minúscula es el juego de una PS4. El mismo par de letras significando lo contrario,
    /// y lo único que los separa es la caja. Normalizar a mayúsculas —que es el reflejo— convierte
    /// todos los juegos de PS4 en parches.
    private static func testTheSameTwoLettersMeanOppositeThings() throws {
        func categoría(_ valor: String) -> ContentKind? {
            ParamSFO(paramSfo([("CATEGORY", .texto(valor)), ("TITLE_ID", .texto("BLUS30443"))]))?.kind
        }
        try expect(categoría("GD") == .patch, "GD en mayúscula es «game data»: una actualización")
        try expect(categoría("gd") == .application, "gd en minúscula es el juego de una PS4")
        try expect(categoría("DG") == .application, "DG es un juego de disco de PS3")
        try expect(categoría("HG") == .application, "HG es uno bajado de la tienda")
        try expect(categoría("AC") == .addOn, "AC es contenido añadido")
        try expect(categoría("gp") == .patch, "y gp el parche de una PS4")
        try expect(categoría("SD") == .other, "unos datos guardados no son un juego")

        // Sin categoría se supone que es el juego: es lo que más veces acierta y no promete nada.
        try expect(ParamSFO(paramSfo([("TITLE", .texto("x"))]))?.kind == .application,
                   "sin CATEGORY se toma por el juego")
    }

    private static func testTheIdentifierSaysWhichMachine() throws {
        let esperado = [
            "CUSA01234": "ps4", "PPSA00123": "ps5", "PCSE00123": "vita", "VLUS00123": "vita",
            "ULUS10041": "psp", "BLUS30443": "ps3", "NPUB30910": "ps3"
        ]
        for (identificador, máquina) in esperado {
            try expect(ParamSFO.machineId(forTitleId: identificador) == máquina,
                       "\(identificador) tiene que ser de \(máquina)")
        }
        try expect(ParamSFO.machineId(forTitleId: "XX") == nil, "y algo que no lo es, no se adivina")
    }

    // MARK: - El disco

    private static func testWalksTheFileSystemOfADisc() throws {
        let fixture = try TemporaryFixture()
        let archivo = fixture.directoryURL.appendingPathComponent("juego.iso")
        let sfo = paramSfo([("TITLE", .texto("Juego de disco")), ("TITLE_ID", .texto("BLES00123")),
                            ("CATEGORY", .texto("DG"))])
        try disco(sectorSize: 2048, carpetas: ["PS3_GAME": ["PARAM.SFO": Data(sfo)]],
                  archivos: ["SYSTEM.CNF": Data("BOOT2 = cdrom0:\\SLUS_202.30;1\n".utf8)])
            .write(to: archivo)

        guard let imagen = IsoImage(url: archivo) else {
            throw TestFailure(description: "la imagen tiene que abrirse")
        }
        try expect(imagen.sectorSize == 2048, "sectores normales")
        try expect(imagen.rootDirectory?.isDirectory == true, "la raíz es una carpeta")

        // El nombre lleva `;1` pegado detrás por el estándar: buscarlo sin recortar no encuentra
        // nada, y es un fallo silencioso porque el archivo sí está.
        guard let entrada = imagen.entry(atPath: "SYSTEM.CNF") else {
            throw TestFailure(description: "SYSTEM.CNF tiene que encontrarse pese al ;1")
        }
        let contenido = imagen.contents(of: entrada).map { String(decoding: $0, as: UTF8.self) }
        try expect(contenido?.contains("SLUS_202.30") == true, "y leerse entero")

        // Y una ruta con carpeta por medio.
        try expect(imagen.entry(atPath: "PS3_GAME/PARAM.SFO") != nil, "se entra en las carpetas")
        try expect(imagen.entry(atPath: "PS3_GAME/NO_EXISTE") == nil, "y lo que no está, no está")
        try expect(imagen.entry(atPath: "SYSTEM.CNF/DENTRO") == nil,
                   "un archivo no se puede recorrer como si fuera carpeta")

        let hechos = PlayStationInspector.inspect(archivo)
        try expect(hechos.machineId == "ps3", "un disco con PS3_GAME es de PS3")
        try expect(hechos.title == "Juego de disco", "con su título de dentro")
        try expect(hechos.evidence == .paramSfo, "leído del PARAM.SFO, que es lo más fiable")
        try expect(hechos.container == .discImage, "y viene en una imagen de disco")
    }

    /// **Un sector no siempre mide 2048.** Un volcado en crudo mide 2352 y los datos no son
    /// contiguos: van en trozos con 304 bytes de relleno entre medias. Leerlo como si fuera un
    /// `.iso` no falla, devuelve bytes desplazados.
    private static func testARawDumpReadsTheSame() throws {
        let fixture = try TemporaryFixture()
        let crudo = fixture.directoryURL.appendingPathComponent("volcado.bin")
        try disco(sectorSize: 2352, dataOffset: 24,
                  archivos: ["SYSTEM.CNF": Data("BOOT2 = cdrom0:\\SCES_509.16;1\n".utf8)])
            .write(to: crudo)

        guard let imagen = IsoImage(url: crudo) else {
            throw TestFailure(description: "un volcado en crudo también es una imagen")
        }
        try expect(imagen.sectorSize == 2352, "se detecta el sector grande")
        try expect(imagen.dataOffset == 24, "y dónde empiezan los datos dentro de él")

        guard let entrada = imagen.entry(atPath: "SYSTEM.CNF"),
              let datos = imagen.contents(of: entrada) else {
            throw TestFailure(description: "el archivo tiene que leerse igual")
        }
        try expect(String(decoding: datos, as: UTF8.self).contains("SCES_509.16"),
                   "y su contenido salir sin desplazar")

        try expect(PlayStationInspector.inspect(crudo).machineId == "ps2", "es un disco de PS2")
    }

    private static func testReadsTheSerialFromTheBootFile() throws {
        // El valor viene con la unidad delante y el `;1` detrás; el número de serie de verdad lleva
        // guion y no lleva punto.
        try expect(PlayStationInspector.serial(fromBootPath: "cdrom0:\\SLUS_202.30;1") == "SLUS-20230",
                   "cdrom0:\\SLUS_202.30;1 es el SLUS-20230")
        try expect(PlayStationInspector.serial(fromBootPath: " cdrom:\\SCES_509.16;1 ") == "SCES-50916",
                   "con espacios alrededor también")
        try expect(PlayStationInspector.serial(fromBootPath: "cdrom0:\\X;1") == nil,
                   "y algo que no tiene forma de serie no se inventa")

        // `BOOT2` es de PS2 y `BOOT` a secas de PS1. Es lo único que los separa desde fuera.
        try expect(PlayStationInspector.bootSerial(inSystemCnf: "BOOT2 = cdrom0:\\SLUS_202.30;1")?.machine == "ps2",
                   "BOOT2 es de PS2")
        try expect(PlayStationInspector.bootSerial(inSystemCnf: "BOOT = cdrom:\\SLUS_005.56;1")?.machine == "ps1",
                   "y BOOT a secas de PS1")
        try expect(PlayStationInspector.bootSerial(inSystemCnf: "VER = 1.00") == nil, "lo demás no dice nada")
    }

    // MARK: - Los paquetes

    /// El identificador de contenido está en 0x30 en PS3 y en 0x40 en PS4. Saber la generación para
    /// decidir dónde mirar sería circular —la generación sale justo de ahí—, así que se prueban los
    /// dos sitios.
    private static func testReadsThePackageHeaderOfBothGenerations() throws {
        let fixture = try TemporaryFixture()

        let deTres = fixture.directoryURL.appendingPathComponent("ps3.pkg")
        try paquete(contentId: "UP0001-BLUS30443_00-0000000000000000", at: 0x30).write(to: deTres)
        let tres = PlayStationInspector.inspect(deTres)
        try expect(tres.machineId == "ps3", "BLUS es de PS3")
        try expect(tres.titleId == "BLUS30443", "el identificador va entre el guion y el guion bajo")
        try expect(tres.evidence == .packageHeader, "y sale de la cabecera, sin descifrar nada")

        let deCuatro = fixture.directoryURL.appendingPathComponent("ps4.pkg")
        try paquete(contentId: "UP4497-CUSA01234_00-ARKNIGHTS0000000", at: 0x40).write(to: deCuatro)
        try expect(PlayStationInspector.inspect(deCuatro).titleId == "CUSA01234",
                   "en PS4 el mismo dato está veinte bytes más allá")
        try expect(PlayStationInspector.inspect(deCuatro).machineId == "ps4", "y CUSA es de PS4")

        // Sin la marca no es un paquete, se llame como se llame.
        let mentira = fixture.directoryURL.appendingPathComponent("mentira.pkg")
        try Data(repeating: 0x41, count: 1024).write(to: mentira)
        try expect(!PlayStationInspector.inspect(mentira).isRecognised, "llamarse .pkg no basta")
    }

    /// Alguien que llega con un juego de PS5 merece que se le diga que no existe emulador, en vez
    /// de que su archivo desaparezca sin comentarios.
    private static func testSaysPlainlyThatThereIsNoEmulator() throws {
        let fixture = try TemporaryFixture()
        let cinco = fixture.directoryURL.appendingPathComponent("ps5.pkg")
        try paquete(contentId: "UP0001-PPSA01234_00-0000000000000000", at: 0x40).write(to: cinco)

        let hechos = PlayStationInspector.inspect(cinco)
        try expect(hechos.machineId == "ps5", "PPSA es de PS5 y se reconoce")
        try expect(hechos.isRecognised, "el archivo está bien: lo que falta es con qué abrirlo")
        try expect(hechos.hasNoEmulator, "y de esta máquina no hay ninguno")
        try expect(hechos.machine?.emulators.isEmpty == true, "la lista no ofrece ninguno")
    }

    // MARK: - Las carpetas

    /// Un juego de PS3 o PS4 volcado de su disco es una **carpeta**, no un archivo. Y lo que hay
    /// que lanzar está dentro: darle la carpeta al emulador no hace nada y no dice por qué.
    private static func testRecognisesAGameFolderAndWhatToLaunch() throws {
        let fixture = try TemporaryFixture()
        let gestor = FileManager.default

        let juego = fixture.directoryURL.appendingPathComponent("Mi Juego", isDirectory: true)
        let usrdir = juego.appendingPathComponent("PS3_GAME/USRDIR", isDirectory: true)
        try gestor.createDirectory(at: usrdir, withIntermediateDirectories: true)
        try Data(paramSfo([("TITLE", .texto("Juego de carpeta")), ("TITLE_ID", .texto("BLES01234")),
                           ("CATEGORY", .texto("DG")), ("APP_VER", .texto("01.01"))]))
            .write(to: juego.appendingPathComponent("PS3_GAME/PARAM.SFO"))
        try Data("eboot".utf8).write(to: usrdir.appendingPathComponent("EBOOT.BIN"))

        let hechos = PlayStationInspector.inspect(juego)
        try expect(hechos.machineId == "ps3", "la carpeta es de PS3")
        try expect(hechos.container == .folder, "y viene como carpeta")
        try expect(hechos.title == "Juego de carpeta", "con su título")
        try expect(hechos.version == "01.01", "y su versión")
        try expect(hechos.launchTarget?.lastPathComponent == "EBOOT.BIN",
                   "lo que se lanza es el ejecutable de dentro, no la carpeta")

        // Sin ejecutable se lanza la carpeta, que es mejor que no lanzar nada.
        try gestor.removeItem(at: usrdir.appendingPathComponent("EBOOT.BIN"))
        try expect(PlayStationInspector.inspect(juego).launchTarget == juego,
                   "sin ejecutable, la carpeta")

        // PS4 y Vita comparten la forma del árbol y los separa el identificador de dentro.
        let deCuatro = fixture.directoryURL.appendingPathComponent("Otro", isDirectory: true)
        try gestor.createDirectory(at: deCuatro.appendingPathComponent("sce_sys"),
                                   withIntermediateDirectories: true)
        try Data(paramSfo([("TITLE_ID", .texto("PCSE00123")), ("CATEGORY", .texto("gd"))]))
            .write(to: deCuatro.appendingPathComponent("sce_sys/param.sfo"))
        let vita = PlayStationInspector.inspect(deCuatro)
        try expect(vita.machineId == "vita", "el identificador manda sobre la forma de la carpeta")
        try expect(vita.kind == .application, "y en Vita gd en minúscula es el juego")
    }

    // MARK: - El registro de máquinas

    private static func testTheMachineListIsHonestAboutWhatItCannotDo() throws {
        var vistas: Set<String> = []
        for máquina in StandaloneMachines.all {
            try expect(vistas.insert(máquina.id).inserted, "identificador repetido: \(máquina.id)")
            // Una máquina sin emuladores tiene que decir que no los hay, y al revés.
            try expect(máquina.emulators.isEmpty == (máquina.maturity == .none),
                       "\(máquina.id): la madurez y la lista de emuladores tienen que decir lo mismo")
            for emulador in máquina.emulators {
                try expect(emulador.bundleNames.allSatisfy { $0.hasSuffix(".app") },
                           "\(emulador.id): un emulador de Mac es un .app")
            }
        }

        // La distinción que este sprint añade y que no existía: hay firmware que sale de la consola
        // y firmware que publica el fabricante. Tratarlos igual deja al usuario atascado sin motivo.
        let ps2 = StandaloneMachines.machine(id: "ps2")
        try expect(ps2?.firmware?.source == .console, "la BIOS de una PS2 sale de una PS2")
        guard case .vendor(let dónde)? = StandaloneMachines.machine(id: "ps3")?.firmware?.source else {
            throw TestFailure(description: "el firmware de PS3 lo publica Sony y hay que decir dónde")
        }
        try expect(dónde.hasPrefix("https://"), "con su dirección, para poder ir")
        try expect(StandaloneMachines.machine(id: "ps4")?.firmware == nil, "PS4 no pide firmware")
        try expect(StandaloneMachines.machine(id: "ps5")?.maturity == EmulationMaturity.none,
                   "y de PS5 no hay emulador")

        // PS1 y PSP no están aquí a propósito: esas sí las lleva un núcleo de libretro.
        try expect(StandaloneMachines.machine(id: "ps1") == nil, "PS1 va por RetroArch")
        try expect(RetroPlatforms.platform(id: "psx") != nil, "y tiene su núcleo desde antes")
        try expect(RetroPlatforms.platform(id: "psp") != nil, "la PSP también")
    }

    /// Un emulador al que le falta su BIOS no da un error: abre una ventana negra. Comprobarlo
    /// antes es la diferencia entre entender el problema y creer que el volcado está roto.
    private static func testFindsTheFirmwareWhereTheEmulatorKeepsIt() throws {
        let fixture = try TemporaryFixture()
        let gestor = FileManager.default
        guard let ps2 = StandaloneMachines.machine(id: "ps2"), let pcsx2 = ps2.emulators.first else {
            throw TestFailure(description: "la PS2 tiene que estar en la lista")
        }

        // Un emulador señalado a mano vale aunque no esté en la lista.
        let app = fixture.directoryURL.appendingPathComponent("Mi PCSX2.app", isDirectory: true)
        try gestor.createDirectory(at: app, withIntermediateDirectories: true)
        let elegido = StandaloneTools.locate(machine: ps2, preferring: app)
        try expect(elegido?.app == app, "se usa el que el usuario elige")
        try expect(elegido?.emulator.dataFolder == pcsx2.dataFolder,
                   "y hereda dónde busca su BIOS el emulador de referencia")

        try expect(StandaloneTools.locate(machine: StandaloneMachines.machine(id: "ps5")!) == nil,
                   "de una máquina sin emuladores no se encuentra ninguno")

        // Una máquina que no pide firmware lo tiene siempre «puesto».
        let ps4 = StandaloneMachines.machine(id: "ps4")!
        try expect(StandaloneTools.hasFirmware(machine: ps4, emulator: ps4.emulators[0]),
                   "PS4 no pide firmware, así que nunca falta")
    }

    // MARK: - Fabricar los formatos

    private enum Valor {
        case texto(String)
        case número(UInt32)
    }

    /// Un `PARAM.SFO`: la marca, dos tablas —claves y valores— y una entrada por dato. Los
    /// desplazamientos de cada entrada son relativos a **su** tabla, no al archivo.
    private static func paramSfo(_ datos: [(String, Valor)]) -> [UInt8] {
        var claves = [UInt8]()
        var valores = [UInt8]()
        var entradas = [UInt8]()

        for (clave, valor) in datos {
            let dóndeLaClave = claves.count
            claves += Array(clave.utf8) + [0]
            let dóndeElValor = valores.count

            let formato: UInt16
            let usado: UInt32
            let reservado: UInt32
            switch valor {
            case .texto(let texto):
                let bytes = Array(texto.utf8) + [0]
                valores += bytes
                formato = 0x0204
                usado = UInt32(bytes.count)
                reservado = usado
            case .número(let número):
                valores += (0..<4).map { UInt8((número >> (8 * $0)) & 0xFF) }
                formato = 0x0404
                usado = 4
                reservado = 4
            }

            entradas += le16(UInt16(dóndeLaClave)) + le16(formato)
            entradas += le32(usado) + le32(reservado) + le32(UInt32(dóndeElValor))
        }
        while claves.count % 4 != 0 { claves.append(0) }

        let dóndeLasClaves = UInt32(0x14 + entradas.count)
        let dóndeLosValores = dóndeLasClaves + UInt32(claves.count)
        var salida: [UInt8] = [0x00, 0x50, 0x53, 0x46]      // «\0PSF»
        salida += le32(0x0000_0101)                          // versión
        salida += le32(dóndeLasClaves) + le32(dóndeLosValores) + le32(UInt32(datos.count))
        return salida + entradas + claves + valores
    }

    /// Una imagen de disco: dieciséis sectores en blanco, el descriptor de volumen, la carpeta raíz
    /// y detrás lo que haya. Con el tamaño de sector que se pida, para poder probar los dos.
    private static func disco(
        sectorSize: Int, dataOffset: Int = 0,
        carpetas: [String: [String: Data]] = [:], archivos: [String: Data] = [:]
    ) -> Data {
        // El reparto de sectores: 16 el descriptor, 17 la raíz, y de 18 en adelante lo demás.
        var contenidoPorSector: [Int: [UInt8]] = [:]
        var siguiente = 18
        var registrosRaíz: [UInt8] = record(name: [0], sector: 17, size: 2048, isDirectory: true)
            + record(name: [1], sector: 17, size: 2048, isDirectory: true)

        for (nombre, datos) in archivos.sorted(by: { $0.key < $1.key }) {
            contenidoPorSector[siguiente] = [UInt8](datos)
            registrosRaíz += record(name: Array("\(nombre);1".utf8), sector: UInt32(siguiente),
                                    size: Int64(datos.count), isDirectory: false)
            siguiente += 1
        }
        for (carpeta, dentro) in carpetas.sorted(by: { $0.key < $1.key }) {
            let dóndeLaCarpeta = siguiente
            siguiente += 1
            var registros: [UInt8] = record(name: [0], sector: UInt32(dóndeLaCarpeta), size: 2048, isDirectory: true)
                + record(name: [1], sector: 17, size: 2048, isDirectory: true)
            for (nombre, datos) in dentro.sorted(by: { $0.key < $1.key }) {
                contenidoPorSector[siguiente] = [UInt8](datos)
                registros += record(name: Array("\(nombre);1".utf8), sector: UInt32(siguiente),
                                    size: Int64(datos.count), isDirectory: false)
                siguiente += 1
            }
            contenidoPorSector[dóndeLaCarpeta] = registros
            registrosRaíz += record(name: Array(carpeta.utf8), sector: UInt32(dóndeLaCarpeta),
                                    size: 2048, isDirectory: true)
        }
        contenidoPorSector[17] = registrosRaíz

        // El descriptor de volumen, con el registro de la raíz metido en su sitio fijo.
        var descriptor = [UInt8](repeating: 0, count: 2048)
        descriptor[0] = 0x01
        for (índice, byte) in Array("CD001".utf8).enumerated() { descriptor[1 + índice] = byte }
        descriptor[6] = 0x01
        for (índice, byte) in record(name: [0], sector: 17, size: 2048, isDirectory: true).enumerated()
        where 156 + índice < descriptor.count {
            descriptor[156 + índice] = byte
        }
        contenidoPorSector[16] = descriptor

        var salida = Data(repeating: 0, count: (siguiente + 1) * sectorSize)
        for (sector, bytes) in contenidoPorSector {
            let desde = sector * sectorSize + dataOffset
            let cuántos = min(bytes.count, 2048)
            salida.replaceSubrange(desde..<desde + cuántos, with: bytes.prefix(cuántos))
        }
        return salida
    }

    /// Un registro de carpeta. Mide 33 más el nombre, y **se rellena hasta un número par**: el
    /// estándar lo exige, y sin el relleno el siguiente registro empieza un byte corrido.
    private static func record(name: [UInt8], sector: UInt32, size: Int64, isDirectory: Bool) -> [UInt8] {
        var registro = [UInt8](repeating: 0, count: 33 + name.count)
        registro[2..<6] = ArraySlice(le32(sector))
        registro[10..<14] = ArraySlice(le32(UInt32(size)))
        registro[25] = isDirectory ? 0x02 : 0x00
        registro[32] = UInt8(name.count)
        registro.replaceSubrange(33..., with: name)
        if registro.count % 2 != 0 { registro.append(0) }
        registro[0] = UInt8(registro.count)
        return registro
    }

    /// Un paquete de la tienda: la marca y el identificador de contenido donde le toque a su
    /// generación.
    private static func paquete(contentId: String, at offset: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        for (índice, byte) in Array("\u{7F}CNT".utf8).enumerated() { bytes[índice] = byte }
        for (índice, byte) in Array(contentId.utf8).enumerated() where offset + índice < bytes.count {
            bytes[offset + índice] = byte
        }
        return Data(bytes)
    }

    private static func le16(_ valor: UInt16) -> [UInt8] { (0..<2).map { UInt8((valor >> (8 * $0)) & 0xFF) } }
    private static func le32(_ valor: UInt32) -> [UInt8] { (0..<4).map { UInt8((valor >> (8 * $0)) & 0xFF) } }
}
