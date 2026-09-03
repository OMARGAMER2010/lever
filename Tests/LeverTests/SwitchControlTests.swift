import Foundation
import LeverCore

/// Pruebas de los controles de la consola híbrida.
///
/// **Todas escriben sobre un `Config.json` fabricado.** Esto es lo único de Lever que escribe un
/// mapa entero en la configuración de otro programa, así que no se prueba por primera vez sobre la
/// del usuario. El archivo de muestra es una copia reducida del que escribe el emulador de verdad,
/// con los campos que no se tocan puestos a propósito para poder comprobar que siguen ahí después.
enum SwitchControlTests {
    static func run() throws {
        try testEveryControlHasItsOwnPlaceOnTheDrawing()
        try testTheTwoFaceLayoutsAreEachOthersMirror()
        try testAnUntouchedProfilePlaysWithTheAutomaticTranslation()
        try testWritesTheFourFaceButtonsWhereTheyBelong()
        try testKeepsTheFieldsItDoesNotUnderstand()
        try testGivesThePadBothSlotsAndLeavesTheKeyboardOnAnother()
        try testWithoutAPadItStillWritesTheKeyboard()
        try testReusesTheIdentifierTheEmulatorAlreadyWroteDown()
        try testAConfigItCannotReadIsNotTouched()
        try testKeepsACopyOfTheOriginalOnce()
        try testTheGameProfileWinsOverTheGlobalOne()
        try testRejectsAGuidThatIsNotOne()
        try testEveryKeyItWritesIsOneTheEmulatorKnows()
    }

    // MARK: - El vocabulario

    /// Que no haya dos controles peleándose por el mismo sitio del dibujo. Si dos cayeran encima,
    /// uno de los dos sería invisible y no habría forma de asignarlo.
    private static func testEveryControlHasItsOwnPlaceOnTheDrawing() throws {
        var ocupados: Set<RetroPadInput> = []
        for control in SwitchPadInput.allCases {
            try expect(!ocupados.contains(control.spot),
                       "dos controles de la consola caen en \(control.spot)")
            ocupados.insert(control.spot)
            try expect(SwitchPadInput.at(control.spot) == control,
                       "el sitio de \(control) no devuelve \(control)")
        }
    }

    /// Las dos disposiciones tienen que ser la una la inversa de la otra **en los cuatro botones
    /// del rombo y solo en esos**. Si cambiara algo más, cambiar de disposición movería controles
    /// que el usuario no pidió mover.
    private static func testTheTwoFaceLayoutsAreEachOthersMirror() throws {
        let posición = SwitchControlProfile.defaultGamepad(.byPosition)
        let etiqueta = SwitchControlProfile.defaultGamepad(.byLabel)

        for control in SwitchPadInput.allCases where !SwitchPadInput.faces.contains(control) {
            try expect(posición[control] == etiqueta[control],
                       "\(control) cambia entre disposiciones y no debería")
        }
        // Por etiqueta, letra con letra.
        try expect(etiqueta[.a] == "A" && etiqueta[.b] == "B", "por etiqueta, A y B no son A y B")
        try expect(etiqueta[.x] == "X" && etiqueta[.y] == "Y", "por etiqueta, X e Y no son X e Y")
        // Por posición, la A de la consola —la de la derecha— la pulsa el botón que SDL llama `B`,
        // que es el de la derecha. Es la inversión que reproduce la consola.
        try expect(posición[.a] == "B" && posición[.b] == "A",
                   "por posición, A y B no están invertidas")
        try expect(posición[.x] == "Y" && posición[.y] == "X",
                   "por posición, X e Y no están invertidas")
    }

    /// El requisito de fondo: un juego que nadie ha configurado tiene que jugarse igual. Un perfil
    /// vacío no puede significar «sin controles».
    private static func testAnUntouchedProfilePlaysWithTheAutomaticTranslation() throws {
        let perfil = SwitchControlProfile.standard
        try expect(perfil.isUntouched, "el perfil de fábrica no está intacto")
        for control in SwitchPadInput.onGamepad {
            try expect(perfil.gamepadBinding(for: control) != "Unbound",
                       "\(control) se queda sin asignar en el perfil de fábrica")
        }
        for control in SwitchPadInput.allCases {
            try expect(perfil.keyboardBinding(for: control) != "Unbound",
                       "\(control) se queda sin tecla en el perfil de fábrica")
        }
        try expect(perfil.gamepadBinding(for: .a) == "B",
                   "el perfil de fábrica no traduce por posición")
    }

    // MARK: - La escritura

    private static func testWritesTheFourFaceButtonsWhereTheyBelong() throws {
        let sitio = try TemporaryFixture()
        let archivo = try write(sample, in: sitio)

        _ = EmulatorControls.apply(
            SwitchControlProfile(faceLayout: .byLabel), pad: pad, atConfig: archivo
        )
        let mando = try gamepadEntry(in: archivo)
        let derecho = mando["right_joycon"] as? [String: Any] ?? [:]
        try expect(derecho["button_a"] as? String == "A", "button_a no quedó en A")
        try expect(derecho["button_b"] as? String == "B", "button_b no quedó en B")
        try expect(derecho["button_x"] as? String == "X", "button_x no quedó en X")
        try expect(derecho["button_y"] as? String == "Y", "button_y no quedó en Y")

        // Y el resto del mando, en su sitio de siempre.
        let izquierdo = mando["left_joycon"] as? [String: Any] ?? [:]
        try expect(izquierdo["button_zl"] as? String == "LeftTrigger", "ZL no es el gatillo")
        try expect(izquierdo["dpad_up"] as? String == "DpadUp", "la cruceta no es la cruceta")
        try expect(derecho["button_plus"] as? String == "Start", "el + no es Start")
    }

    /// La promesa que sostiene toda la decisión de escribir: Lever **edita** la entrada que el
    /// emulador escribió, no la redacta. Todo lo que no entiende sigue ahí después.
    private static func testKeepsTheFieldsItDoesNotUnderstand() throws {
        let sitio = try TemporaryFixture()
        let archivo = try write(sample, in: sitio)

        _ = EmulatorControls.apply(.standard, pad: pad, atConfig: archivo)
        let raíz = try root(of: archivo)
        let mando = try gamepadEntry(in: archivo)

        try expect(mando["deadzone_left"] as? Double == 0.15, "se perdió la zona muerta")
        try expect(mando["trigger_threshold"] as? Double == 0.4, "se perdió el umbral del gatillo")
        try expect((mando["motion"] as? [String: Any])?["sensitivity"] as? Int == 77,
                   "se perdió la sensibilidad del giroscopio")
        try expect((mando["led"] as? [String: Any])?["led_color"] as? Int == 4242,
                   "se perdió el color del LED")
        // Un campo que esta versión de Lever no conoce: si desapareciera, la promesa de heredar los
        // cambios de esquema gratis sería falsa.
        try expect(mando["campo_de_una_version_futura"] as? String == "intacto",
                   "se perdió un campo desconocido")
        // Y fuera de `input_config`, nada se toca.
        try expect(raíz["docked_mode"] as? Bool == true, "se tocó el modo de pantalla")
        try expect(raíz["version"] as? Int == 70, "se tocó la versión de la configuración")
    }

    /// Las tres ranuras: el mando duplicado en las dos que mira el emulador según el modo de
    /// pantalla, y el teclado en una tercera para que no le quite el sitio.
    private static func testGivesThePadBothSlotsAndLeavesTheKeyboardOnAnother() throws {
        let sitio = try TemporaryFixture()
        let archivo = try write(sample, in: sitio)

        _ = EmulatorControls.apply(.standard, pad: pad, atConfig: archivo)
        let perfiles = try inputConfig(in: archivo)
        try expect(perfiles.count == 3, "no salieron tres perfiles sino \(perfiles.count)")

        let ranuras = perfiles.map { ($0["player_index"] as? String) ?? "?" }
        try expect(ranuras.contains("Handheld"), "falta la ranura de la mano")
        try expect(ranuras.contains("Player1"), "falta la ranura de la base")
        try expect(ranuras.contains("Player2"), "falta la ranura del teclado")

        let delMando = perfiles.filter { ($0["backend"] as? String) == "GamepadSDL2" }
        try expect(delMando.count == 2, "el mando no está en las dos ranuras")
        try expect(Set(delMando.map { $0["id"] as? String ?? "" }) == [pad!.id],
                   "las dos copias del mando no llevan el mismo identificador")
        // El tipo importa: en la ranura de la mano el emulador espera una consola portátil, y en la
        // de la base un mando entero.
        let porRanura = Dictionary(uniqueKeysWithValues: perfiles.map {
            ($0["player_index"] as? String ?? "?", $0["controller_type"] as? String ?? "?")
        })
        try expect(porRanura["Handheld"] == "Handheld", "la ranura de la mano no es portátil")
        try expect(porRanura["Player1"] == "ProController", "la ranura de la base no es un mando")

        let teclado = try expectOne(perfiles.filter { ($0["backend"] as? String) == "WindowKeyboard" })
        let palanca = teclado["left_joycon_stick"] as? [String: Any] ?? [:]
        try expect(palanca["stick_up"] as? String == "W", "el teclado no mueve la palanca")
        // Un teclado no asigna la palanca entera: si quedara `joystick`, el archivo diría dos cosas
        // a la vez sobre el mismo objeto.
        try expect(palanca["joystick"] == nil, "al teclado le quedó la palanca de un mando")
    }

    /// Sin identificador de mando se escribe el teclado igualmente. Es la diferencia entre un juego
    /// que se puede jugar con el teclado y un juego que no responde a nada.
    private static func testWithoutAPadItStillWritesTheKeyboard() throws {
        let sitio = try TemporaryFixture()
        let archivo = try write(sampleWithoutPad, in: sitio)

        let resultado = EmulatorControls.apply(.standard, pad: nil, atConfig: archivo)
        try expect(resultado == .appliedWithoutGamepad,
                   "sin mando no avisó de que faltaba: \(resultado)")
        let perfiles = try inputConfig(in: archivo)
        try expect(perfiles.count == 1, "escribió algo más que el teclado")
        try expect(perfiles[0]["backend"] as? String == "WindowKeyboard", "no es el teclado")
    }

    /// El identificador es `0-<GUID>`, y el GUID lleva un CRC del nombre y el bus: no se puede
    /// inventar. El que ya está en el archivo lo escribió el emulador, así que es el bueno.
    private static func testReusesTheIdentifierTheEmulatorAlreadyWroteDown() throws {
        let sitio = try TemporaryFixture()
        let archivo = try write(sample, in: sitio)

        let encontrado = EmulatorControls.knownPad(
            named: "DualSense Wireless Controller", atConfig: archivo
        )
        try expect(encontrado?.id == "0-030057564c050000e60c000000016800",
                   "no reaprovechó el identificador guardado")

        // Y aplicando sin decirle ninguno, se queda con ese en vez de borrar el mando del usuario.
        _ = EmulatorControls.apply(.standard, pad: nil, atConfig: archivo)
        let mando = try gamepadEntry(in: archivo)
        try expect(mando["id"] as? String == "0-030057564c050000e60c000000016800",
                   "una escritura sin mando delante borró el que había")

        // El teclado nunca puede pasar por mando: su identificador es `0` y no identifica nada.
        try expect(EmulatorControls.knownPad(in: [
            ["backend": "WindowKeyboard", "id": "0", "name": "Keyboard"]
        ]) == nil, "tomó el teclado por un mando")
    }

    /// Un archivo que no se entiende no se toca. Escribir encima de lo que no se ha podido leer
    /// dejaría al usuario sin emulador, que es mucho peor que dejarlo sin la función.
    private static func testAConfigItCannotReadIsNotTouched() throws {
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        try Data("esto no es json".utf8).write(to: archivo)

        let resultado = EmulatorControls.apply(.standard, pad: pad, atConfig: archivo)
        try expect(resultado == .unreadableConfig, "no dijo que no sabía leerlo: \(resultado)")
        let quedó = String(data: try Data(contentsOf: archivo), encoding: .utf8)
        try expect(quedó == "esto no es json", "tocó un archivo que no había entendido")
    }

    /// La copia del original se hace una vez. Si se rehiciera en cada escritura acabaría siendo
    /// copia de lo último que escribió Lever, que no sirve para volver atrás.
    private static func testKeepsACopyOfTheOriginalOnce() throws {
        let sitio = try TemporaryFixture()
        let archivo = try write(sample, in: sitio)
        let copia = sitio.directoryURL.appendingPathComponent(EmulatorControls.backupName)

        _ = EmulatorControls.apply(SwitchControlProfile(faceLayout: .byLabel),
                                   pad: pad, atConfig: archivo)
        try expect(FileManager.default.fileExists(atPath: copia.path), "no guardó copia del original")
        let primera = try Data(contentsOf: copia)

        _ = EmulatorControls.apply(.standard, pad: pad, atConfig: archivo)
        let segunda = try Data(contentsOf: copia)
        try expect(segunda == primera, "la copia del original cambió en la segunda escritura")
        // Y la copia es de verdad la de antes: lleva el rombo que traía el archivo de muestra.
        let guardado = try JSONSerialization.jsonObject(with: primera) as? [String: Any] ?? [:]
        let perfiles = guardado["input_config"] as? [[String: Any]] ?? []
        let derecho = perfiles.first?["right_joycon"] as? [String: Any] ?? [:]
        try expect(derecho["button_a"] as? String == "B", "la copia no es la de antes de escribir")
    }

    /// Que el perfil del juego mande sobre el global, y que quitarlo devuelva el mando al global.
    private static func testTheGameProfileWinsOverTheGlobalOne() throws {
        let sitio = try TemporaryFixture()
        let biblioteca = SwitchControlLibrary(root: sitio.directoryURL)

        try expect(biblioteca.resolved(gameId: "0100ABCD00001000").faceLayout == .byPosition,
                   "sin nada guardado no salió la traducción de fábrica")

        try biblioteca.save(SwitchControlProfile(faceLayout: .byLabel), for: .global)
        try expect(biblioteca.resolved(gameId: "0100ABCD00001000").faceLayout == .byLabel,
                   "el global no se aplicó a un juego sin perfil propio")

        var propio = SwitchControlProfile(faceLayout: .byPosition)
        propio.gamepad[.zl] = "RightTrigger"
        try biblioteca.save(propio, for: .game("0100ABCD00001000"))

        let resuelto = biblioteca.resolved(gameId: "0100ABCD00001000")
        try expect(resuelto.gamepadBinding(for: .zl) == "RightTrigger",
                   "el perfil del juego no ganó al global")
        try expect(biblioteca.effectiveScope(gameId: "0100ABCD00001000") == .game("0100ABCD00001000"),
                   "no dijo que mandaba el del juego")
        // Otro juego sigue con el global: por juego significa por juego.
        try expect(biblioteca.resolved(gameId: "0100FFFF00002000").faceLayout == .byLabel,
                   "el perfil de un juego se le pegó a otro")

        biblioteca.remove(.game("0100ABCD00001000"))
        try expect(biblioteca.resolved(gameId: "0100ABCD00001000").faceLayout == .byLabel,
                   "al quitar el del juego no volvió el global")
    }

    /// Un GUID mal leído es peor que ninguno: el archivo lo acepta y el emulador no lo reconoce
    /// nunca, así que el fallo aparece como un mando que no hace nada y sin ningún mensaje.
    private static func testRejectsAGuidThatIsNotOne() throws {
        let bueno = "030057564c050000e60c000000016800,DualSense,a:b0,b:b1,"
        try expect(SDLGamepads.guid(inMapping: bueno) == "030057564c050000e60c000000016800",
                   "no leyó un GUID correcto")
        try expect(SDLGamepads.guid(inMapping: "00000000000000000000000000000000,X,") == nil,
                   "aceptó treinta y dos ceros")
        try expect(SDLGamepads.guid(inMapping: "0300,X,") == nil, "aceptó un GUID corto")
        try expect(SDLGamepads.guid(inMapping: "030057564C050000E60C000000016800,X,") == nil,
                   "aceptó un GUID en mayúsculas, que no es el que escribe el emulador")
        try expect(SDLGamepads.guid(inMapping: "") == nil, "aceptó una cadena vacía")
    }

    /// Cada tecla que Lever escribe tiene que ser una que el emulador sepa leer. Equivocarse aquí
    /// no da error: escribe un nombre que el archivo acepta y el emulador ignora.
    private static func testEveryKeyItWritesIsOneTheEmulatorKnows() throws {
        // Las que el archivo de muestra —escrito por el emulador de verdad— usa, más las que
        // Lever pone por omisión. Si una traducción se desviara, dejaría de estar en la lista.
        let conocidas: Set<String> = [
            "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
            "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
            "Up", "Down", "Left", "Right", "Minus", "Plus", "Enter", "Space",
            "Tab", "Escape", "BackSpace", "ShiftLeft", "ShiftRight", "Unbound"
        ]
        for (_, nombre) in SwitchControlProfile.defaultKeyboard {
            try expect(conocidas.contains(nombre),
                       "la tecla por omisión «\(nombre)» no es de las que el emulador conoce")
        }
        // Y la traducción desde el Mac: la `Z` del teclado da `Z`, y la flecha arriba da `Up`.
        try expect(SwitchKeyNames.name(forKeyCode: 6) == "Z", "la Z no se traduce a Z")
        try expect(SwitchKeyNames.name(forKeyCode: 126) == "Up", "la flecha arriba no es Up")
        try expect(SwitchKeyNames.name(forKeyCode: 36) == "Enter", "el Intro no es Enter")
        try expect(SwitchKeyNames.name(forKeyCode: 18) == "Number1", "el 1 no es Number1")
        // Una tecla que no se puede asignar se rechaza en vez de inventarle un nombre.
        try expect(SwitchKeyNames.name(forKeyCode: 999) == nil, "inventó un nombre para una tecla")
    }

    // MARK: - Ayudas

    private static let pad: (id: String, name: String)? =
        ("0-030057564c050000e60c000000016800", "DualSense Wireless Controller")

    private static func write(_ json: String, in fixture: TemporaryFixture) throws -> URL {
        let archivo = fixture.directoryURL.appendingPathComponent("Config.json")
        try Data(json.utf8).write(to: archivo)
        return archivo
    }

    private static func root(of url: URL) throws -> [String: Any] {
        let datos = try Data(contentsOf: url)
        guard let raíz = try JSONSerialization.jsonObject(with: datos) as? [String: Any] else {
            throw TestFailure(description: "el Config.json escrito no es un objeto")
        }
        return raíz
    }

    private static func inputConfig(in url: URL) throws -> [[String: Any]] {
        guard let perfiles = try root(of: url)["input_config"] as? [[String: Any]] else {
            throw TestFailure(description: "el Config.json escrito no tiene input_config")
        }
        return perfiles
    }

    private static func gamepadEntry(in url: URL) throws -> [String: Any] {
        try expectOne(try inputConfig(in: url).filter {
            ($0["backend"] as? String) == "GamepadSDL2"
        }.prefix(1).map { $0 })
    }

    private static func expectOne(_ entries: [[String: Any]]) throws -> [String: Any] {
        guard let primera = entries.first else {
            throw TestFailure(description: "no había ninguna entrada donde debía haber una")
        }
        return primera
    }

    /// Una copia reducida del `Config.json` que escribe el emulador de verdad. Los valores raros
    /// —la zona muerta a 0.15, la sensibilidad a 77, el color del LED— están puestos a propósito
    /// para poder comprobar que siguen ahí después de escribir.
    private static let sample = """
    {
      "version": 70,
      "docked_mode": true,
      "input_config": [
        {
          "version": 1,
          "backend": "GamepadSDL2",
          "id": "0-030057564c050000e60c000000016800",
          "name": "DualSense Wireless Controller",
          "controller_type": "ProController",
          "player_index": "Player1",
          "deadzone_left": 0.15,
          "deadzone_right": 0.1,
          "trigger_threshold": 0.4,
          "campo_de_una_version_futura": "intacto",
          "motion": { "motion_backend": "GamepadDriver", "sensitivity": 77,
                      "gyro_deadzone": 1, "enable_motion": true },
          "rumble": { "strong_rumble": 1, "weak_rumble": 1, "enable_rumble": true },
          "led": { "enable_led": false, "turn_off_led": false,
                   "use_rainbow": false, "led_color": 4242 },
          "left_joycon_stick": { "joystick": "Left", "invert_stick_x": false,
                                 "invert_stick_y": true, "rotate90_cw": false,
                                 "stick_button": "LeftStick" },
          "right_joycon_stick": { "joystick": "Right", "invert_stick_x": false,
                                  "invert_stick_y": false, "rotate90_cw": false,
                                  "stick_button": "RightStick" },
          "left_joycon": { "button_minus": "Back", "button_l": "LeftShoulder",
                           "button_zl": "LeftTrigger", "button_sl": "Unbound",
                           "button_sr": "Unbound", "dpad_up": "DpadUp",
                           "dpad_down": "DpadDown", "dpad_left": "DpadLeft",
                           "dpad_right": "DpadRight" },
          "right_joycon": { "button_plus": "Start", "button_r": "RightShoulder",
                            "button_zr": "RightTrigger", "button_sl": "Unbound",
                            "button_sr": "Unbound", "button_x": "Y", "button_b": "A",
                            "button_y": "X", "button_a": "B" }
        }
      ]
    }
    """

    /// El mismo archivo sin ninguna entrada de mando, que es como está el de un emulador recién
    /// instalado que nadie ha abierto todavía con un mando puesto.
    private static let sampleWithoutPad = """
    { "version": 70, "docked_mode": false, "input_config": [] }
    """
}
