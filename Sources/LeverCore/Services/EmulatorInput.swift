import Foundation

/// Con qué se juega: lo que el emulador tiene configurado para recibir entrada.
///
/// Lever **lee** esto, no lo escribe. La diferencia importa: el mapeo de controles que Lever sí
/// escribe es el de RetroArch, porque ahí Lever elige el núcleo y monta la partida entera. Un
/// emulador de programa aparte lo instala el usuario, trae su propia configuración y la cambia en
/// sus propias versiones; escribirle dentro sería romperse en cada actualización suya.
///
/// Pero callarlo tampoco vale. Un juego que arranca y no responde a nada es indistinguible de un
/// juego roto, y la causa —que el emulador solo tiene el teclado, o nada— está a un archivo de
/// distancia. Decirlo es barato y es justo lo que este proyecto hace con las llaves y el firmware.
public struct EmulatorInputDevice: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case keyboard
        case gamepad

        public var textKey: TextKey {
            switch self {
            case .keyboard: return .inputKindKeyboard
            case .gamepad: return .inputKindGamepad
            }
        }
    }

    public let kind: Kind
    /// El nombre que el emulador guardó del dispositivo, tal cual.
    public let name: String
    /// La ranura de jugador a la que está asignado, con el vocabulario del emulador.
    public let slot: String

    public init(kind: Kind, name: String, slot: String) {
        self.kind = kind
        self.name = name
        self.slot = slot
    }

    public var id: String { "\(slot)-\(name)" }
}

/// Lo que se ha podido averiguar de la entrada de un emulador.
public struct EmulatorInput: Equatable, Sendable {
    public let devices: [EmulatorInputDevice]

    public init(devices: [EmulatorInputDevice] = []) {
        self.devices = devices
    }

    public var hasGamepad: Bool { devices.contains { $0.kind == .gamepad } }
    public var hasKeyboard: Bool { devices.contains { $0.kind == .keyboard } }
    /// Sin ningún dispositivo el juego arranca y no responde a nada, que es el peor de los fallos:
    /// no da ningún error y parece que el juego está roto.
    public var isEmpty: Bool { devices.isEmpty }
}

/// Lee la configuración de entrada de un emulador de programa aparte.
public enum EmulatorInputReader {
    /// Qué tiene configurado el emulador, o `nil` si de este no se sabe leer.
    ///
    /// `nil` no es «no tiene nada»: es «no lo sé». La distinción es la de siempre en este proyecto
    /// —un hecho o el silencio, nunca una suposición— y aquí es literal, porque cada familia de
    /// emuladores guarda lo suyo en un formato distinto y solo se entiende el de esta.
    public static func read(
        emulator: StandaloneEmulator, fileManager: FileManager = .default
    ) -> EmulatorInput? {
        let archivo = emulator.dataURL(fileManager: fileManager)
            .appendingPathComponent("Config.json")
        guard let datos = try? Data(contentsOf: archivo) else { return nil }
        return parse(datos)
    }

    /// Interpreta el `Config.json` de la familia Ryujinx. Separado de la lectura para poder
    /// probarlo con un archivo fabricado, sin depender de que haya un emulador instalado.
    ///
    /// El formato es una lista de perfiles y **cada ranura de jugador admite uno solo**: si hay dos
    /// apuntando al mismo jugador, el emulador se queda con uno y el otro no responde. Por eso se
    /// enseña la ranura de cada uno y no solo la lista de aparatos.
    public static func parse(_ data: Data) -> EmulatorInput? {
        guard let raíz = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perfiles = raíz["input_config"] as? [[String: Any]]
        else { return nil }

        let aparatos: [EmulatorInputDevice] = perfiles.compactMap { perfil in
            guard let motor = perfil["backend"] as? String else { return nil }
            let clase: EmulatorInputDevice.Kind
            switch motor {
            case "WindowKeyboard": clase = .keyboard
            // Todo lo que no es el teclado de la ventana entra por SDL, que es como esta familia
            // habla con cualquier mando. Se acepta por descarte para que un motor nuevo no
            // desaparezca de la lista sin avisar.
            default: clase = .gamepad
            }
            let nombre = (perfil["name"] as? String) ?? motor
            let ranura = (perfil["player_index"] as? String) ?? "?"
            return EmulatorInputDevice(kind: clase, name: nombre, slot: ranura)
        }
        return EmulatorInput(devices: aparatos)
    }
}
