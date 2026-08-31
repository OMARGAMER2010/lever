import Foundation
import LeverCore

/// Pruebas del reconocimiento de ROMs y de la configuración con la que se lanza el emulador.
///
/// Las cabeceras se fabrican byte a byte, como en `ApkInspectorTests`: son las de verdad —el «NES»
/// del principio, el logotipo que la Game Boy comprueba al arrancar, la suma de la Super Nintendo—
/// y no hace falta ninguna ROM de nadie para comprobar que se leen.
enum EmulationTests {
    static func run() throws {
        try testEveryPlatformHasACoreAndAnArchitecture()
        try testRecognisesEachConsoleByItsHeader()
        try testFallsBackToTheExtensionAndSaysSo()
        try testDoesNotInventAConsoleForAStrangeFile()
        try testReadsTheArchitectureOfARealBinary()
        try testBuildsTheCoreDownloadAddress()
        try testWritesTheInputLinesRetroArchUnderstands()
        try testTheDefaultLayoutIsTheOneEverybodyKnows()
        try testTheMostSpecificProfileWins()
        try testOnlyOffersTheButtonsTheConsoleHas()
        try testTranslatesMacKeysToRetroArchNames()
    }

    // MARK: - Las máquinas

    private static func testEveryPlatformHasACoreAndAnArchitecture() throws {
        try expect(!RetroPlatforms.all.isEmpty, "tiene que haber máquinas")
        var vistas: Set<String> = []
        for máquina in RetroPlatforms.all {
            try expect(vistas.insert(máquina.id).inserted, "identificador repetido: \(máquina.id)")
            try expect(!máquina.core.isEmpty, "\(máquina.id) necesita un núcleo")
            try expect(!máquina.extensions.isEmpty, "\(máquina.id) necesita extensiones")
            try expect(máquina.coreFileName.hasSuffix("_libretro.dylib"),
                       "el archivo del núcleo se llama como lo publica libretro: \(máquina.coreFileName)")
        }
        // Las seis clases de máquina del plan tienen que estar cubiertas.
        let clases = Set(RetroPlatforms.all.map(\.architecture))
        for clase in RetroArchitecture.allCases {
            try expect(clases.contains(clase), "falta alguna máquina de \(clase.rawValue)")
        }
        // Una consola de dos pantallas se maneja con el dedo: si no, el aviso no se enseña.
        try expect(RetroPlatforms.platform(id: "nds")?.hasTouch == true, "la DS es táctil")
        try expect(RetroPlatforms.platform(id: "nds")?.screens == 2, "y tiene dos pantallas")
        // Y una que necesita BIOS tiene que decirlo antes de que el usuario espere a una descarga.
        try expect(RetroPlatforms.platform(id: "psx")?.needsBios == true, "PlayStation necesita BIOS")
        try expect(RetroPlatforms.platform(id: "nes")?.needsBios == false, "la NES no")
    }

    // MARK: - Reconocer

    private static func testRecognisesEachConsoleByItsHeader() throws {
        let fixture = try TemporaryFixture()

        // NES: «NES» y un fin de fichero, que es la cabecera iNES.
        try comprueba(fixture, "cualquiera.bin", cabecera(en: [0: [0x4E, 0x45, 0x53, 0x1A]]),
                      esperada: "nes", nombre: nil)

        // Game Boy: el logotipo que la consola comprueba antes de ejecutar nada, y el título
        // justo detrás.
        var gb = cabecera(en: [0x104: [0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B]])
        escribe("TETRIS", en: &gb, desde: 0x134)
        try comprueba(fixture, "sinextension", gb, esperada: "gb", nombre: "TETRIS")

        // Game Boy Advance: su logotipo al principio y la marca fija de 0xB2.
        var gba = cabecera(en: [0x04: [0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21], 0xB2: [0x96]])
        escribe("METROID4", en: &gba, desde: 0xA0)
        try comprueba(fixture, "x.dat", gba, esperada: "gba", nombre: "METROID4")

        // Nintendo 64: la misma ROM circula en tres órdenes de bytes y las tres son válidas.
        for marca in [[0x80, 0x37, 0x12, 0x40], [0x37, 0x80, 0x40, 0x12], [0x40, 0x12, 0x37, 0x80]] {
            var n64 = cabecera(en: [0: marca.map(UInt8.init)])
            escribe("SUPER MARIO 64", en: &n64, desde: 0x20)
            try comprueba(fixture, "juego.rom", n64, esperada: "n64", nombre: "SUPER MARIO 64")
        }

        // Mega Drive: «SEGA» en 0x100 y el nombre del juego más abajo.
        var mega = [UInt8](repeating: 0x20, count: 0x200)
        escribe("SEGA MEGA DRIVE ", en: &mega, desde: 0x100)
        escribe("SONIC THE HEDGEHOG", en: &mega, desde: 0x120)
        try comprueba(fixture, "algo.bin", mega, esperada: "megadrive", nombre: "SONIC THE HEDGEHOG")

        // Master System: «TMR SEGA», que puede estar en tres sitios según el cartucho.
        try comprueba(fixture, "x.bin", cabecera(en: [0x7FF0: Array("TMR SEGA".utf8)]),
                      esperada: "sms", nombre: nil)

        // Nintendo DS: el CRC del logotipo, que en una ROM buena vale siempre 0xCF56.
        var nds = cabecera(en: [0x15C: [0x56, 0xCF]])
        escribe("MARIOKART", en: &nds, desde: 0)
        try comprueba(fixture, "x.dat", nds, esperada: "nds", nombre: "MARIOKART")

        // Super Nintendo: no tiene marca. Lo que la delata es su propia comprobación, la suma y
        // su complemento sumando 0xFFFF.
        var snes = [UInt8](repeating: 0x00, count: 0x10000)
        escribe("SUPER METROID       ", en: &snes, desde: 0x7FC0)
        snes[0x7FDC] = 0x34; snes[0x7FDD] = 0x12   // complemento 0x1234
        snes[0x7FDE] = 0xCB; snes[0x7FDF] = 0xED   // suma 0xEDCB, y 0x1234 + 0xEDCB = 0xFFFF
        try comprueba(fixture, "x.bin", snes, esperada: "snes", nombre: "SUPER METROID")
    }

    /// Hay máquinas que no marcan sus ROMs de ninguna forma. Ahí la extensión es lo único que
    /// queda, y eso se dice: es la diferencia entre saberlo y suponerlo.
    private static func testFallsBackToTheExtensionAndSaysSo() throws {
        let fixture = try TemporaryFixture()
        let cue = fixture.directoryURL.appendingPathComponent("juego.cue")
        try Data("FILE \"juego.bin\" BINARY\n".utf8).write(to: cue)

        let facts = RomInspector.inspect(cue)
        try expect(facts.platform?.id == "psx", "un .cue es de PlayStation: \(facts.platform?.id ?? "nada")")
        try expect(facts.evidence == .fileExtension,
                   "y hay que decir que la prueba es floja, porque un archivo mal nombrado se cuela")

        // Y cuando la cabecera sí habla, manda ella aunque la extensión diga otra cosa: un .bin
        // puede ser de media docena de máquinas.
        let mentiroso = fixture.directoryURL.appendingPathComponent("mentiroso.gba")
        try Data(cabecera(en: [0: [0x4E, 0x45, 0x53, 0x1A]])).write(to: mentiroso)
        let leído = RomInspector.inspect(mentiroso)
        try expect(leído.platform?.id == "nes",
                   "la cabecera manda sobre la extensión: \(leído.platform?.id ?? "nada")")
        try expect(leído.evidence == .header, "y por eso la prueba es buena")
    }

    private static func testDoesNotInventAConsoleForAStrangeFile() throws {
        let fixture = try TemporaryFixture()
        let cualquiera = try fixture.makeFile(named: "notas.txt")
        let facts = RomInspector.inspect(cualquiera)
        try expect(!facts.isRecognised, "un .txt no es el juego de ninguna consola")
        try expect(facts.evidence == .none, "y se dice que no se reconoce, en vez de elegir una")
    }

    // MARK: - RetroArch

    /// La arquitectura que hay que mirar es la del programa que va a cargar el núcleo, no la del
    /// Mac. Se comprueba contra binarios de verdad de este sistema.
    private static func testReadsTheArchitectureOfARealBinary() throws {
        // `/bin/echo` es universal en cualquier macOS moderno: trae las dos, y en un Mac de chip
        // Apple tiene que salir la nativa.
        let echo = URL(fileURLWithPath: "/bin/echo")
        if FileManager.default.isExecutableFile(atPath: echo.path) {
            let arquitectura = RetroTools.architecture(of: echo)
            try expect(arquitectura == "arm64" || arquitectura == "x86_64",
                       "de un binario universal sale una de las dos: \(arquitectura ?? "ninguna")")
        }

        // Y de algo que no es un binario, nada. No se adivina.
        let fixture = try TemporaryFixture()
        let texto = try fixture.makeFile(named: "cosa.txt")
        try expect(RetroTools.architecture(of: texto) == nil, "un archivo de texto no tiene arquitectura")
    }

    private static func testBuildsTheCoreDownloadAddress() throws {
        let arm = RetroTools.coreURL(core: "nestopia", architecture: "arm64").absoluteString
        try expect(arm == "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/"
                        + "nestopia_libretro.dylib.zip", "la dirección de arm64: \(arm)")
        let intel = RetroTools.coreURL(core: "snes9x", architecture: "x86_64").absoluteString
        try expect(intel.contains("/osx/x86_64/latest/snes9x_libretro.dylib.zip"),
                   "y la de Intel, que es otra carpeta: \(intel)")
    }

    // MARK: - Controles

    private static func testWritesTheInputLinesRetroArchUnderstands() throws {
        var perfil = ControlProfile.standard
        perfil.gamepad[.a] = .button(1)
        perfil.gamepad[.leftStickLeft] = .axis("-0")

        let líneas = RetroConfig.inputLines(for: perfil)
        func valor(_ clave: String) -> String? {
            líneas.first { $0.hasPrefix(clave + " =") }?
                .split(separator: "\"").dropFirst().first.map(String.init)
        }

        try expect(valor("input_player1_a") == "x", "la A del RetroPad es la X del teclado")
        try expect(valor("input_player1_start") == "enter", "empezar es Enter")
        try expect(valor("input_player1_a_btn") == "1", "y el botón 1 del mando")
        // Los nombres de RetroArch no son los nuestros: la palanca izquierda se llama por su eje.
        try expect(valor("input_player1_l_x_minus_axis") == "-0",
                   "la palanca va por eje y signo: \(valor("input_player1_l_x_minus_axis") ?? "nada")")
        // Lo que no se asigna se escribe vacío a propósito: omitirlo deja la asignación de fábrica
        // de RetroArch puesta, y el usuario ve un botón haciendo algo que él no pidió.
        try expect(valor("input_player1_b_btn") == "nul", "sin mando asignado, se escribe vacío")
    }

    private static func testTheDefaultLayoutIsTheOneEverybodyKnows() throws {
        let estándar = ControlProfile.standard
        try expect(estándar.binding(for: .up) == .key("up"), "cursores para moverse")
        try expect(estándar.binding(for: .b) == .key("z"), "Z y X para los botones")
        try expect(estándar.binding(for: .a) == .key("x"), "como en todos los tutoriales")
        try expect(estándar.binding(for: .start) == .key("enter"), "Enter para empezar")
        // Todos los controles del RetroPad tienen tecla: sin eso hay botones que no se pueden
        // pulsar sin mando, y entonces hay juegos que no se pueden terminar.
        for control in RetroPadInput.allCases {
            try expect(estándar.binding(for: control).isAssigned,
                       "\(control.rawValue) se queda sin tecla")
        }
        try expect(ControlProfile.wasd.binding(for: .up) == .key("w"), "el otro perfil mueve con WASD")
    }

    /// Tres niveles y gana el más concreto, que es como la gente lo piensa: «así en general, menos
    /// en esta consola, menos en este juego».
    private static func testTheMostSpecificProfileWins() throws {
        let fixture = try TemporaryFixture()
        let biblioteca = ControlLibrary(root: fixture.directoryURL)
        let n64 = RetroPlatforms.platform(id: "n64")

        try expect(biblioteca.resolved(platform: n64, gameName: "Zelda").id == "estandar",
                   "sin nada guardado, el estándar")

        var global = ControlProfile.standard; global.id = "mio"
        try biblioteca.save(global, for: .global)
        try expect(biblioteca.resolved(platform: n64, gameName: "Zelda").id == "mio", "manda el global")

        var deLaConsola = ControlProfile.standard; deLaConsola.id = "n64"
        try biblioteca.save(deLaConsola, for: .platform("n64"))
        try expect(biblioteca.resolved(platform: n64, gameName: "Zelda").id == "n64",
                   "y el de la consola por encima del global")

        var delJuego = ControlProfile.standard; delJuego.id = "zelda"
        try biblioteca.save(delJuego, for: .game("Zelda"))
        try expect(biblioteca.resolved(platform: n64, gameName: "Zelda").id == "zelda",
                   "y el del juego por encima de todo")
        try expect(biblioteca.effectiveScope(platform: n64, gameName: "Zelda") == .game("Zelda"),
                   "y se puede decir cuál está mandando, para que el usuario no adivine")

        // Se guarda como JSON legible: el usuario tiene que poder abrirlo y arreglarlo.
        let archivo = fixture.directoryURL.appendingPathComponent(ControlScope.game("Zelda").fileName)
        let texto = try String(contentsOf: archivo, encoding: .utf8)
        try expect(texto.contains("\"up\""), "las teclas se guardan por su nombre: \(texto.prefix(80))")

        biblioteca.remove(.game("Zelda"))
        try expect(biblioteca.resolved(platform: n64, gameName: "Zelda").id == "n64",
                   "al quitar el del juego se vuelve al de la consola")
    }

    /// Enseñar dieciséis botones para una Game Boy, que tiene cuatro y dos, es enseñar catorce
    /// casillas que no hacen nada.
    private static func testOnlyOffersTheButtonsTheConsoleHas() throws {
        let gb = RetroPlatforms.platform(id: "gb")
        let deLaGameBoy = RetroPadInput.available(on: gb)
        try expect(deLaGameBoy.contains(.a) && deLaGameBoy.contains(.b), "la Game Boy tiene A y B")
        try expect(!deLaGameBoy.contains(.x), "pero no tiene X")
        try expect(!deLaGameBoy.contains(.l2), "ni gatillos")

        let snes = RetroPadInput.available(on: RetroPlatforms.platform(id: "snes"))
        try expect(snes.contains(.x) && snes.contains(.l), "la Super Nintendo sí tiene X y L")

        let n64 = RetroPadInput.available(on: RetroPlatforms.platform(id: "n64"))
        try expect(n64.contains(.leftStickUp), "y la 64 tiene palanca")
    }

    /// Las teclas se traducen por su **código**, no por el carácter que escriben: en un teclado
    /// español la tecla que en el inglés hace la `;` escribe otra cosa, y lo que el usuario espera
    /// es que quede asignada la tecla que ha pulsado, esté donde esté.
    private static func testTranslatesMacKeysToRetroArchNames() throws {
        try expect(RetroKeyNames.name(forKeyCode: 6) == "z", "la Z del teclado")
        try expect(RetroKeyNames.name(forKeyCode: 7) == "x", "y la X")
        try expect(RetroKeyNames.name(forKeyCode: 36) == "enter", "Intro se llama enter, no return")
        try expect(RetroKeyNames.name(forKeyCode: 126) == "up", "los cursores por su nombre")
        try expect(RetroKeyNames.name(forKeyCode: 60) == "rshift",
                   "y la mayúscula de la derecha es otra tecla que la de la izquierda")
        try expect(RetroKeyNames.name(forKeyCode: 76) == "kp_enter", "el Intro del numérico es otro")
        // Una tecla que no se puede asignar no se inventa: devolver nada deja la interfaz
        // escuchando en vez de guardar una línea que RetroArch va a ignorar sin decir nada.
        try expect(RetroKeyNames.name(forKeyCode: 999) == nil, "lo que no está, no se inventa")

        // Y lo que se enseña no es el nombre interno: «rshift» se lee peor que «⇧ der.».
        try expect(RetroKeyNames.label(for: "enter") == "↩", "en pantalla se ve el símbolo")
        try expect(RetroKeyNames.label(for: "z") == "Z", "y una letra, en mayúscula")

        // El perfil de fábrica tiene que estar escrito con nombres que RetroArch entienda: si uno
        // no lo fuera, esa tecla no haría nada y no habría ningún error que lo dijera.
        let válidos = Set((0...130).compactMap { RetroKeyNames.name(forKeyCode: UInt16($0)) })
        for (control, asignación) in ControlProfile.defaultKeyboard {
            guard case .key(let tecla) = asignación else { continue }
            try expect(válidos.contains(tecla),
                       "\(control.rawValue) usa «\(tecla)», que no es un nombre de tecla de RetroArch")
        }
    }

    // MARK: - Fábrica de cabeceras

    private static func cabecera(en trozos: [Int: [UInt8]]) -> [UInt8] {
        let final = (trozos.map { $0.key + $0.value.count }.max() ?? 0) + 64
        var bytes = [UInt8](repeating: 0, count: max(final, 0x200))
        for (sitio, contenido) in trozos {
            for (índice, byte) in contenido.enumerated() { bytes[sitio + índice] = byte }
        }
        return bytes
    }

    private static func escribe(_ texto: String, en bytes: inout [UInt8], desde: Int) {
        for (índice, byte) in Array(texto.utf8).enumerated() where desde + índice < bytes.count {
            bytes[desde + índice] = byte
        }
    }

    private static func comprueba(
        _ fixture: TemporaryFixture, _ nombre: String, _ bytes: [UInt8],
        esperada: String, nombre interno: String?
    ) throws {
        let archivo = fixture.directoryURL.appendingPathComponent(nombre)
        try Data(bytes).write(to: archivo)
        let facts = RomInspector.inspect(archivo)
        try expect(facts.platform?.id == esperada,
                   "\(esperada) debe reconocerse por su cabecera, salió \(facts.platform?.id ?? "nada")")
        try expect(facts.evidence == .header, "\(esperada): la prueba es la cabecera")
        if let interno {
            try expect(facts.internalName == interno,
                       "\(esperada): el nombre de dentro es «\(interno)», salió «\(facts.internalName ?? "nada")»")
        }
    }
}
