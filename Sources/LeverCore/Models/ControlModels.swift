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
        case .leftStickUp, .leftStickDown, .leftStickLeft, .rightStickUp: return "LS"
        case .leftStickRight, .rightStickDown, .rightStickLeft, .rightStickRight: return "RS"
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
    public static func available(on platform: RetroPlatform?) -> [RetroPadInput] {
        guard let platform else { return onDiagram }
        switch platform.id {
        case "nes", "sms": return [.up, .down, .left, .right, .a, .b, .start, .select]
        case "gb": return [.up, .down, .left, .right, .a, .b, .start, .select]
        case "gba": return [.up, .down, .left, .right, .a, .b, .l, .r, .start, .select]
        case "snes": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start, .select]
        case "megadrive": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start]
        case "n64": return [.up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .l2, .start,
                            .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight]
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
    public var label: String {
        switch self {
        case .key(let tecla): return tecla
        case .button(let número): return "botón \(número)"
        case .axis(let eje): return "eje \(eje)"
        case .hat(_, let dirección): return "cruceta \(dirección)"
        case .none: return "—"
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
        .l3: .key("d"), .r3: .key("f"),
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
    public static let wasd = ControlProfile(
        id: "wasd", name: "WASD",
        keyboard: defaultKeyboard.merging([
            .up: .key("w"), .down: .key("s"), .left: .key("a"), .right: .key("d"),
            .a: .key("l"), .b: .key("k"), .x: .key("i"), .y: .key("j"),
            .l: .key("u"), .r: .key("o")
        ]) { _, nuevo in nuevo }
    )

    public static let builtIn: [ControlProfile] = [standard, wasd]

    public func binding(for input: RetroPadInput) -> ControlBinding {
        keyboard[input] ?? .none
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
