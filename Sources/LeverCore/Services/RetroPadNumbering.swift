import Foundation

/// Un elemento de un mando tal como lo describe IOKit: su página, su uso y su galleta.
///
/// Se copia a una estructura propia en vez de pasear el `IOHIDElement` por todas partes para que
/// la numeración se pueda probar sin tener un mando enchufado. La numeración es la parte que se
/// puede equivocar; leer IOKit no.
public struct HIDElementInfo: Equatable, Sendable {
    /// Los tipos que da IOKit, con su número. Solo se distinguen los que cambian la decisión.
    public enum Kind: Sendable, Equatable {
        case misc
        case button
        case axis
        case other

        public init(iokitType: UInt32) {
            switch iokitType {
            case 1: self = .misc
            case 2: self = .button
            case 3: self = .axis
            default: self = .other
            }
        }
    }

    public var page: UInt32
    public var usage: UInt32
    public var cookie: UInt32
    public var kind: Kind

    public init(page: UInt32, usage: UInt32, cookie: UInt32, kind: Kind) {
        self.page = page
        self.usage = usage
        self.cookie = cookie
        self.kind = kind
    }
}

/// Traduce un botón físico al número que RetroArch escribe en `input_playerN_<control>_btn`.
///
/// **Por qué hace falta esto y por qué no vale `GameController`.** El número no es una propiedad
/// del botón: es la posición que ese botón ocupa en la lista que arma el emulador al reconocer el
/// mando. Así que no se puede deducir del nombre que le dé el sistema, ni preguntárselo a nadie:
/// hay que armar la misma lista, con la misma regla. Lo que hay aquí es esa regla, traducida de
/// `input/drivers_hid/iohidmanager_hid.c` de RetroArch 1.22.2.
///
/// **Y hay que hacerlo por IOKit, no por `GameController`.** RetroArch en un Mac usa el driver de
/// mandos `hid` sobre `iohidmanager` —lo dice su propio registro— y ese lee los elementos HID en
/// crudo. `GameController` enseña un mando ya normalizado, sin galletas ni usos, así que no hay
/// forma de saber desde ahí en qué posición va a caer un botón. Además, en este Mac `GameController`
/// **no ve** el DualSense emparejado por Bluetooth: ni desde un ejecutable suelto ni desde una app
/// con su ventana delante. IOKit sí, que es justo lo que ve RetroArch.
///
/// La versión de RetroArch importa: si algún día cambia la regla, cambia la numeración y esto hay
/// que volver a mirarlo. Las pruebas llevan la tabla del Nimbus que la propia fuente documenta y la
/// del DualSense leída de un mando de verdad.
public enum RetroPadNumbering {
    // Las páginas del estándar HID que RetroArch mira.
    static let pageGenericDesktop: UInt32 = 0x01
    static let pageSimulation: UInt32 = 0x02
    static let pageButton: UInt32 = 0x09
    static let pageConsumer: UInt32 = 0x0C
    static let usageHatSwitch: UInt32 = 0x39

    /// El orden **es** el número del eje: la X es el eje 0, la Y el 1, y así. No es alfabético ni
    /// el del estándar HID; es la lista que RetroArch lleva escrita, y copiarla en otro orden
    /// cambia todos los ejes de sitio sin que nada avise.
    static let axisUsages: [UInt32] = [
        0x30, 0x31,  // X, Y            — la palanca izquierda
        0x33, 0x34,  // Rx, Ry          — la derecha
        0x32, 0x35,  // Z, Rz           — los gatillos
        0xBA, 0xBB,  // timón, gas      — de la página de simulación
        0xC8, 0xC4, 0xC5  // dirección, acelerador, freno
    ]

    /// **RetroArch solo lee los treinta y dos primeros botones** (`joykey < 32` en
    /// `iohidmanager_hid_joypad_button`). Un botón más allá se guarda sin error y no hace nada.
    public static let maxButton = 32

    /// Lo que sale de leer un mando: en qué número cae cada elemento.
    public struct Layout: Equatable, Sendable {
        /// Galleta → el número que va en `_btn`.
        public var buttons: [UInt32: Int]
        /// Galleta → el número que va en `_axis`.
        public var axes: [UInt32: Int]
        /// La cruceta. RetroArch se queda con **una** y la llama `h0`; si el mando declara varias,
        /// la suya es la última que encuentra.
        public var hat: UInt32?

        public init(buttons: [UInt32: Int] = [:], axes: [UInt32: Int] = [:], hat: UInt32? = nil) {
            self.buttons = buttons
            self.axes = axes
            self.hat = hat
        }
    }

    /// Arma la lista igual que la arma el emulador y devuelve en qué número cae cada elemento.
    ///
    /// Los tres pasos que deciden el resultado, y ninguno es evidente:
    /// 1. Los elementos se ordenan por página, uso y galleta **antes** de mirarlos.
    /// 2. Cada botón entra en la lista ordenado por su uso, no por el orden en que aparece.
    /// 3. Un uso repetido no pisa al primero: se aparta y se pega **al final**, detrás de todos.
    public static func layout(of elements: [HIDElementInfo]) -> Layout {
        let ordenados = elements.sorted { a, b in
            if a.page != b.page { return a.page < b.page }
            if a.usage != b.usage { return a.usage < b.usage }
            return a.cookie < b.cookie
        }

        var botones: [HIDElementInfo] = []
        var botonesRepetidos: [HIDElementInfo] = []
        var ejes: [(id: Int, cookie: UInt32)] = []
        var ejesRepetidos: [UInt32] = []
        var cruceta: UInt32?

        // Inserta ordenado por uso, detrás de los que tengan el mismo. Es lo que hace que la
        // numeración no dependa del orden en que IOKit devuelva los elementos.
        func insertar(_ elemento: HIDElementInfo, en lista: inout [HIDElementInfo]) {
            var índice = 0
            while índice < lista.count, lista[índice].usage <= elemento.usage { índice += 1 }
            lista.insert(elemento, at: índice)
        }

        func anotarEje(_ id: Int, _ cookie: UInt32) {
            if ejes.contains(where: { $0.id == id }) { ejesRepetidos.append(cookie) }
            else { ejes.append((id, cookie)) }
        }

        for elemento in ordenados {
            var esBotón = false

            switch elemento.page {
            case pageGenericDesktop where elemento.kind == .misc:
                if elemento.usage == usageHatSwitch {
                    cruceta = elemento.cookie
                } else if let eje = axisUsages.firstIndex(of: elemento.usage) {
                    anotarEje(eje, elemento.cookie)
                } else {
                    // Un mando puede poner botones en esta página. Lo que no es eje ni cruceta,
                    // botón es.
                    esBotón = true
                }

            case pageButton, pageConsumer:
                esBotón = elemento.kind == .misc || elemento.kind == .button

            case pageSimulation:
                // Aquí RetroArch **no** mira el tipo. Se copia igual: la fidelidad es el objetivo.
                if let eje = axisUsages.firstIndex(of: elemento.usage) {
                    anotarEje(eje, elemento.cookie)
                } else {
                    esBotón = true
                }

            default:
                break
            }

            guard esBotón else { continue }
            if botones.contains(where: { $0.usage == elemento.usage }) {
                insertar(elemento, en: &botonesRepetidos)
            } else {
                insertar(elemento, en: &botones)
            }
        }

        // Los ejes repetidos rellenan los números que hayan quedado libres, de menor a mayor.
        var pendientes = ejesRepetidos
        for id in 0..<axisUsages.count where !pendientes.isEmpty {
            guard !ejes.contains(where: { $0.id == id }) else { continue }
            ejes.append((id, pendientes.removeFirst()))
        }

        var layout = Layout(hat: cruceta)
        for (posición, botón) in (botones + botonesRepetidos).enumerated() {
            layout.buttons[botón.cookie] = posición
        }
        for eje in ejes { layout.axes[eje.cookie] = eje.id }
        return layout
    }

    // MARK: - Lo que vale la pena guardar

    /// Si RetroArch va a poder leer ese número. Guardar uno que no lee es guardar un botón que no
    /// hace nada, y sin ningún aviso: mejor no guardarlo.
    public static func isUsable(button number: Int) -> Bool {
        number >= 0 && number < maxButton
    }

    // MARK: - La cruceta

    /// A dónde apunta la cruceta, con la cuenta que hace RetroArch.
    ///
    /// Los dos ajustes de delante no son adorno: un mando que declara cuatro posiciones en vez de
    /// ocho las cuenta de dos en dos, y otro que empieza a contar en uno va corrido. Sin ellos, la
    /// cruceta apunta a otro lado en la mitad de los mandos.
    public static func hatPosition(value: Int, logicalMin: Int, logicalMax: Int) -> (x: Int, y: Int) {
        var valor = value
        if logicalMax - logicalMin == 3 { valor *= 2 }
        if logicalMin == 1 { valor -= 1 }

        switch valor {
        case 0: return (0, -1)   // arriba
        case 1: return (1, -1)
        case 2: return (1, 0)    // derecha
        case 3: return (1, 1)
        case 4: return (0, 1)    // abajo
        case 5: return (-1, 1)
        case 6: return (-1, 0)   // izquierda
        case 7: return (-1, -1)
        default: return (0, 0)   // en el centro
        }
    }

    /// El nombre que RetroArch escribe (`h0up`) para una posición de la cruceta.
    ///
    /// Solo las cuatro rectas. En diagonal hay dos direcciones a la vez y no se sabe cuál quería
    /// el usuario: se ignora y se sigue escuchando, que es mejor que acertar a medias.
    public static func hatDirection(value: Int, logicalMin: Int, logicalMax: Int) -> String? {
        let posición = hatPosition(value: value, logicalMin: logicalMin, logicalMax: logicalMax)
        switch posición {
        case (0, -1): return "up"
        case (0, 1): return "down"
        case (-1, 0): return "left"
        case (1, 0): return "right"
        default: return nil
        }
    }

    // MARK: - Los ejes

    /// El valor que RetroArch calcula para un eje: de −32767 a 32767 a partir de sus límites.
    ///
    /// Hace falta para saber **hacia dónde** se ha movido, que es lo que decide el signo del
    /// `+0`/`-0` que se guarda. Y explica una trampa: un gatillo en reposo no vale cero, vale
    /// −32767, así que mirar solo el valor haría que un gatillo suelto pareciera un eje pulsado.
    public static func axisValue(_ raw: Int, physicalMin: Int, physicalMax: Int) -> Int {
        let recorrido = physicalMax - physicalMin
        guard recorrido != 0 else { return 0 }
        let proporción = Double(raw - physicalMin) / Double(recorrido)
        return Int((proporción * 2.0 - 1.0) * 32767.0)
    }
}
