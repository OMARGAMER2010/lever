import Foundation

/// Un control del mando virtual al que todo se traduce.
///
/// libretro no habla de mandos de verdad: habla de un mando imaginario —el «RetroPad»— con la
/// forma del de PlayStation, y cada núcleo traduce ese mando al de su consola. Por eso mapear un
/// mando de Xbox a una Game Boy no es un problema de dos piezas sino de tres, y la de en medio es
/// siempre esta. Todo lo que Lever asigna, lo asigna aquí.
public enum RetroPadInput: String, CaseIterable, Sendable, Codable, Identifiable {
    case up, down, left, right
    case a, b, x, y
    case l, r, l2, r2, l3, r3
    case start, select
    /// Palancas. Se guardan por eje y sentido porque así las nombra RetroArch.
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight

    public var id: String { rawValue }

    /// Cómo lo llama RetroArch en su configuración. No es el mismo nombre que el nuestro: el suyo
    /// es el que entiende el archivo, y equivocarse aquí no da error, solo un botón que no hace
    /// nada.
    public var retroArchName: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .a: return "a"
        case .b: return "b"
        case .x: return "x"
        case .y: return "y"
        case .l: return "l"
        case .r: return "r"
        case .l2: return "l2"
        case .r2: return "r2"
        case .l3: return "l3"
        case .r3: return "r3"
        case .start: return "start"
        case .select: return "select"
        case .leftStickUp: return "l_y_minus"
        case .leftStickDown: return "l_y_plus"
        case .leftStickLeft: return "l_x_minus"
        case .leftStickRight: return "l_x_plus"
        case .rightStickUp: return "r_y_minus"
        case .rightStickDown: return "r_y_plus"
        case .rightStickLeft: return "r_x_minus"
        case .rightStickRight: return "r_x_plus"
        }
    }

    /// Cómo se llama en el mando que la gente tiene en la mano. El RetroPad tiene forma de mando
    /// de PlayStation, así que enseñarlo con esos nombres es lo que menos confunde.
    public var symbol: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .a: return "○"
        case .b: return "✕"
        case .x: return "△"
        case .y: return "□"
        case .l: return "L1"
        case .r: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        case .start: return "Start"
        case .select: return "Select"
        // Estaban partidos cuatro y cuatro por el orden en que están escritos, no por la palanca a
        // la que pertenecen: «izquierda de la palanca izquierda» decía RS y «arriba de la derecha»
        // decía LS. Quien remapeaba asignaba la otra.
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight: return "LS"
        case .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight: return "RS"
        }
    }

    /// Los que se enseñan en el diagrama del mando, en el orden en que se leen.
    public static let onDiagram: [RetroPadInput] = [
        .l2, .l, .up, .down, .left, .right, .select, .start, .x, .y, .a, .b, .r, .r2, .l3, .r3
    ]

    /// Los botones que existen de verdad en la consola emulada.
    ///
    /// Enseñar dieciséis botones para una Game Boy, que tiene cuatro y dos, es enseñar catorce
    /// casillas que no hacen nada. Cada máquina tiene los suyos.
    /// Cómo se llama este control **en esta consola**, cuando ahí no es lo que su nombre dice.
    ///
    /// El mando que dibuja Lever es el RetroPad, que tiene gatillos; la DS no. Su núcleo usa esos
    /// cuatro sitios para otras cosas, así que enseñarlos como «L2» o «R3» sería enseñar cuatro
    /// casillas que no se entienden. `nil` significa «el nombre de siempre».
    public func consoleLabel(on platform: RetroPlatform?) -> TextKey? {
        guard platform?.id == "nds" else { return nil }
        switch self {
        case .l2: return .controlDSMicrophone
        case .r2: return .controlDSSwapScreens
        case .l3: return .controlDSCloseLid
        case .r3: return .controlDSStylusStick
        default: return nil
        }
    }

    public static let leftStick: [RetroPadInput] = [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight]
    public static let rightStick: [RetroPadInput] = [.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight]

    public static func available(on platform: RetroPlatform?) -> [RetroPadInput] {
        guard let platform else { return onDiagram }
        switch platform.id {
        case "nes", "sms": return [.up, .down, .left, .right, .a, .b, .start, .select]
        case "gb": return [.up, .down, .left, .right, .a, .b, .start, .select]
        case "gba": return [.up, .down, .left, .right, .a, .b, .l, .r, .start, .select]
        case "snes": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start, .select]
        case "megadrive": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start]
        // Los botones C de la N64 son la palanca derecha: así los mapea su núcleo, y sin ellos en
        // la lista no había forma de tocarlos —y hay juegos que no se pueden jugar sin las C.
        case "n64": return [.up, .down, .left, .right, .a, .b, .l, .r, .l2, .start]
            + leftStick + rightStick
        // La palanca del mando con el que se jugó de verdad. Antes caían todas en la lista genérica,
        // que no la trae: en la PlayStation, la Dreamcast, la PSP y la 3DS no se podía remapear.
        case "psx": return onDiagram + leftStick + rightStick
        case "dreamcast": return [.up, .down, .left, .right, .a, .b, .x, .y, .l2, .r2, .start] + leftStick
        case "psp": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start, .select] + leftStick
        // La de abajo se toca con el puntero, no con un botón; la 3DS además trae deslizador.
        //
        // Los cuatro de atrás no son gatillos en la DS: su núcleo los usa para soplar al micrófono
        // (L2), cambiar las pantallas de sitio (R2), cerrar la tapa (L3) y mover el lápiz con la
        // palanca (R3). Sin ellos en la lista no había forma de asignarlos, y hay juegos que piden
        // soplar o cerrar la tapa para pasar de sitio.
        case "nds": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start, .select,
                            .l2, .r2, .l3, .r3]
        case "3ds": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .l2, .r2, .start, .select]
            + leftStick + rightStick
        default: return onDiagram
        }
    }
}

/// A qué está atado un control del RetroPad.
public enum ControlBinding: Equatable, Sendable, Codable {
    /// Una tecla, con el nombre que usa RetroArch (`z`, `enter`, `rshift`…).
    case key(String)
    /// Un botón del mando, por su número.
    case button(Int)
    /// Un eje del mando, con su signo (`+0`, `-1`).
    case axis(String)
    /// Una dirección de la cruceta, por su número.
    case hat(Int, String)
    /// Sin asignar. Existe a propósito: dejar un botón sin nada es una decisión válida.
    case none

    /// Cómo se enseña en el diagrama.
    ///
    /// Los nombres internos de RetroArch valen para el archivo y se leen mal en pantalla: `rshift`
    /// es «⇧ der.» y `up` de una cruceta es una flecha, no la palabra.
    public func label(_ strings: Strings) -> String {
        switch self {
        case .key(let tecla): return RetroKeyNames.label(for: tecla)
        case .button(let número): return strings(.controlsButton, String(número))
        case .axis(let eje): return strings(.controlsAxis, eje)
        case .hat(_, let dirección): return strings(.controlsHat, Self.arrow(for: dirección))
        case .none: return strings[.controlsUnassigned]
        }
    }

    private static func arrow(for direction: String) -> String {
        switch direction {
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        default: return direction
        }
    }

    public var isAssigned: Bool { self != .none }
}

/// Un juego de asignaciones completo: teclado y mando.
///
/// Se guarda tal cual en disco —es `Codable`— porque el usuario puede tener varios y quiere que
/// sigan ahí la próxima vez.
public struct ControlProfile: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// Teclado. Siempre lleno: es lo que garantiza que un juego se pueda jugar sin mando.
    public var keyboard: [RetroPadInput: ControlBinding]
    /// Mando. Vacío significa «lo que RetroArch reconozca solo», que para los mandos conocidos
    /// funciona sin tocar nada.
    public var gamepad: [RetroPadInput: ControlBinding]

    public init(
        id: String, name: String,
        keyboard: [RetroPadInput: ControlBinding],
        gamepad: [RetroPadInput: ControlBinding] = [:]
    ) {
        self.id = id
        self.name = name
        self.keyboard = keyboard
        self.gamepad = gamepad
    }

    /// La disposición por omisión, que es la que asumen todas las guías y todos los tutoriales de
    /// emulación desde hace veinte años: cursores para moverse, Z y X para los dos botones, A y S
    /// para los otros dos, Q y W para los gatillos, Enter para empezar.
    ///
    /// No se inventa una mejor a propósito. Un usuario que busque ayuda en internet va a encontrar
    /// esta, y que la suya sea otra es una pelea que no vale la pena.
    public static let defaultKeyboard: [RetroPadInput: ControlBinding] = [
        .up: .key("up"), .down: .key("down"), .left: .key("left"), .right: .key("right"),
        .a: .key("x"), .b: .key("z"), .x: .key("s"), .y: .key("a"),
        .l: .key("q"), .r: .key("w"), .l2: .key("e"), .r2: .key("r"),
        // La `v` y no la `f`: la `f` ya la usa la palanca izquierda, y dos controles en la misma
        // tecla es uno de los dos que no responde. Además la `f` es la de pantalla completa.
        .l3: .key("d"), .r3: .key("v"),
        .start: .key("enter"), .select: .key("rshift"),
        .leftStickUp: .key("t"), .leftStickDown: .key("g"),
        .leftStickLeft: .key("f"), .leftStickRight: .key("h"),
        .rightStickUp: .key("i"), .rightStickDown: .key("k"),
        .rightStickLeft: .key("j"), .rightStickRight: .key("l")
    ]

    public static let standard = ControlProfile(
        id: "estandar", name: "Estándar", keyboard: defaultKeyboard
    )

    /// La otra disposición que existe de verdad: WASD para moverse, que es lo que espera quien
    /// viene de jugar en PC.
    ///
    /// Antes se escribía encima de la de arriba solo a medias y quedaban cinco teclas con dos
    /// controles cada una: `i`, `j`, `k` y `l` eran botón **y** palanca derecha a la vez, y `d`
    /// movía y pulsaba L3. Dos controles en la misma tecla es uno que no responde.
    ///
    /// Ahora se escribe entera. Al mover el movimiento a WASD, los cursores quedan libres y son el
    /// sitio natural para la palanca derecha —la de mirar—, que es justo lo que hace falta en las
    /// consolas de tres dimensiones. WASD lleva la cruceta y la palanca izquierda a la vez: es lo
    /// que hace que la misma disposición valga para un juego plano y para uno en tres dimensiones.
    public static let wasd = ControlProfile(
        id: "wasd", name: "WASD",
        keyboard: [
            .up: .key("w"), .down: .key("s"), .left: .key("a"), .right: .key("d"),
            .leftStickUp: .key("w"), .leftStickDown: .key("s"),
            .leftStickLeft: .key("a"), .leftStickRight: .key("d"),
            .rightStickUp: .key("up"), .rightStickDown: .key("down"),
            .rightStickLeft: .key("left"), .rightStickRight: .key("right"),
            .a: .key("l"), .b: .key("k"), .x: .key("i"), .y: .key("j"),
            .l: .key("u"), .r: .key("o"), .l2: .key("e"), .r2: .key("r"),
            .l3: .key("c"), .r3: .key("v"),
            .start: .key("enter"), .select: .key("rshift")
        ]
    )

    public static let builtIn: [ControlProfile] = [standard, wasd]

    public func binding(for input: RetroPadInput) -> ControlBinding {
        keyboard[input] ?? .none
    }

    /// Lo que tenga el mando para ese control. Va aparte del teclado a propósito: RetroArch
    /// escribe las dos cosas por control —una línea para la tecla y otra para el botón— y las dos
    /// valen a la vez, así que asignar un botón no debe borrar la tecla.
    public func gamepadBinding(for input: RetroPadInput) -> ControlBinding {
        gamepad[input] ?? .none
    }
}

/// A qué se le aplican unas asignaciones.
///
/// Tres niveles, del más general al más concreto, porque es como la gente lo piensa: «así juego
/// yo», «así juego a la Nintendo 64, que tiene una palanca» y «en este juego cambié el salto».
public enum ControlScope: Equatable, Sendable, Codable {
    case global
    case platform(String)
    case game(String)

    /// Nombre del archivo donde se guardan. El del juego lleva su nombre para que se pueda
    /// encontrar y borrar a mano, que es lo que la gente acaba haciendo.
    public var fileName: String {
        switch self {
        case .global: return "global.json"
        case .platform(let id): return "plataforma-\(id).json"
        case .game(let nombre): return "juego-\(nombre).json"
        }
    }
}
