import Foundation

/// Traduce una tecla del Mac al nombre que escribe el emulador de la consola híbrida.
///
/// Existe aparte de `RetroKeyNames` en vez de encadenarse con ella porque pasar por los nombres de
/// RetroArch sería una traducción doble con el medio lleno de pérdidas: RetroArch llama `shift` a
/// la izquierda y `rshift` a la derecha, este emulador las llama `ShiftLeft` y `ShiftRight`, y hay
/// teclas que uno nombra y el otro no. Cada traducción sale del código de tecla, que es el hecho.
///
/// El código de tecla manda sobre el carácter por lo mismo que allí: el carácter depende de la
/// distribución, y en un teclado español la tecla donde el inglés tiene la `;` no escribe `;`. Lo
/// que el usuario espera es que la tecla que ha pulsado, en su sitio físico, sea la que quede.
public enum SwitchKeyNames {
    /// Lo que el emulador escribe para «este control no hace nada».
    public static let unbound = "Unbound"

    /// De código de tecla de macOS al nombre del emulador. Solo las que se pueden asignar; las que
    /// no están se rechazan en vez de inventarles un nombre que el archivo ignoraría en silencio.
    private static let byKeyCode: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",

        // Los números de la fila de arriba se llaman `Number0`… para no chocar con los del
        // teclado numérico, que son `Keypad0`…
        18: "Number1", 19: "Number2", 20: "Number3", 21: "Number4", 22: "Number6",
        23: "Number5", 25: "Number9", 26: "Number7", 28: "Number8", 29: "Number0",

        // Ojo: aquí `Plus` y `Minus` son las **teclas** `=` y `-`, no los botones `+` y `−` de la
        // consola. Coinciden de nombre y no de significado, y es justo el sitio donde una prueba
        // de menos deja un control mudo.
        24: "Plus", 27: "Minus", 33: "BracketLeft", 30: "BracketRight", 39: "Quote",
        41: "Semicolon", 42: "BackSlash", 43: "Comma", 44: "Slash", 47: "Period", 50: "Tilde",

        36: "Enter", 48: "Tab", 49: "Space", 51: "BackSpace", 53: "Escape",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",

        56: "ShiftLeft", 60: "ShiftRight", 59: "ControlLeft", 62: "ControlRight",
        58: "AltLeft", 61: "AltRight", 55: "WinLeft", 54: "WinRight", 57: "CapsLock",

        115: "Home", 116: "PageUp", 117: "Delete", 119: "End", 121: "PageDown",

        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",

        82: "Keypad0", 83: "Keypad1", 84: "Keypad2", 85: "Keypad3", 86: "Keypad4",
        87: "Keypad5", 88: "Keypad6", 89: "Keypad7", 91: "Keypad8", 92: "Keypad9",
        65: "KeypadDecimal", 67: "KeypadMultiply", 69: "KeypadAdd", 75: "KeypadDivide",
        76: "KeypadEnter", 78: "KeypadSubtract", 71: "NumLock"
    ]

    /// El nombre del emulador para un código de tecla de macOS, o `nil` si esa tecla no se puede
    /// asignar. Devolver `nil` es una respuesta: la hoja sigue escuchando en vez de guardar una
    /// asignación que no va a funcionar.
    public static func name(forKeyCode code: UInt16) -> String? {
        byKeyCode[code]
    }

    public static func keyCode(for name: String) -> UInt16? {
        byKeyCode.first { $0.value == name }?.key
    }

    /// Cómo se enseña una tecla en la hoja. El nombre del archivo vale para el archivo, pero
    /// «ShiftLeft» en pantalla se lee peor que «⇧», y «Tilde» no dice qué tecla es.
    public static func label(for name: String) -> String {
        if let bonito = pretty[name] { return bonito }
        // `Number7` se enseña como `7`, que es lo que lleva escrito la tecla.
        if name.hasPrefix("Number"), let dígito = name.last { return String(dígito) }
        if name.hasPrefix("Keypad"), let dígito = name.last, dígito.isNumber {
            return "\(dígito) num"
        }
        return name
    }

    private static let pretty: [String: String] = [
        "Enter": "↩", "KeypadEnter": "↩ num", "Space": "espacio", "Escape": "esc",
        "BackSpace": "⌫", "Tab": "⇥", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→",
        "ShiftLeft": "⇧", "ShiftRight": "⇧ der.", "ControlLeft": "ctrl",
        "ControlRight": "ctrl der.", "AltLeft": "⌥", "AltRight": "⌥ der.",
        "WinLeft": "⌘", "WinRight": "⌘ der.", "CapsLock": "⇪",
        "Minus": "-", "Plus": "=", "Comma": ",", "Period": ".", "Slash": "/",
        "BackSlash": "\\", "Semicolon": ";", "Quote": "'", "Tilde": "`",
        "BracketLeft": "[", "BracketRight": "]",
        "Delete": "⌦", "Home": "inicio", "End": "fin", "PageUp": "re pág",
        "PageDown": "av pág", "NumLock": "bloq num",
        "KeypadDecimal": ". num", "KeypadMultiply": "× num", "KeypadAdd": "+ num",
        "KeypadDivide": "÷ num", "KeypadSubtract": "− num",
        unbound: "—"
    ]
}
