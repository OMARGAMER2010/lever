import Darwin
import Foundation
import LeverCore

/// Prueba de integración de los `.xci`: la copia de un cartucho de la consola híbrida.
///
/// Lo que separa esta prueba de `SwitchTests` es el tamaño. Allí las cabeceras se fabrican y pesan
/// unos cientos de bytes; aquí se lee un volcado de verdad de varios gigas, y eso saca a la luz
/// tres cosas que un archivo de mentira no puede:
///
/// 1. Que el reconocimiento no se lleva el archivo a memoria. Con una cabecera de prueba, leer de
///    más y leerlo entero cuestan lo mismo y ninguna prueba nota la diferencia.
/// 2. Que la validación es superficial de verdad: se reconoce el archivo **sin llaves**, sin
///    descifrar y sin extraer nada.
/// 3. Que un cartucho no se lee como un paquete de la tienda. La raíz de un `.xci` solo lista
///    particiones; el juego está una vuelta más adentro, en `secure`.
///
/// El archivo lo pone quien ejecuta la prueba, en `LEVER_XCI_PATH`. Sin esa variable la prueba se
/// salta: el proyecto no trae —ni debe traer— el volcado de nadie.
enum XciIntegrationTests {
    static func run() throws {
        // Estas tres no necesitan ningún archivo grande y por eso corren siempre: son las que
        // protegen el camino de entrada, que es donde estaba el fallo.
        try testTheExtensionIsRegisteredAndCaseInsensitive()
        try testAFileNameNeverBecomesPartOfAShellCommand()
        try testAPackageThatIsOnlyAnExtensionIsReportedAsBroken()
        try testTheFourWaysThisCanGoWrongAreEachSaidDifferently()

        guard let ruta = ProcessInfo.processInfo.environment["LEVER_XCI_PATH"] else {
            print("SKIP XciIntegrationTests: define LEVER_XCI_PATH con la ruta de un .xci")
            return
        }
        let archivo = URL(fileURLWithPath: ruta)
        guard FileManager.default.isReadableFile(atPath: archivo.path) else {
            throw TestFailure(description: "LEVER_XCI_PATH no se puede leer: \(archivo.path)")
        }
        try testARealCartridgeIsRecognisedWithoutKeys(archivo)
        try testReadingItDoesNotLoadItIntoMemory(archivo)
        try testItRoutesToTheConsolesTab(archivo)
        try testItSaysWhetherTheCartridgeCarriesFirmware(archivo)
    }

    // MARK: - El camino de entrada

    /// La extensión está en el registro, y da igual cómo venga escrita.
    ///
    /// Lo segundo no es una florituras: los volcados viejos vienen en mayúsculas más a menudo de lo
    /// que parece, y un `.XCI` que no entra por el selector de archivos es indistinguible de un
    /// `.xci` que no está soportado.
    private static func testTheExtensionIsRegisteredAndCaseInsensitive() throws {
        try expect(
            SwitchContainer.allCases.map(\.fileExtension).contains("xci"),
            "el registro canónico de envoltorios tiene que incluir el .xci"
        )
        try expect(
            StandaloneMachines.allExtensions.contains("xci"),
            "y la máquina que lo ejecuta tiene que reclamarlo, o no llega a la pestaña de consolas"
        )
        try expect(
            SupportedFileKind.rom.extensions.contains("xci"),
            "y la lista de formatos admitidos tiene que traerlo"
        )

        for escrito in ["juego.xci", "juego.XCI", "juego.Xci", "juego.xCI"] {
            let url = URL(fileURLWithPath: "/tmp/\(escrito)")
            try expect(
                SupportedFileKind.rom.accepts(url),
                "«\(escrito)» tiene que entrar: la caja de las letras no decide nada"
            )
            try expect(
                SwitchContainer.named(url) == .xci,
                "«\(escrito)» promete un cartucho, venga como venga escrito"
            )
        }

        // Y lo que no es: un cartucho no es un programa nativo. Si entrara por aquí, Lever
        // intentaría trasladarlo con Wine en vez de dárselo a un emulador.
        let cartucho = URL(fileURLWithPath: "/tmp/juego.xci")
        try expect(!SupportedFileKind.exe.accepts(cartucho), "un .xci no es un ejecutable nativo")
        try expect(!SupportedFileKind.rar.accepts(cartucho), "ni un comprimido que se pueda extraer")
        try expect(
            StandaloneMachines.candidates(forExtension: "xci").contains { $0.id == "switch" },
            "lo ejecuta un programa aparte, y por eso está en el registro de máquinas de programa aparte"
        )
    }

    /// El nombre del archivo nunca acaba dentro del texto de una orden.
    ///
    /// La única orden de todo el camino de un `.xci` que pasa por un intérprete es la de
    /// descomprimir, y sus argumentos van como parámetros posicionales. Esta prueba lo fija: con un
    /// nombre lleno de metacaracteres, el nombre tiene que aparecer **entero, en su propio hueco**,
    /// y el guion no puede contener ni un trozo de él.
    private static func testAFileNameNeverBecomesPartOfAShellCommand() throws {
        let hostil = "juego`whoami` ;rm -rf $HOME& \"comillas\" 'y más'.xci"
        let paquete = URL(fileURLWithPath: "/tmp/\(hostil)")
        let orden = SwitchTools.decompressCommand(
            package: paquete, from: 0x4000, length: 1024,
            into: URL(fileURLWithPath: "/tmp/salida.nsp"),
            zstd: URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
        )

        guard let guion = orden.arguments.first(where: { $0.contains("zstd") == false && $0.contains("tail") }) else {
            throw TestFailure(description: "la orden tiene que llevar un guion con el recorte")
        }
        try expect(
            !guion.contains(hostil) && !guion.contains("whoami") && !guion.contains("rm -rf"),
            "el guion no puede llevar dentro nada del nombre del archivo"
        )
        try expect(
            orden.arguments.contains(paquete.path),
            "la ruta va en su propio argumento, que es lo que impide que el intérprete la mire"
        )
        // Los parámetros posicionales del guion son la prueba de que se pasan por fuera.
        try expect(guion.contains("$2"), "y el guion se refiere a ella por su número, no por su texto")
    }

    /// Un archivo que solo tiene la extensión se dice con su nombre.
    ///
    /// Un `.xci` pesa gigas y casi siempre llega por una descarga larga. Cuando no se reconoce, lo
    /// que ha pasado casi seguro es que se quedó a medias, y «no se reconoce el archivo» manda a
    /// buscar el fallo donde no está.
    private static func testAPackageThatIsOnlyAnExtensionIsReportedAsBroken() throws {
        let fixture = try TemporaryFixture()

        // Bastante grande para no ser un despiste y sin ninguna cabecera válida: es exactamente lo
        // que deja una descarga cortada por la mitad.
        let aMedias = fixture.directoryURL.appendingPathComponent("cortado.xci")
        try Data(repeating: 0, count: 0x40000).write(to: aMedias)
        try expect(
            !SwitchInspector.inspect(aMedias).isRecognised,
            "sin la marca HEAD no es un cartucho, se llame como se llame"
        )
        try expect(
            FileRouter.looksLikeBrokenSwitchPackage(aMedias),
            "y hay que poder decir que prometía serlo, que es lo que orienta al usuario"
        )
        try expect(
            FileRouter.route(for: aMedias) == nil,
            "no se le entrega a nadie: no hay nada que abrir"
        )

        // Y lo contrario, que es lo que evita que el aviso salga donde no toca.
        let comprimido = fixture.directoryURL.appendingPathComponent("cosas.zip")
        try Data(repeating: 0, count: 16).write(to: comprimido)
        try expect(
            !FileRouter.looksLikeBrokenSwitchPackage(comprimido),
            "un .zip cualquiera no prometía ser un cartucho"
        )
    }

    /// Las cuatro cosas que pueden salir mal se dicen cada una con su nombre.
    ///
    /// Son cuatro y no una porque el arreglo de cada una es distinto: instalar un emulador, volver
    /// a bajar el archivo, conseguir un `prod.keys`, o mirar qué dijo el emulador al abrirse. Un
    /// único «no se pudo abrir el juego» las junta todas y no sirve para ninguna.
    private static func testTheFourWaysThisCanGoWrongAreEachSaidDifferently() throws {
        // 1 · Falta el programa que lo ejecuta. Con un `.app` que no existe, no hay runtime: es
        //     exactamente lo que ve quien todavía no ha instalado ningún emulador.
        let sinInstalar = StandaloneMachine(
            id: "prueba", name: "Prueba", family: "prueba", maturity: .experimental,
            emulators: [StandaloneEmulator(
                id: "fantasma", name: "Fantasma",
                bundleNames: ["NoExisteEsteEmulador-\(UUID().uuidString).app"], dataFolder: "fantasma"
            )],
            extensions: ["xci"]
        )
        try expect(
            StandaloneTools.locate(machine: sinInstalar) == nil,
            "sin el .app instalado no hay con qué abrirlo, y hay que poder decirlo antes de lanzar"
        )

        // 2 · Falta la configuración. Reconocer el archivo no necesita llaves, pero jugarlo sí, y
        //     la diferencia entre las dos cosas es justo lo que hay que enseñar.
        let sinLlaves = SwitchFacts(
            container: .xci, evidence: .container,
            entries: [SwitchEntry(name: "a.nca", offset: 0x200, size: 0x100)],
            bytes: 0x300, missingKeys: SwitchKeyFile.required, requiredKeyGeneration: 17
        )
        try expect(sinLlaves.isRecognised, "el cartucho se reconoce igual: eso no depende de las llaves")
        try expect(!sinLlaves.missingKeys.isEmpty, "pero hay que decir qué falta para poder jugarlo")
        try expect(
            sinLlaves.keysAreTooOld(available: 12),
            "y un prod.keys viejo para un juego nuevo es un caso aparte, no «faltan las llaves»"
        )
        try expect(
            !sinLlaves.keysAreTooOld(available: 20),
            "con llaves suficientes no se avisa de nada"
        )

        // 3 · El archivo no es lo que dice ser. Cubierto arriba, y se comprueba aquí que no se
        //     confunde con el caso 1: son mensajes distintos porque son arreglos distintos.
        // 4 · El lanzamiento falló. Lo dice el emulador, y Lever repite lo que dijo.
        //
        // Los cuatro textos tienen que existir en los dos idiomas y no repetirse: dos estados con
        // el mismo texto son, para el usuario, un solo estado.
        for idioma in Language.allCases {
            let s = Strings.table(for: idioma)
            let textos: [String] = [
                s[.switchEmulatorMissingBody],
                s[.errBrokenSwitchPackage],
                s[.switchKeysMissingBody],
                s[.errNoSwitchEmulator]
            ]
            for texto in textos {
                try expect(!texto.isEmpty, "ningún estado puede quedarse sin texto en \(idioma)")
            }
            try expect(
                Set(textos).count == textos.count,
                "los estados tienen que decir cosas distintas en \(idioma)"
            )
        }
    }

    // MARK: - El archivo de verdad

    /// Se reconoce, y se reconoce **sin llaves**.
    ///
    /// Es la forma de comprobar que la validación es superficial. Si hiciera falta descifrar algo
    /// para saber que esto es un cartucho, sin `prod.keys` no se reconocería, y aquí se reconoce:
    /// la tabla de particiones va en claro porque la consola la necesita antes de descifrar nada.
    private static func testARealCartridgeIsRecognisedWithoutKeys(_ archivo: URL) throws {
        let bytes = archivo.fileSizeInBytes ?? 0
        let hechos = SwitchInspector.inspect(archivo, keys: nil)

        try expect(hechos.isRecognised, "el volcado tiene que reconocerse")
        try expect(hechos.container == .xci, "y como copia de cartucho, no como paquete de la tienda")
        try expect(!hechos.container!.isCompressed, "un .xci no viene comprimido")
        try expect(hechos.container!.isCartridge, "y sí viene de un cartucho")
        try expect(!hechos.entries.isEmpty, "la partición «secure» tiene que traer sus piezas")
        try expect(
            hechos.entries.contains { $0.isContent },
            "y entre ellas, al menos un .nca, que es donde está el juego"
        )
        try expect(hechos.bytes == bytes, "el tamaño leído es el del archivo")

        // Sin llaves no se llega a la cabecera de las piezas. Que lo diga —en vez de dejar huecos
        // en blanco— es la diferencia entre entender el problema y creer que el volcado está roto.
        try expect(
            hechos.evidence != .ncaHeader,
            "sin llaves no se puede leer la cabecera de ninguna pieza"
        )
        try expect(!hechos.missingKeys.isEmpty, "y hay que decir cuáles faltan")
        try expect(!hechos.needsDecompression, "no hay nada que rehacer: las piezas están enteras")

        // Ninguna pieza puede caer fuera del archivo. Es la comprobación que descubre una suma mal
        // hecha del origen de los datos, que si no da entradas de aspecto correcto y basura dentro.
        for pieza in hechos.entries {
            try expect(
                pieza.offset >= 0 && pieza.offset + pieza.size <= bytes,
                "la pieza «\(pieza.name)» tiene que caber dentro del archivo"
            )
        }

        print("""
              [xci] \(archivo.lastPathComponent)
                    \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · \
              \(hechos.entries.count) piezas · prueba: \(hechos.evidence) · \
              faltan: \(hechos.missingKeys.joined(separator: ", "))
              """)
    }

    /// Leerlo no se lo lleva a memoria.
    ///
    /// La comprobación es la memoria del propio proceso antes y después. Un `.xci` de seis gigas
    /// leído entero se nota; una cabecera de doscientos bytes, no. El margen es deliberadamente
    /// generoso —lo que se persigue es un error de bulto, no unos kilobytes— pero cualquier
    /// `Data(contentsOf:)` que se colara en este camino lo rompería por varios órdenes de magnitud.
    private static func testReadingItDoesNotLoadItIntoMemory(_ archivo: URL) throws {
        let tamaño = archivo.fileSizeInBytes ?? 0
        let margen: Int64 = 64 * 1024 * 1024

        // Primero se comprueba el propio medidor. Sin esto la prueba sería de las peores que hay:
        // si `task_info` fallara devolvería cero siempre, la diferencia sería cero siempre, y una
        // lectura del archivo entero pasaría la prueba tan campante.
        try expectTheMeterNoticesRealMemory()

        let antes = footprint()
        let hechos = SwitchInspector.inspect(archivo, keys: nil)
        let después = footprint()
        try expect(hechos.isRecognised, "el archivo se tiene que haber leído de verdad")

        let crecimiento = después - antes
        try expect(
            crecimiento < margen,
            "leer el cartucho creció \(crecimiento / (1024 * 1024)) MB de un archivo de \(tamaño / (1024 * 1024)) MB"
        )
        print("[xci] memoria del proceso: +\(crecimiento / 1024) KB para un archivo de \(tamaño / (1024 * 1024)) MB")
    }

    /// Que el medidor mide: se reservan 128 MB de verdad y se comprueba que los ve.
    ///
    /// Se tocan todas las páginas porque reservar no es ocupar: sin escribir en ellas, el sistema
    /// no las respalda y la memoria física no sube. Es justo el detalle que dejaría el control sin
    /// valor.
    private static func expectTheMeterNoticesRealMemory() throws {
        let cuántos = 128 * 1024 * 1024
        let antes = footprint()
        try expect(antes > 0, "el medidor de memoria no contesta: task_info ha fallado")

        var visto: Int64 = 0
        do {
            var bloque = [UInt8](repeating: 0, count: cuántos)
            for página in stride(from: 0, to: cuántos, by: 4096) { bloque[página] = 1 }
            visto = footprint() - antes
            // Se usa después de medir para que el optimizador no pueda tirar el bloque entero.
            try expect(bloque[0] == 1, "el bloque de control tiene que seguir escrito")
        }
        try expect(
            visto > Int64(cuántos) / 2,
            "el medidor no vio 128 MB recién reservados (vio \(visto / (1024 * 1024)) MB): no sirve para lo que sigue"
        )
    }

    /// Entra por la pestaña de consolas, que es lo que la ventana enseña.
    ///
    /// El fallo que esto fija: el modelo aceptaba el `.xci` y la ventana enseñaba la pestaña de
    /// comprimidos, porque cada uno tenía su propia lista de comprobaciones y la de la ventana solo
    /// preguntaba por ROMs. Con `FileRouter` es una sola lista y las dos preguntan a la misma.
    private static func testItRoutesToTheConsolesTab(_ archivo: URL) throws {
        try expect(
            FileRouter.route(for: archivo) == .rom,
            "un cartucho va a la pestaña de consolas, no a la de comprimidos"
        )
        try expect(
            !FileRouter.looksLikeBrokenSwitchPackage(archivo),
            "y no es un paquete a medias: se ha reconocido entero"
        )
    }

    /// Dice si el cartucho trae el firmware dentro.
    ///
    /// Un `.xci` lleva tres particiones y el firmware va en `update`. Lever solo leía `secure` —el
    /// juego— así que no podía distinguir un volcado entero de uno recortado, y eso es justo lo que
    /// decide si el emulador va a poder sacar el firmware del propio archivo o si hay que buscarlo
    /// fuera. Con el volcado recortado delante, la respuesta tiene que ser que no lo trae.
    private static func testItSaysWhetherTheCartridgeCarriesFirmware(_ archivo: URL) throws {
        let hechos = SwitchInspector.inspect(archivo, keys: nil)
        guard let actualización = hechos.cartridgeUpdate else {
            throw TestFailure(description: "de un cartucho hay que poder decir si trae firmware")
        }
        switch actualización {
        case .included(let bytes):
            try expect(bytes > 0, "si dice que lo trae, tiene que medir algo")
            print("[xci] el cartucho trae firmware dentro: \(bytes / (1024 * 1024)) MB")
        case .trimmed:
            print("[xci] volcado recortado: no trae firmware dentro")
        }
        try expect(
            actualización.hasFirmware == (actualización != .trimmed),
            "las dos formas de preguntarlo tienen que contestar lo mismo"
        )
    }

    // MARK: - Medir la memoria

    /// La memoria física que el proceso tiene ocupada ahora mismo.
    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var cuenta = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let resultado = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cuenta)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &cuenta)
            }
        }
        return resultado == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
