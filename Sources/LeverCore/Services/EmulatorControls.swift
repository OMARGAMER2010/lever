import Foundation

/// Cómo acabó un intento de escribir los controles.
///
/// No es un `Bool` porque los fallos no son intercambiables: «no se supo el identificador del
/// mando» se arregla conectándolo y abriendo el emulador una vez, y «el emulador está abierto» se
/// arregla cerrándolo. Un `false` mandaría al usuario a adivinar cuál de los dos le ha tocado.
public enum ControlWriteOutcome: Equatable, Sendable {
    case applied
    /// Se escribió el teclado, pero del mando no se supo el identificador. El juego se puede jugar;
    /// el mando, no.
    case appliedWithoutGamepad
    /// El emulador está abierto. No se ha tocado nada.
    case emulatorIsRunning
    case unreadableConfig
    case writeFailed

    public var textKey: TextKey {
        switch self {
        case .applied: return .switchControlsApplied
        case .appliedWithoutGamepad: return .switchControlsNoPadId
        case .emulatorIsRunning: return .switchControlsEmulatorOpen
        case .unreadableConfig: return .switchControlsUnreadable
        case .writeFailed: return .switchControlsFailed
        }
    }

    public var isSuccess: Bool { self == .applied || self == .appliedWithoutGamepad }
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
///    que una versión futura añada. Así los cambios de esquema se heredan gratis en vez de
///    romperse. La plantilla propia de aquí abajo solo entra en juego cuando el archivo no tiene
///    ninguna entrada que copiar.
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

        let existentes = (raíz["input_config"] as? [[String: Any]]) ?? []
        // El mando que se pide, y si no se pide ninguno, el que el archivo ya conociera. Así una
        // escritura hecha sin mando delante no borra el que el usuario tenía configurado.
        let mando = pad ?? knownPad(in: existentes)

        raíz["input_config"] = slots(profile, pad: mando, from: existentes)
        guard let salida = try? JSONSerialization.data(
            withJSONObject: raíz, options: [.prettyPrinted, .sortedKeys]
        ) else { return .writeFailed }

        backUp(archivo, fileManager: fileManager)

        let temporal = archivo.deletingLastPathComponent()
            .appendingPathComponent("Config.json.lever-\(UUID().uuidString)")
        guard (try? salida.write(to: temporal)) != nil else { return .writeFailed }
        guard (try? fileManager.replaceItemAt(archivo, withItemAt: temporal)) != nil else {
            try? fileManager.removeItem(at: temporal)
            return .writeFailed
        }
        return mando == nil ? .appliedWithoutGamepad : .applied
    }

    /// Guarda el archivo tal como estaba, la primera vez y solo la primera.
    private static func backUp(_ archivo: URL, fileManager: FileManager) {
        let copia = archivo.deletingLastPathComponent().appendingPathComponent(backupName)
        guard !fileManager.fileExists(atPath: copia.path) else { return }
        try? fileManager.copyItem(at: archivo, to: copia)
    }

    // MARK: - Las tres ranuras

    /// Las tres entradas que se escriben, y por qué son tres para dos aparatos.
    ///
    /// El emulador enlaza **un solo dispositivo por ranura de jugador**: si hay dos apuntando al
    /// mismo jugador, se queda con uno y el otro no responde. Y el modo de pantalla elige la
    /// ranura: puesto en la base mira `Player1`, y en la mano mira `Handheld`. Con el mando en una
    /// sola de las dos, cambiar de modo dejaría el mando mudo sin que nada lo explicara. Por eso va
    /// **duplicado en las dos**, con el mismo identificador, y el teclado se queda en `Player2` de
    /// respaldo, que es donde no le quita el sitio a nadie.
    static func slots(
        _ profile: SwitchControlProfile,
        pad: (id: String, name: String)?,
        from existing: [[String: Any]]
    ) -> [[String: Any]] {
        let plantillaMando = existing.first { ($0["backend"] as? String) != "WindowKeyboard" }
            ?? gamepadTemplate
        let plantillaTeclado = existing.first { ($0["backend"] as? String) == "WindowKeyboard" }
            ?? keyboardTemplate

        var salida: [[String: Any]] = []
        if let pad {
            let base = gamepadEntry(profile, from: plantillaMando, pad: pad)
            salida.append(place(base, type: "Handheld", slot: "Handheld"))
            salida.append(place(base, type: "ProController", slot: "Player1"))
        }
        salida.append(place(
            keyboardEntry(profile, from: plantillaTeclado),
            type: "ProController", slot: "Player2"
        ))
        return salida
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

    /// La entrada del teclado. Mismo criterio, con la forma que el archivo le da a las palancas de
    /// un teclado: cuatro sentidos por palanca, porque una tecla no tiene medias tintas.
    static func keyboardEntry(
        _ profile: SwitchControlProfile, from template: [String: Any]
    ) -> [String: Any] {
        var entrada = template
        entrada["backend"] = "WindowKeyboard"
        entrada["id"] = "0"
        entrada["name"] = "Keyboard"

        for control in SwitchPadInput.allCases {
            let (sección, clave) = control.field
            var objeto = entrada[sección] as? [String: Any] ?? [:]
            objeto[clave] = profile.keyboardBinding(for: control)
            entrada[sección] = objeto
        }

        for sección in ["left_joycon_stick", "right_joycon_stick"] {
            var objeto = entrada[sección] as? [String: Any] ?? [:]
            for delMando in ["joystick", "invert_stick_x", "invert_stick_y", "rotate90_cw"] {
                objeto.removeValue(forKey: delMando)
            }
            entrada[sección] = objeto
        }
        return entrada
    }

    // MARK: - El identificador del mando

    /// El identificador que el emulador ya tiene guardado para un mando.
    ///
    /// Es el primer sitio donde se busca, y no por ahorrar: el identificador es `0-<GUID de SDL>`, y
    /// ese GUID lleva dentro un CRC del nombre del dispositivo y el bus por el que está conectado.
    /// No se puede construir a mano ni reutilizar entre cable y Bluetooth. El que ya está en el
    /// archivo lo escribió el propio emulador, así que es correcto por definición.
    public static func knownPad(named name: String?, atConfig archivo: URL) -> (id: String, name: String)? {
        guard let datos = try? Data(contentsOf: archivo),
              let raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let perfiles = raíz["input_config"] as? [[String: Any]]
        else { return nil }
        if let name, let exacto = knownPad(in: perfiles, named: name) { return exacto }
        return knownPad(in: perfiles)
    }

    /// La misma búsqueda sobre una lista ya leída. Pública porque es la parte que se puede probar
    /// sin tocar ningún archivo, y porque tomar el teclado por un mando es un fallo silencioso.
    public static func knownPad(
        in profiles: [[String: Any]], named name: String? = nil
    ) -> (id: String, name: String)? {
        for perfil in profiles {
            guard (perfil["backend"] as? String) != "WindowKeyboard",
                  let id = perfil["id"] as? String, !id.isEmpty, id != "0",
                  let nombre = perfil["name"] as? String
            else { continue }
            if let name, nombre != name { continue }
            return (id, nombre)
        }
        return nil
    }

    // MARK: - Las plantillas de respaldo

    /// Lo que se escribe cuando el archivo no tiene **ninguna** entrada que copiar, que es el caso
    /// de un emulador recién instalado que nadie ha abierto todavía. Los valores son los que el
    /// propio emulador pone por omisión; los botones los sustituye `gamepadEntry`.
    ///
    /// Calculadas y no guardadas: un `[String: Any]` no se puede compartir entre hilos, y como
    /// constante estática el compilador lo rechaza con razón. Se arman al pedirlas, que es dos
    /// veces por escritura y solo cuando el archivo no traía nada.
    static var gamepadTemplate: [String: Any] { [
        "version": 1,
        "backend": "GamepadSDL2",
        "deadzone_left": 0.1, "deadzone_right": 0.1,
        "range_left": 1.0, "range_right": 1.0,
        "trigger_threshold": 0.5,
        "motion": ["motion_backend": "GamepadDriver", "sensitivity": 100,
                   "gyro_deadzone": 1.0, "enable_motion": true],
        "rumble": ["strong_rumble": 1.0, "weak_rumble": 1.0, "enable_rumble": true],
        "led": ["enable_led": false, "turn_off_led": false, "use_rainbow": false, "led_color": 0],
        // Los `SL` y `SR` son los botones del lomo de un Joy-Con suelto. Ningún mando entero los
        // tiene, así que se quedan sin asignar en vez de robarle el sitio a otro.
        "left_joycon": ["button_sl": SDLButton.unbound, "button_sr": SDLButton.unbound],
        "right_joycon": ["button_sl": SDLButton.unbound, "button_sr": SDLButton.unbound]
    ] }

    static var keyboardTemplate: [String: Any] { [
        "version": 1,
        "backend": "WindowKeyboard",
        "left_joycon": ["button_sl": SwitchKeyNames.unbound, "button_sr": SwitchKeyNames.unbound],
        "right_joycon": ["button_sl": SwitchKeyNames.unbound, "button_sr": SwitchKeyNames.unbound]
    ] }
}
