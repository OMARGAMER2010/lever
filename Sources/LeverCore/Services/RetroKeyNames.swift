import Foundation

/// Traduce una tecla del Mac al nombre que RetroArch escribe en su configuración.
///
/// Hace falta porque los dos hablan de teclas de forma distinta: macOS da un código de tecla y un
/// carácter, y RetroArch quiere un nombre suyo —`enter`, `rshift`, `kp_enter`—. Equivocarse aquí
/// no da ningún error: escribe una línea que RetroArch ignora, y el usuario ve un botón que no
/// hace nada y no tiene forma de saber por qué.
///
/// El código de tecla manda sobre el carácter a propósito: el carácter depende de la distribución
/// del teclado, y en uno español la tecla que hay donde el inglés tiene la `;` no escribe `;`.
/// Lo que el usuario espera es que la tecla que ha pulsado, en su sitio físico, sea la que quede
/// asignada.
public enum RetroKeyNames {
    /// De código de tecla de macOS al nombre de RetroArch. Solo las que se pueden asignar; las
    /// que no están se rechazan en vez de inventarles un nombre.
    private static let byKeyCode: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",

        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",

        24: "equals", 27: "minus", 33: "leftbracket", 30: "rightbracket", 39: "quote",
        41: "semicolon", 42: "backslash", 43: "comma", 44: "slash", 47: "period", 50: "backquote",

        36: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",

        56: "shift", 60: "rshift", 59: "ctrl", 62: "rctrl", 58: "alt", 61: "ralt",
        55: "meta", 54: "rmeta", 57: "capslock",

        115: "home", 116: "pageup", 117: "del", 119: "end", 121: "pagedown",

        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",

        // Teclado numérico. RetroArch los llama `kp0`… y al Intro suyo `kp_enter`.
        82: "kp0", 83: "kp1", 84: "kp2", 85: "kp3", 86: "kp4", 87: "kp5",
        88: "kp6", 89: "kp7", 91: "kp8", 92: "kp9",
        65: "kp_period", 67: "kp_multiply", 69: "kp_plus", 75: "kp_divide",
        76: "kp_enter", 78: "kp_minus", 71: "numlock"
    ]

    /// El nombre de RetroArch para un código de tecla de macOS, o `nil` si esa tecla no se puede
    /// asignar. Devolver `nil` es una respuesta: la interfaz sigue escuchando en vez de guardar
    /// una asignación que no va a funcionar.
    public static func name(forKeyCode code: UInt16) -> String? {
        byKeyCode[code]
    }

    /// Cómo se enseña una tecla en el diagrama. El nombre interno de RetroArch vale para el
    /// archivo, pero «rshift» en pantalla se lee peor que «⇧ der.».
    public static func label(for name: String) -> String {
        let bonitos: [String: String] = [
            "enter": "↩", "kp_enter": "↩ num", "space": "espacio", "escape": "esc",
            "backspace": "⌫", "tab": "⇥", "up": "↑", "down": "↓", "left": "←", "right": "→",
            "shift": "⇧", "rshift": "⇧ der.", "ctrl": "ctrl", "rctrl": "ctrl der.",
            "alt": "⌥", "ralt": "⌥ der.", "meta": "⌘", "rmeta": "⌘ der.",
            "minus": "-", "equals": "=", "comma": ",", "period": ".", "slash": "/",
            "backslash": "\\", "semicolon": ";", "quote": "'", "backquote": "`",
            "leftbracket": "[", "rightbracket": "]", "del": "supr", "nul": "—"
        ]
        return bonitos[name] ?? name.uppercased()
    }
}
