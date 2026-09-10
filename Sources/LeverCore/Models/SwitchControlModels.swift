import Foundation

/// Un control del mando de la consola híbrida.
///
/// Va aparte de `RetroPadInput` y no es duplicación: el RetroPad es el mando imaginario de
/// libretro, con nombres de PlayStation, y esta consola tiene los suyos —`ZL` donde aquel dice
/// `L2`, `−` y `+` donde dice `Select` y `Start`—. Escribir `button_zl` desde un caso llamado `l2`
/// sería mentir en el sitio donde más caro sale: el archivo de otro programa.
///
/// Lo que sí se comparte es **la posición**. Los dos mandos tienen la misma forma, así que cada
/// control sabe a qué sitio del dibujo corresponde (`spot`) y el diagrama se reaprovecha entero.
public enum SwitchPadInput: String, CaseIterable, Sendable, Codable, Identifiable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case a, b, x, y
    case l, r, zl, zr
    case minus, plus
    case leftStickButton, rightStickButton
    /// Los sentidos de las palancas. **Solo existen para el teclado**: un mando asigna la palanca
    /// entera —`joystick: "Left"`— y no sus cuatro sentidos. Es una diferencia de forma del propio
    /// archivo, y el modelo la respeta en vez de aplanarla.
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight

    public var id: String { rawValue }

    /// A qué sitio del dibujo corresponde. La coincidencia es exacta y no casual: los dos mandos
    /// tienen cuatro botones en rombo, dos gatillos por lado y dos palancas en el mismo sitio.
    public var spot: RetroPadInput {
        switch self {
        case .dpadUp: return .up
        case .dpadDown: return .down
        case .dpadLeft: return .left
        case .dpadRight: return .right
        // El rombo, por posición: la `A` de esta consola está a la derecha, que es donde el
        // RetroPad tiene su `a`; la `B` abajo, la `X` arriba y la `Y` a la izquierda.
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .l: return .l
        case .r: return .r
        case .zl: return .l2
        case .zr: return .r2
        case .minus: return .select
        case .plus: return .start
        case .leftStickButton: return .l3
        case .rightStickButton: return .r3
        case .leftStickUp: return .leftStickUp
        case .leftStickDown: return .leftStickDown
        case .leftStickLeft: return .leftStickLeft
        case .leftStickRight: return .leftStickRight
        case .rightStickUp: return .rightStickUp
        case .rightStickDown: return .rightStickDown
        case .rightStickLeft: return .rightStickLeft
        case .rightStickRight: return .rightStickRight
        }
    }

    /// Cómo lo llama la consola. Es lo que va escrito en la hoja, porque es lo que el juego enseña
    /// en pantalla cuando dice «pulsa A».
    public var label: String {
        switch self {
        case .dpadUp: return "↑"
        case .dpadDown: return "↓"
        case .dpadLeft: return "←"
        case .dpadRight: return "→"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .minus: return "−"
        case .plus: return "+"
        case .leftStickButton: return "L3"
        case .rightStickButton: return "R3"
        case .leftStickUp: return "L ↑"
        case .leftStickDown: return "L ↓"
        case .leftStickLeft: return "L ←"
        case .leftStickRight: return "L →"
        case .rightStickUp: return "R ↑"
        case .rightStickDown: return "R ↓"
        case .rightStickLeft: return "R ←"
        case .rightStickRight: return "R →"
        }
    }

    /// Dónde vive en el `Config.json`: el objeto que lo contiene y la clave.
    ///
    /// El emulador reparte los controles como si fueran dos Joy-Con sueltos, aunque se esté usando
    /// un mando entero: la cruceta y el `ZL` cuelgan del izquierdo, el rombo y el `+` del derecho.
    public var field: (section: String, key: String) {
        switch self {
        case .dpadUp: return ("left_joycon", "dpad_up")
        case .dpadDown: return ("left_joycon", "dpad_down")
        case .dpadLeft: return ("left_joycon", "dpad_left")
        case .dpadRight: return ("left_joycon", "dpad_right")
        case .minus: return ("left_joycon", "button_minus")
        case .l: return ("left_joycon", "button_l")
        case .zl: return ("left_joycon", "button_zl")
        case .a: return ("right_joycon", "button_a")
        case .b: return ("right_joycon", "button_b")
        case .x: return ("right_joycon", "button_x")
        case .y: return ("right_joycon", "button_y")
        case .plus: return ("right_joycon", "button_plus")
        case .r: return ("right_joycon", "button_r")
        case .zr: return ("right_joycon", "button_zr")
        case .leftStickButton: return ("left_joycon_stick", "stick_button")
        case .rightStickButton: return ("right_joycon_stick", "stick_button")
        case .leftStickUp: return ("left_joycon_stick", "stick_up")
        case .leftStickDown: return ("left_joycon_stick", "stick_down")
        case .leftStickLeft: return ("left_joycon_stick", "stick_left")
        case .leftStickRight: return ("left_joycon_stick", "stick_right")
        case .rightStickUp: return ("right_joycon_stick", "stick_up")
        case .rightStickDown: return ("right_joycon_stick", "stick_down")
        case .rightStickLeft: return ("right_joycon_stick", "stick_left")
        case .rightStickRight: return ("right_joycon_stick", "stick_right")
        }
    }

    /// Los que un mando puede asignar. Deja fuera los sentidos de las palancas por lo dicho arriba.
    public static let onGamepad: [SwitchPadInput] = [
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
        .a, .b, .x, .y, .l, .r, .zl, .zr, .minus, .plus,
        .leftStickButton, .rightStickButton
    ]

    /// Los cuatro del rombo, que son los únicos que cambian entre las dos disposiciones.
    public static let faces: [SwitchPadInput] = [.a, .b, .x, .y]

    /// El que ocupa ese sitio del dibujo. La correspondencia es de uno a uno en los dos sentidos:
    /// cada control tiene su sitio y cada sitio tiene su control.
    public static func at(_ spot: RetroPadInput) -> SwitchPadInput? { bySpot[spot] }

    private static let bySpot: [RetroPadInput: SwitchPadInput] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.spot, $0) }
    )
}

/// Cómo se traduce el rombo de la consola al rombo del mando que hay puesto.
///
/// Es la única decisión de mapeo que la mayoría de la gente va a querer tocar, y las dos respuestas
/// son legítimas porque responden a dos memorias distintas.
public enum SwitchFaceLayout: String, Equatable, Sendable, Codable, CaseIterable {
    /// **Por posición.** La `A` de la consola —la de la derecha— se pulsa con el botón de la
    /// derecha del mando: el círculo en un DualSense. Reproduce la consola: confirmar sigue
    /// estando donde estaba. Es la de fábrica.
    case byPosition
    /// **Por etiqueta.** La `A` de la consola se pulsa con el botón que dice `A`: la cruz en un
    /// DualSense. Para quien viene de PlayStation y salta con la cruz sin pensarlo.
    case byLabel

    public var textKey: TextKey {
        switch self {
        case .byPosition: return .switchFaceByPosition
        case .byLabel: return .switchFaceByLabel
        }
    }

    public var other: SwitchFaceLayout { self == .byPosition ? .byLabel : .byPosition }
}

/// Cómo se llaman los botones de un mando en el archivo del emulador.
///
/// Son los nombres de SDL, que son los de un mando de Xbox: `A` es el de abajo, `B` el de la
/// derecha, `X` el de la izquierda e `Y` el de arriba. **Es la fuente de toda la confusión de este
/// archivo**, y por eso están aquí con nombre propio en vez de sueltos como cadenas.
public enum SDLButton {
    public static let bottom = "A"
    public static let right = "B"
    public static let left = "X"
    public static let top = "Y"
    public static let leftShoulder = "LeftShoulder"
    public static let rightShoulder = "RightShoulder"
    public static let leftTrigger = "LeftTrigger"
    public static let rightTrigger = "RightTrigger"
    public static let leftStick = "LeftStick"
    public static let rightStick = "RightStick"
    public static let dpadUp = "DpadUp"
    public static let dpadDown = "DpadDown"
    public static let dpadLeft = "DpadLeft"
    public static let dpadRight = "DpadRight"
    public static let back = "Back"
    public static let start = "Start"
    public static let unbound = "Unbound"

    /// Los que se pueden elegir en la hoja, en el orden en que se leen en el mando.
    public static let assignable = [
        top, left, right, bottom,
        leftShoulder, rightShoulder, leftTrigger, rightTrigger,
        dpadUp, dpadDown, dpadLeft, dpadRight,
        leftStick, rightStick, back, start, unbound
    ]

    /// Cómo se enseña en pantalla, con los nombres serigrafiados en el mando que hay puesto. En un
    /// DualSense no pone «A» por ninguna parte: pone una cruz.
    public static func label(_ name: String, family: ConnectedGamepad.Family) -> String {
        switch name {
        case bottom: return family.faceLabels.b
        case right: return family.faceLabels.a
        case left: return family.faceLabels.y
        case top: return family.faceLabels.x
        case leftShoulder: return family.shoulderLabels.l
        case rightShoulder: return family.shoulderLabels.r
        case leftTrigger: return family.shoulderLabels.l2
        case rightTrigger: return family.shoulderLabels.r2
        case leftStick: return family.stickLabels.left
        case rightStick: return family.stickLabels.right
        case dpadUp: return "↑"
        case dpadDown: return "↓"
        case dpadLeft: return "←"
        case dpadRight: return "→"
        case back: return family.menuLabels.select
        case start: return family.menuLabels.start
        case unbound: return "—"
        default: return name
        }
    }
}

/// Con qué se juega a un juego de la consola híbrida.
///
/// Guarda **solo lo que el usuario ha cambiado**. Un perfil vacío no significa «sin controles»:
/// significa la traducción de fábrica, que es la que hace que un juego recién soltado se juegue sin
/// tocar nada. Es la diferencia entre un archivo de dos líneas y uno de cuarenta que hay que
/// mantener al día cada vez que cambie un valor por omisión.
public enum SwitchInputDevice: String, CaseIterable, Codable, Sendable {
    case keyboardMouse, gamepad

    public var textKey: TextKey { self == .keyboardMouse ? .switchKeyboardMouse : .switchGamepad }
}

public struct SwitchControlProfile: Equatable, Sendable, Codable {
    public var faceLayout: SwitchFaceLayout
    public var inputDevice: SwitchInputDevice
    public var mouseSensitivity: Double
    public var invertMouseY: Bool
    /// Lo que el usuario haya cambiado del mando, con nombres de SDL.
    public var gamepad: [SwitchPadInput: String]
    /// Lo que haya cambiado del teclado, con nombres de Ryujinx.
    public var keyboard: [SwitchPadInput: String]

    public init(
        faceLayout: SwitchFaceLayout = .byPosition,
        gamepad: [SwitchPadInput: String] = [:],
        keyboard: [SwitchPadInput: String] = [:],
        inputDevice: SwitchInputDevice = .keyboardMouse,
        mouseSensitivity: Double = 1,
        invertMouseY: Bool = false
    ) {
        self.faceLayout = faceLayout
        self.gamepad = gamepad
        self.keyboard = keyboard
        self.inputDevice = inputDevice
        self.mouseSensitivity = mouseSensitivity
        self.invertMouseY = invertMouseY
    }

    private enum CodingKeys: String, CodingKey {
        case faceLayout, gamepad, keyboard, inputDevice, mouseSensitivity, invertMouseY
    }

    public init(from decoder: any Decoder) throws {
        let valores = try decoder.container(keyedBy: CodingKeys.self)
        faceLayout = try valores.decodeIfPresent(SwitchFaceLayout.self, forKey: .faceLayout) ?? .byPosition
        gamepad = try valores.decodeIfPresent([SwitchPadInput: String].self, forKey: .gamepad) ?? [:]
        keyboard = try valores.decodeIfPresent([SwitchPadInput: String].self, forKey: .keyboard) ?? [:]
        inputDevice = try valores.decodeIfPresent(SwitchInputDevice.self, forKey: .inputDevice) ?? .keyboardMouse
        mouseSensitivity = try valores.decodeIfPresent(Double.self, forKey: .mouseSensitivity) ?? 1
        invertMouseY = try valores.decodeIfPresent(Bool.self, forKey: .invertMouseY) ?? false
    }

    /// La de fábrica: por posición y sin nada tocado.
    public static let standard = SwitchControlProfile()

    public var isUntouched: Bool {
        faceLayout == .byPosition && gamepad.isEmpty && keyboard.isEmpty && inputDevice == .keyboardMouse
            && mouseSensitivity == 1 && !invertMouseY
    }

    // MARK: - Lo que de verdad se va a escribir

    public func gamepadBinding(for input: SwitchPadInput) -> String {
        gamepad[input] ?? Self.defaultGamepad(faceLayout)[input] ?? SDLButton.unbound
    }

    public func keyboardBinding(for input: SwitchPadInput) -> String {
        keyboard[input] ?? Self.defaultKeyboard[input] ?? SwitchKeyNames.unbound
    }

    /// La traducción automática del mando de la consola al que haya puesto.
    ///
    /// Todo va por posición menos el rombo, que es lo único que las dos disposiciones discuten: los
    /// gatillos, la cruceta y las palancas están en el mismo sitio en cualquier mando.
    public static func defaultGamepad(_ layout: SwitchFaceLayout) -> [SwitchPadInput: String] {
        var mapa: [SwitchPadInput: String] = [
            .dpadUp: SDLButton.dpadUp, .dpadDown: SDLButton.dpadDown,
            .dpadLeft: SDLButton.dpadLeft, .dpadRight: SDLButton.dpadRight,
            .l: SDLButton.leftShoulder, .r: SDLButton.rightShoulder,
            .zl: SDLButton.leftTrigger, .zr: SDLButton.rightTrigger,
            .minus: SDLButton.back, .plus: SDLButton.start,
            .leftStickButton: SDLButton.leftStick, .rightStickButton: SDLButton.rightStick
        ]
        switch layout {
        // La `A` de la consola está a la derecha, y el botón de la derecha se llama `B` en SDL.
        // Esa inversión es la que hace que confirmar siga cayendo donde el usuario lo espera.
        case .byPosition:
            mapa[.a] = SDLButton.right
            mapa[.b] = SDLButton.bottom
            mapa[.x] = SDLButton.top
            mapa[.y] = SDLButton.left
        // Letra con letra. En un DualSense esto pone la `A` en la cruz, que es lo que quiere quien
        // lleva veinte años saltando con la cruz.
        case .byLabel:
            mapa[.a] = SDLButton.bottom
            mapa[.b] = SDLButton.right
            mapa[.x] = SDLButton.left
            mapa[.y] = SDLButton.top
        }
        return mapa
    }

    /// Las acciones frecuentes quedan junto a WASD. Los nombres siguen siendo los botones de la
    /// consola: Shift es ZL, cuyo significado depende del juego y no siempre es correr.
    public static let defaultKeyboard: [SwitchPadInput: String] = [
        .dpadUp: "Up", .dpadDown: "Down", .dpadLeft: "Left", .dpadRight: "Right",
        .a: "E", .b: "Space", .x: "C", .y: "F",
        .l: "Q", .r: "R", .zl: "ShiftLeft", .zr: "V",
        .minus: "Tab", .plus: "Enter",
        .leftStickButton: "G", .rightStickButton: "H",
        .leftStickUp: "W", .leftStickDown: "S", .leftStickLeft: "A", .leftStickRight: "D",
        .rightStickUp: "I", .rightStickDown: "K", .rightStickLeft: "J", .rightStickRight: "L"
    ]
}

/// A qué se le aplica un perfil de la consola híbrida.
///
/// Dos niveles y no tres, al revés que en RetroArch: aquí solo hay una máquina, así que el escalón
/// de «así juego a la Nintendo 64» no significa nada.
public enum SwitchControlScope: Equatable, Sendable, Codable {
    case global
    /// El identificador de dieciséis dígitos del juego, o su nombre de archivo si no se ha podido
    /// leer. **La identidad de verdad es el identificador**: el nombre lo pone quien comparte el
    /// archivo y dos copias del mismo juego se llaman distinto.
    case game(String)

    public var fileName: String {
        switch self {
        case .global: return "global.json"
        case .game(let id): return "juego-\(id).json"
        }
    }

    public var textKey: TextKey {
        switch self {
        case .global: return .switchControlsScopeGlobal
        case .game: return .switchControlsScopeGame
        }
    }
}

/// Los `[SwitchPadInput: String]` no se codifican solos: un diccionario con clave que no es
/// `String` se guarda como una lista plana, y entonces el archivo no hay quien lo lea ni lo
/// arregle a mano. Con esto se guarda como un objeto de verdad.
extension SwitchPadInput: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}
