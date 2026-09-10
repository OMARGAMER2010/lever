import Foundation

/// Cómo acabó un intento de escribir los controles.
///
/// No es un `Bool` porque los fallos no son intercambiables: «no se supo el identificador del
/// mando» se arregla conectándolo y abriendo el emulador una vez, y «el emulador está abierto» se
/// arregla cerrándolo. Un `false` mandaría al usuario a adivinar cuál de los dos le ha tocado.
public enum ControlWriteOutcome: Equatable, Sendable {
    case applied
    case saved
    case missingTemplate
    case appliedWithoutGamepad
    /// El emulador está abierto. No se ha tocado nada.
    case emulatorIsRunning
    case unreadableConfig
    case writeFailed

    public var textKey: TextKey {
        switch self {
        case .applied: return .switchControlsApplied
        case .saved: return .switchControlsSaved
        case .missingTemplate: return .switchInputTemplateMissing
        case .appliedWithoutGamepad: return .switchControlsNoPadId
        case .emulatorIsRunning: return .switchControlsEmulatorOpen
        case .unreadableConfig: return .switchControlsUnreadable
        case .writeFailed: return .switchControlsFailed
        }
    }

    public var isSuccess: Bool { self == .applied || self == .saved }
}

/// Escribe el mapa de controles en la configuración del emulador de la consola híbrida.
///
/// **Esto amplía la excepción que abrió `EmulatorSettings`, y la ampliación se justifica así.**
/// `EmulatorInputReader`, aquí al lado, solo lee, y explica por qué: escribirle dentro a un
/// programa que instala y actualiza el usuario es firmarse a romperse en cada versión suya.
/// `EmulatorSettings` se saltó eso para **una clave booleana** de nombre estable. Un mapa de
/// controles son decenas de campos anidados, que es exactamente lo que aquel comentario decía que
/// no se tocara. Cuatro razones para hacerlo igualmente:
///
/// 1. **No hay otra forma.** El emulador no tiene configuración de entrada por juego —su
///    `games/<identificador>/` solo lleva caché de sombreadores—, así que la única lista que existe
///    es la global de su `Config.json`. Sin escribirla, «controles distintos en este juego» no
///    existe. No es una comodidad sustituible por otra cosa.
///
/// 2. **Lever no redacta un perfil desde cero: edita el que escribió el emulador.** Se toma la
///    entrada que ya está en el archivo y se sustituyen **solo los valores hoja de los botones**,
///    dejando intacto todo lo demás: zonas muertas, giroscopio, vibración, LED, y cualquier campo
///    que una versión futura añada. Así los campos nuevos se conservan. Si no hay una plantilla
///    válida del emulador, Lever lo indica y no escribe un esquema inventado.
///
/// 3. **El peor fallo es legible.** Si el esquema cambiara de forma incompatible, lo que el usuario
///    ve es «los controles no son los que pedí», que se entiende y se deshace. Escribir claves de
///    gráficos o de sistema no tendría esa red: ahí el fallo es un emulador que no arranca.
///
/// 4. **Es reversible.** La primera vez se guarda el original en `Config.json.lever-original`, se
///    escribe a un temporal y se mueve encima —si algo falla a mitad queda la configuración de
///    antes, no un archivo truncado—, y no se escribe nunca con el emulador abierto, porque lo
///    reescribe al cerrarse y el cambio se perdería sin que nadie lo entendiera.
public enum EmulatorControls {
    public static let virtualDeviceName = "Lever Keyboard and Mouse"
    public static let templatesName = "Config.json.lever-input-templates.json"
    public static let mouseSnapshotName = "Config.json.lever-before-mouse.json"
    /// Copia del archivo tal como estaba antes de que Lever lo tocara por primera vez. Se guarda
    /// una sola vez: si se rehiciera en cada escritura, la «copia del original» acabaría siendo
    /// copia de lo último que escribió Lever, que no sirve para nada.
    ///
    /// Pública para que las pruebas puedan comprobar que la copia se hace y que no se rehace.
    public static let backupName = "Config.json.lever-original"

    // MARK: - Aplicar

    /// Escribe el perfil en la configuración de ese emulador.
    ///
    /// Se niega si el emulador está abierto: al cerrarse vuelca su configuración de memoria y se
    /// llevaría por delante lo que se acabara de escribir. Es el mismo motivo por el que el botón
    /// del modo de pantalla avisa antes.
    @MainActor
    @discardableResult
    public static func apply(
        _ profile: SwitchControlProfile,
        pad: (id: String, name: String)?,
        for emulator: StandaloneEmulator,
        fileManager: FileManager = .default
    ) -> ControlWriteOutcome {
        guard !EmulatorSettings.isRunning(emulator) else { return .emulatorIsRunning }
        return apply(
            profile, pad: pad,
            atConfig: EmulatorSettings.configURL(for: emulator, fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// La misma escritura sobre un archivo concreto. Separada para poder probarla contra un
    /// `Config.json` fabricado: esto escribe en la configuración de otro programa, y eso no se
    /// prueba por primera vez sobre la del usuario.
    @discardableResult
    public static func apply(
        _ profile: SwitchControlProfile,
        pad: (id: String, name: String)?,
        atConfig archivo: URL,
        fileManager: FileManager = .default
    ) -> ControlWriteOutcome {
        guard let datos = try? Data(contentsOf: archivo),
              var raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else { return .unreadableConfig }

        guard let existentes = raíz["input_config"] as? [[String: Any]] else { return .unreadableConfig }
        let caché = archivo.deletingLastPathComponent().appendingPathComponent(templatesName)
        var guardadas: [[String: Any]] = []
        if fileManager.fileExists(atPath: caché.path) {
            guard let datos = try? Data(contentsOf: caché),
                  let leídas = try? JSONSerialization.jsonObject(with: datos) as? [[String: Any]]
            else { return .unreadableConfig }
            guardadas = leídas
        }
        // La configuración activa ya no contiene el dispositivo inactivo. Se conservan sus
        // entradas aparte antes de sustituirlas, para recuperar también campos de versiones futuras.
        let plantillas = existentes + guardadas.filter { antigua in
            !existentes.contains { $0["id"] as? String == antigua["id"] as? String
                && $0["backend"] as? String == antigua["backend"] as? String
                && $0["player_index"] as? String == antigua["player_index"] as? String }
        }
        let mando = pad ?? (profile.inputDevice == .gamepad ? knownPad(in: plantillas) : nil)
        guard let mando else { return .appliedWithoutGamepad }
        guard (profile.inputDevice == .keyboardMouse) == (mando.name == virtualDeviceName) else { return .appliedWithoutGamepad }
        guard let nuevas = slots(profile, pad: mando, from: plantillas) else { return .missingTemplate }
        raíz["input_config"] = nuevas
        guard let salida = try? JSONSerialization.data(
            withJSONObject: raíz, options: [.prettyPrinted, .sortedKeys]
        ) else { return .writeFailed }

        do {
            if mando.name == virtualDeviceName { try beginMouseSession(atConfig: archivo, data: datos, entries: existentes) }
            let originales = try JSONSerialization.data(withJSONObject: plantillas, options: [.prettyPrinted, .sortedKeys])
            try originales.write(to: caché, options: .atomic)
            try backUp(archivo, fileManager: fileManager)
        } catch { return .writeFailed }

        let temporal = archivo.deletingLastPathComponent()
            .appendingPathComponent("Config.json.lever-\(UUID().uuidString)")
        guard (try? salida.write(to: temporal)) != nil else { return .writeFailed }
        guard (try? fileManager.replaceItemAt(archivo, withItemAt: temporal)) != nil else {
            try? fileManager.removeItem(at: temporal)
            return .writeFailed
        }
        return .applied
    }

    private static func beginMouseSession(atConfig archivo: URL, data: Data, entries: [[String: Any]]) throws {
        let copia = archivo.deletingLastPathComponent().appendingPathComponent(mouseSnapshotName)
        if entries.allSatisfy({ $0["name"] as? String == virtualDeviceName }) && FileManager.default.fileExists(atPath: copia.path) { return }
        try data.write(to: copia, options: .atomic)
    }

    /// El dispositivo SDL solo existe durante la sesión. Al cerrarla se recupera la entrada
    /// anterior, conservando los cambios de gráficos o ventana que el emulador haya guardado.
    /// El diario permite recuperar también una sesión interrumpida cuando Lever vuelve a abrirse.
    @MainActor
    public static func recoverMouseSession(for emulator: StandaloneEmulator, fileManager: FileManager = .default) {
        guard !EmulatorSettings.isRunning(emulator) else { return }
        _ = recoverMouseSession(atConfig: EmulatorSettings.configURL(for: emulator, fileManager: fileManager))
    }

    @discardableResult
    public static func recoverMouseSession(atConfig archivo: URL) -> Bool {
        let copia = archivo.deletingLastPathComponent().appendingPathComponent(mouseSnapshotName)
        guard let guardado = try? Data(contentsOf: copia),
              let original = try? JSONSerialization.jsonObject(with: guardado) as? [String: Any],
              let entradas = original["input_config"] as? [[String: Any]],
              let datos = try? Data(contentsOf: archivo),
              var actual = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let activas = actual["input_config"] as? [[String: Any]] else { return false }
        do {
            if activas.contains(where: { $0["name"] as? String == virtualDeviceName }) {
                let anteriores = entradas.filter { $0["name"] as? String != virtualDeviceName }
                // Ryujinx puede guardar un mando nuevo mientras el ratón sigue en otra ranura.
                // Solo se recuperan las ranuras todavía virtuales; las ediciones físicas se respetan.
                let recuperadas = activas.allSatisfy { $0["name"] as? String == virtualDeviceName }
                    ? anteriores
                    : activas.flatMap { entrada -> [[String: Any]] in
                        guard entrada["name"] as? String == virtualDeviceName else { return [entrada] }
                        guard let ranura = entrada["player_index"] as? String else { return [] }
                        return anteriores.filter { $0["player_index"] as? String == ranura }
                    }
                actual["input_config"] = recuperadas
                try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys]).write(to: archivo, options: .atomic)
            }
            try FileManager.default.removeItem(at: copia)
            return true
        } catch { return false }
    }

    /// Guarda el archivo tal como estaba, la primera vez y solo la primera.
    private static func backUp(_ archivo: URL, fileManager: FileManager) throws {
        let copia = archivo.deletingLastPathComponent().appendingPathComponent(backupName)
        guard !fileManager.fileExists(atPath: copia.path) else { return }
        try fileManager.copyItem(at: archivo, to: copia)
    }

    // MARK: - El jugador principal

    /// Handheld y Docked consultan ranuras distintas. Solo el dispositivo elegido ocupa ambas;
    /// Player2 pertenece a otro jugador (Cappy en Odyssey), no es una entrada alternativa de Mario.
    static func slots(
        _ profile: SwitchControlProfile,
        pad: (id: String, name: String),
        from existing: [[String: Any]]
    ) -> [[String: Any]]? {
        let mandos = existing.filter { $0["backend"] as? String == "GamepadSDL2" }
        let virtual = pad.name == virtualDeviceName
        guard var plantilla = mandos.first(where: { $0["id"] as? String == pad.id })
            ?? mandos.first(where: { $0["name"] as? String == pad.name })
            ?? mandos.first(where: { $0["name"] as? String != virtualDeviceName }),
              plantilla["left_joycon"] is [String: Any], plantilla["right_joycon"] is [String: Any],
              plantilla["left_joycon_stick"] is [String: Any], plantilla["right_joycon_stick"] is [String: Any]
        else { return nil }
        if virtual {
            // Un ratón no tiene deriva física. Heredar la zona muerta del DualSense perdería
            // movimientos pequeños. La plantilla física permanece intacta en la caché.
            plantilla["deadzone_left"] = 0.0; plantilla["deadzone_right"] = 0.0
            plantilla["range_left"] = 1.0; plantilla["range_right"] = 1.0
            for sección in ["left_joycon_stick", "right_joycon_stick"] {
                var palanca = plantilla[sección] as? [String: Any] ?? [:]
                for clave in ["invert_stick_x", "invert_stick_y", "rotate90_cw"] { palanca[clave] = false }
                plantilla[sección] = palanca
            }
            for (sección, clave) in [("motion", "enable_motion"), ("rumble", "enable_rumble")] {
                if var ajustes = plantilla[sección] as? [String: Any] { ajustes[clave] = false; plantilla[sección] = ajustes }
            }
        }
        let base = gamepadEntry(virtual ? .standard : profile, from: plantilla, pad: pad)
        return [place(base, type: "Handheld", slot: "Handheld"),
                place(base, type: "ProController", slot: "Player1")]
    }

    private static func place(
        _ entry: [String: Any], type: String, slot: String
    ) -> [String: Any] {
        var copia = entry
        copia["controller_type"] = type
        copia["player_index"] = slot
        return copia
    }

    // MARK: - Rellenar una entrada

    /// La entrada de un mando: la plantilla con los botones sustituidos.
    static func gamepadEntry(
        _ profile: SwitchControlProfile,
        from template: [String: Any],
        pad: (id: String, name: String)
    ) -> [String: Any] {
        var entrada = template
        entrada["backend"] = "GamepadSDL2"
        entrada["id"] = pad.id
        entrada["name"] = pad.name

        for control in SwitchPadInput.onGamepad {
            let (sección, clave) = control.field
            var objeto = entrada[sección] as? [String: Any] ?? [:]
            objeto[clave] = profile.gamepadBinding(for: control)
            entrada[sección] = objeto
        }

        // Las palancas de un mando se asignan enteras, no por sentidos. Si la plantilla venía de un
        // teclado traería `stick_up` y compañía, que aquí no significan nada: se quitan en vez de
        // dejarlas puestas confundiendo a quien abra el archivo.
        for (sección, lado) in [("left_joycon_stick", "Left"), ("right_joycon_stick", "Right")] {
            var objeto = entrada[sección] as? [String: Any] ?? [:]
            for sentido in ["stick_up", "stick_down", "stick_left", "stick_right"] {
                objeto.removeValue(forKey: sentido)
            }
            objeto["joystick"] = lado
            // Solo si no venían: invertir un eje o girar la palanca noventa grados son ajustes que
            // el usuario pudo poner a mano, y Lever no los toca.
            for (clave, valor) in [("invert_stick_x", false), ("invert_stick_y", false),
                                   ("rotate90_cw", false)] where objeto[clave] == nil {
                objeto[clave] = valor
            }
            entrada[sección] = objeto
        }
        return entrada
    }

    // MARK: - El identificador del mando

    /// Busca también en las plantillas inactivas. Las entradas virtuales se excluyen para que
    /// seleccionar «Mando» nunca vuelva a elegir el teclado de una sesión anterior.
    public static func knownPad(named name: String? = nil, atConfig archivo: URL) -> (id: String, name: String)? {
        guard let datos = try? Data(contentsOf: archivo),
              let raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let perfiles = raíz["input_config"] as? [[String: Any]]
        else { return nil }
        let caché = archivo.deletingLastPathComponent().appendingPathComponent(templatesName)
        let guardadas = (try? Data(contentsOf: caché)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
        } ?? []
        if let name, let exacto = knownPad(in: perfiles + guardadas, named: name) { return exacto }
        return knownPad(in: perfiles + guardadas)
    }

    /// La misma búsqueda sobre una lista ya leída. Pública porque es la parte que se puede probar
    /// sin tocar ningún archivo, y porque tomar el teclado por un mando es un fallo silencioso.
    public static func knownPad(
        in profiles: [[String: Any]], named name: String? = nil
    ) -> (id: String, name: String)? {
        for perfil in profiles {
            guard (perfil["backend"] as? String) == "GamepadSDL2",
                  let id = perfil["id"] as? String, !id.isEmpty, id != "0",
                  let nombre = perfil["name"] as? String, nombre != virtualDeviceName
            else { continue }
            if let name, nombre != name { continue }
            return (id, nombre)
        }
        return nil
    }

}
