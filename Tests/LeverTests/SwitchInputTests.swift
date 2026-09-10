import Foundation
import LeverCore

enum SwitchInputTests {
    static func run() throws {
        try expect(SwitchControlProfile.standard.keyboardBinding(for: .b) == "Space",
                   "el reparto de escritorio debe poner B en Espacio")
        try expect(SwitchControlProfile.standard.keyboardBinding(for: .a) == "E",
                   "confirmar debe quedar junto a WASD")
        try expect(SwitchControlProfile.standard.keyboardBinding(for: .plus) == "Enter",
                   "el menú debe abrirse con Intro")
        try testSDLIdentityUsesTheEmulatorsByteOrder()
        try testOldProfilesKeepExplicitKeys()
        try testSwitchingDevicesPreservesInactiveTemplates()
        try testMalformedInputIsNotOverwritten()
        try testSessionBindingsAndReservedKeys()
        try testQualityKeepsUnknownValuesUnknown()
        try testClosingTheMouseSessionRestoresOnlyInputs()
        try testSessionRecoveryKeepsPhysicalEditsInOtherSlots()
        try testSlowStartupCanBecomeReadyAfterTimeout()
        try testStartupReportsActualFailureOnce()
    }

    private static func testSlowStartupCanBecomeReadyAfterTimeout() throws {
        var monitor = SwitchMouseSession.StartupMonitor()
        try expect(monitor.update(isReady: false, hasFailed: false, timedOut: false) == nil,
                   "una carga todavía pendiente no es un fallo")
        try expect(monitor.update(isReady: false, hasFailed: false, timedOut: true) == .switchMouseFailed,
                   "el arranque sin confirmar produce un único aviso al vencer el plazo")
        try expect(monitor.update(isReady: false, hasFailed: false, timedOut: true) == nil,
                   "el sondeo no repite el aviso cada medio segundo")
        try expect(monitor.update(isReady: true, hasFailed: false, timedOut: true) == .switchMouseReady,
                   "el mando que aparece tras la espera sustituye el aviso por listo")
        try expect(monitor.update(isReady: true, hasFailed: false, timedOut: true) == nil,
                   "listo también se comunica una sola vez")
    }

    private static func testStartupReportsActualFailureOnce() throws {
        var monitor = SwitchMouseSession.StartupMonitor()
        try expect(monitor.update(isReady: false, hasFailed: true, timedOut: false) == .switchMouseFailed,
                   "un fallo explícito no espera 45 segundos")
        try expect(monitor.update(isReady: false, hasFailed: true, timedOut: false) == nil,
                   "un fallo persistente no llena el registro")
    }

    private static func testSDLIdentityUsesTheEmulatorsByteOrder() throws {
        try expect(SDLGamepads.ryujinx133ID(forSDLGuid: "ff00c4894c65766572204b6579007601")
                   == "0-000000ff-654c-6576-7220-4b6579007601", "GUID probado dentro de Ryujinx")
        try expect(SDLGamepads.ryujinx133ID(forSDLGuid: "030057564c050000e60c000000016800")
                   == "0-00000003-054c-0000-e60c-000000016800", "GUID físico conserva los bytes enumerados")
        try expect(SDLGamepads.ryujinx133ID(forSDLGuid: "0-unknown") == nil, "no inventa GUID")
    }

    private static func testOldProfilesKeepExplicitKeys() throws {
        let datos = Data(#"{"faceLayout":"byPosition","gamepad":{},"keyboard":{"a":"Z","b":"X"}}"#.utf8)
        var perfil = try JSONDecoder().decode(SwitchControlProfile.self, from: datos)
        try expect(perfil.keyboardBinding(for: .a) == "Z" && perfil.keyboardBinding(for: .b) == "X",
                   "migrar no borra teclas explícitas")
        try expect(perfil.inputDevice == .keyboardMouse && perfil.mouseSensitivity == 1,
                   "el perfil antiguo tiene una selección legible")
        perfil.inputDevice = .gamepad; perfil.mouseSensitivity = 1.75; perfil.invertMouseY = true
        let copia = try JSONDecoder().decode(SwitchControlProfile.self, from: JSONEncoder().encode(perfil))
        try expect(copia == perfil, "el nuevo perfil se conserva al guardarlo")
        for (_, tecla) in SwitchControlProfile.defaultKeyboard {
            try expect(SwitchKeyNames.keyCode(for: tecla) != nil, "el módulo debe poder recibir \(tecla)")
        }
    }

    private static func testSwitchingDevicesPreservesInactiveTemplates() throws {
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        let original = Data(#"{"version":70,"future_root":99,"input_config":[{"backend":"GamepadSDL2","id":"physical-id","name":"My Pad","player_index":"Handheld","deadzone_right":0.23,"future":{"keep":42},"left_joycon":{},"right_joycon":{},"left_joycon_stick":{"invert_stick_y":true},"right_joycon_stick":{},"motion":{"enable_motion":true,"sensitivity":73}}]}"#.utf8)
        try original.write(to: archivo)
        let virtual = (id: "0-000000ff-654c-6576-7220-4b6579007601", name: EmulatorControls.virtualDeviceName)
        try expect(EmulatorControls.apply(.standard, pad: virtual, atConfig: archivo) == .applied,
                   "el teclado virtual se aplica sobre la plantilla existente")
        var raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        var entradas = raíz["input_config"] as! [[String: Any]]
        try expect(entradas.count == 2 && entradas.allSatisfy { $0["id"] as? String == virtual.id },
                   "el dispositivo elegido ocupa las dos ranuras")
        try expect(entradas[0]["deadzone_right"] as? Double == 0, "el ratón no hereda deriva del mando")
        try expect(EmulatorControls.knownPad(atConfig: archivo)?.name == "My Pad",
                   "el mando inactivo sigue siendo recuperable")
        try expect(EmulatorControls.apply(SwitchControlProfile(inputDevice: .gamepad),
                                         pad: ("physical-id", "My Pad"), atConfig: archivo) == .applied,
                   "volver al mando recupera su plantilla")
        raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        entradas = raíz["input_config"] as! [[String: Any]]
        try expect(entradas[0]["deadzone_right"] as? Double == 0.23, "conserva la zona muerta física")
        try expect((entradas[0]["future"] as? [String: Any])?["keep"] as? Int == 42, "conserva campos futuros")
        try expect((entradas[0]["motion"] as? [String: Any])?["enable_motion"] as? Bool == true,
                   "el módulo no desactivó el giroscopio físico")
        try expect(raíz["future_root"] as? Int == 99, "conserva el resto del archivo")
        let respaldo = try Data(contentsOf: sitio.directoryURL.appendingPathComponent(EmulatorControls.backupName))
        try expect(respaldo == original,
                   "el respaldo permanece byte por byte")
    }

    private static func testMalformedInputIsNotOverwritten() throws {
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        let datos = Data(#"{"input_config":false,"future":1}"#.utf8)
        try datos.write(to: archivo)
        try expect(EmulatorControls.apply(.standard, pad: nil, atConfig: archivo) == .unreadableConfig,
                   "una lista inválida no se sustituye por una vacía")
        let después = try Data(contentsOf: archivo)
        try expect(después == datos, "el archivo inválido queda intacto")
    }

    private static func testSessionBindingsAndReservedKeys() throws {
        let sdl = URL(fileURLWithPath: "/fabricado con espacios/SDL.dylib")
        var perfil = SwitchControlProfile.standard
        perfil.keyboard[.a] = "Z"
        let config = try SwitchMouseSession.configuration(profile: perfil, sdl: sdl)
        try expect(config.buttonKeys[0] == 49 && config.buttonKeys[1] == 6,
                   "el salto usa Espacio y la confirmación respeta la tecla guardada")
        try expect(config.directionKeys == [13, 1, 0, 2, 34, 40, 38, 37], "WASD e IJKL conservan los sentidos")
        try expect(config.sdlPath == sdl.path, "una ruta con espacios no se interpreta como shell")
        for nombre in ["Escape", "WinLeft", "NoExiste"] {
            perfil.keyboard[.a] = nombre
            var rechazado = false
            do { _ = try SwitchMouseSession.configuration(profile: perfil, sdl: sdl) }
            catch SwitchMouseSession.Failure.invalidSettings { rechazado = true }
            try expect(rechazado, "se debe rechazar la tecla \(nombre)")
        }
        perfil = .standard; perfil.mouseSensitivity = .nan
        var rechazado = false
        do { _ = try SwitchMouseSession.configuration(profile: perfil, sdl: sdl) }
        catch SwitchMouseSession.Failure.invalidSettings { rechazado = true }
        try expect(rechazado, "una sensibilidad no numérica no llega al módulo")
    }

    private static func testQualityKeepsUnknownValuesUnknown() throws {
        try expect(EmulatorQuality.read(root: ["res_scale": true]).scale == nil, "un booleano no es escala 1")
        try expect(EmulatorQuality.read(root: ["res_scale": "1"]).scale == nil, "una cadena no es una escala")
        try expect(EmulatorQuality.read(root: ["res_scale": -1]).scale == nil, "sin escala personalizada no se adivina")
        try expect(EmulatorQuality.read(root: ["res_scale": -1, "res_scale_custom": 0.75]).scale == 0.75,
                   "leer un ajuste no afirma que sea compatible")
        try expect(EmulatorQuality.read(root: ["res_scale": 1, "scaling_filter": "Bilinear"]).filter == "Bilinear",
                   "se muestra el filtro que está escrito")
    }

    private static func testClosingTheMouseSessionRestoresOnlyInputs() throws {
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        let datos = Data(#"{"res_scale":1,"input_config":[{"name":"My Pad","backend":"GamepadSDL2","id":"id","player_index":"Handheld","left_joycon":{},"right_joycon":{},"left_joycon_stick":{},"right_joycon_stick":{}}]}"#.utf8)
        try datos.write(to: archivo)
        try expect(EmulatorControls.apply(.standard, pad: ("virtual-id", EmulatorControls.virtualDeviceName), atConfig: archivo) == .applied,
                   "prepara la sesión sobre el archivo fabricado")
        var raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        raíz["res_scale"] = 2
        try JSONSerialization.data(withJSONObject: raíz).write(to: archivo)
        try expect(EmulatorControls.recoverMouseSession(atConfig: archivo), "recupera una sesión terminada o interrumpida")
        raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        try expect(raíz["res_scale"] as? Int == 2, "no borra ajustes guardados por el emulador")
        try expect((raíz["input_config"] as? [[String: Any]])?.first?["name"] as? String == "My Pad",
                   "no deja un dispositivo virtual inexistente en el emulador")
    }

    private static func testSessionRecoveryKeepsPhysicalEditsInOtherSlots() throws {
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        let original = Data(#"{"input_config":[{"name":"Old Pad","id":"old","player_index":"Handheld"},{"name":"Old Pad","id":"old","player_index":"Player1"}]}"#.utf8)
        try original.write(to: sitio.directoryURL.appendingPathComponent(EmulatorControls.mouseSnapshotName))
        let actual = Data(#"{"input_config":[{"name":"Lever Keyboard and Mouse","id":"virtual","player_index":"Handheld"},{"name":"New Pad","id":"new","player_index":"Player1"}]}"#.utf8)
        try actual.write(to: archivo)
        try expect(EmulatorControls.recoverMouseSession(atConfig: archivo), "la mezcla de dispositivos también se recupera")
        let raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        let entradas = raíz["input_config"] as! [[String: Any]]
        try expect(entradas.first?["name"] as? String == "Old Pad", "se retira la ranura virtual restante")
        try expect(entradas.last?["name"] as? String == "New Pad", "se conserva la edición física del usuario")
        try expect(!FileManager.default.fileExists(atPath: sitio.directoryURL.appendingPathComponent(EmulatorControls.mouseSnapshotName).path),
                   "el diario se retira después de recuperar todas las ranuras virtuales")

        try Data(#"{"input_config":[]}"#.utf8).write(to: sitio.directoryURL.appendingPathComponent(EmulatorControls.mouseSnapshotName))
        try actual.write(to: archivo)
        try expect(EmulatorControls.recoverMouseSession(atConfig: archivo), "una ranura virtual sin antecedente se retira")
        let sinAntecedente = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        let conservadas = sinAntecedente["input_config"] as! [[String: Any]]
        try expect(conservadas.count == 1 && conservadas[0]["name"] as? String == "New Pad",
                   "sin una plantilla anterior no se inventa un dispositivo para la ranura")
    }
}
