import Combine
import Foundation
import IOKit.hid

/// Un mando conectado al Mac, tal como lo ve el sistema.
public struct ConnectedGamepad: Identifiable, Equatable, Sendable {
    public let id: String
    /// Lo que el mando dice llamarse.
    public let name: String
    /// De qué familia es. No es un adorno: decide con qué nombres se enseñan sus botones.
    public let family: Family
    /// Por cable o por Bluetooth.
    public let wireless: Bool

    public enum Family: String, Equatable, Sendable {
        case dualSense
        case dualShock
        case xbox
        /// Cualquier otro que hable el protocolo estándar. Funciona igual; solo cambian los
        /// nombres serigrafiados en los botones.
        case generic

        /// Cómo llama este mando a los cuatro botones de la derecha, que es donde cada fabricante
        /// pone un nombre distinto para lo mismo.
        public var faceLabels: (a: String, b: String, x: String, y: String) {
            switch self {
            case .dualSense, .dualShock: return ("○", "✕", "△", "□")
            case .xbox: return ("B", "A", "Y", "X")
            case .generic: return ("A", "B", "X", "Y")
            }
        }

        /// Por quién lo fabrica y qué modelo es. Es lo único que dice IOKit, y es suficiente:
        /// preguntarle al mando cómo se llama a sí mismo daría cadenas distintas por cada revisión.
        public static func of(vendor: Int, product: Int) -> Family {
            switch (vendor, product) {
            case (0x054C, 0x0CE6), (0x054C, 0x0DF2): return .dualSense
            case (0x054C, 0x05C4), (0x054C, 0x09CC), (0x054C, 0x0BA0), (0x054C, 0x0268):
                return .dualShock
            case (0x045E, _): return .xbox
            default: return .generic
            }
        }
    }

    public init(id: String, name: String, family: Family, wireless: Bool) {
        self.id = id
        self.name = name
        self.family = family
        self.wireless = wireless
    }
}

/// Vigila qué mandos hay conectados y, cuando se le pide, escucha cuál es el siguiente botón que
/// se pulsa y **con qué número lo va a ver RetroArch**.
///
/// **Por qué IOKit y no `GameController`.** `GameController` es el marco cómodo: da el mando ya
/// normalizado, con nombres para los botones y sin pedir permisos. Pero aquí sobra la comodidad y
/// falta lo otro: el número que hay que escribir en la configuración sale de la lista de elementos
/// HID en crudo (ver `RetroPadNumbering`), y `GameController` no la enseña. Y hay una razón más
/// terca: en este Mac, con un DualSense emparejado por Bluetooth, `GameController` devuelve **cero
/// mandos** —desde un ejecutable suelto y desde una app con su ventana delante— mientras IOKit lo
/// ve sin dudar. Enseñar una lista de mandos que no es la que verá el emulador sería mentir.
///
/// Lo que se pierde por el camino: el porcentaje de batería. Lo daba `GameController` y IOKit no
/// lo publica para este mando. Antes que sacarlo de un segundo sitio y arriesgarse a que las dos
/// listas no coincidan, no se enseña.
@MainActor
public final class GamepadWatcher: ObservableObject {
    /// Los que hay ahora mismo.
    @Published public private(set) var gamepads: [ConnectedGamepad] = []
    @Published public private(set) var isListening = false

    /// Cuánto se tiene que mover un eje para contar como pulsado, sobre 32767. RetroArch da por
    /// pulsado medio recorrido; se pide lo mismo aquí para no guardar un eje que él no vería.
    private static let axisThreshold = 16384

    private var manager: IOHIDManager?
    private var pads: [UInt32: Pad] = [:]
    private var handler: ((ControlBinding) -> Void)?
    /// Los ejes tal como estaban al empezar a escuchar. Sin esto, **un gatillo suelto parece un
    /// eje pulsado**: en reposo no vale cero, vale el extremo, y cualquier umbral lo daría por
    /// movido antes de que el usuario tocara nada.
    private var axisBaseline: [UInt32: [UInt32: Int]] = [:]
    /// Los botones que ya estaban hundidos al empezar. Quien viene de pulsar algo no quiere
    /// asignarlo: se ignoran hasta que se sueltan.
    private var heldButtons: [UInt32: Set<UInt32>] = [:]

    /// Todo lo que hace falta saber de un mando para traducir lo que llega de él.
    private struct Pad {
        let device: IOHIDDevice
        let gamepad: ConnectedGamepad
        let layout: RetroPadNumbering.Layout
        let elements: [UInt32: IOHIDElement]
        let bounds: [UInt32: Bounds]
    }

    private struct Bounds {
        var logicalMin: Int
        var logicalMax: Int
        var physicalMin: Int
        var physicalMax: Int
    }

    public init() {}

    // MARK: - Mirar

    /// Empieza a mirar. Los mandos que se enchufen o se emparejen después entran solos: IOKit
    /// avisa, y sin eso habría que decirle al usuario que cierre y vuelva a abrir la hoja.
    public func start() {
        guard manager == nil else { return }

        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Los mismos aparatos que busca RetroArch. Pedir menos dejaría fuera mandos que él sí
        // usaría; pedir más metería teclados y ratones en la lista.
        let criterios: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: Int(RetroPadNumbering.pageGenericDesktop), kIOHIDDeviceUsageKey: 0x04],
            [kIOHIDDeviceUsagePageKey: Int(RetroPadNumbering.pageGenericDesktop), kIOHIDDeviceUsageKey: 0x05],
            [kIOHIDDeviceUsagePageKey: 0x05, kIOHIDDeviceUsageKey: 0x00]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(hid, criterios as CFArray)

        let contexto = Unmanaged.passUnretained(self).toOpaque()
        let recuento: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<GamepadWatcher>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in watcher.refresh() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(hid, recuento, contexto)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, recuento, contexto)
        IOHIDManagerRegisterInputValueCallback(hid, Self.valueCallback, contexto)

        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Sin `seize`: abrir en exclusiva le quitaría el mando a RetroArch, que es justo quien
        // tiene que quedárselo cuando arranque el juego.
        guard IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }

        manager = hid
        refresh()
    }

    public func stop() {
        stopListening()
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        pads = [:]
        gamepads = []
    }

    public func refresh() {
        guard let manager else { return }
        let aparatos = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []

        var leídos: [UInt32: Pad] = [:]
        for aparato in aparatos {
            guard let pad = Self.read(aparato) else { continue }
            leídos[Self.locationID(of: aparato)] = pad
        }
        pads = leídos
        // Por nombre, para que la lista no baile de orden entre lecturas: el conjunto que devuelve
        // IOKit no tiene ninguno.
        gamepads = leídos.values.map(\.gamepad).sorted { $0.name < $1.name }
    }

    // MARK: - Escuchar una asignación

    /// Escucha hasta que se pulse algo, y devuelve la asignación tal como habrá que escribirla.
    ///
    /// Es lo que hace funcionar el diagrama: se pulsa el botón dibujado y luego el de verdad.
    public func listen(_ handler: @escaping (ControlBinding) -> Void) {
        self.handler = handler
        axisBaseline = [:]
        heldButtons = [:]

        for (location, pad) in pads {
            var ejes: [UInt32: Int] = [:]
            var hundidos: Set<UInt32> = []
            for (cookie, elemento) in pad.elements {
                guard let valor = Self.currentValue(of: elemento, in: pad.device) else { continue }
                if pad.layout.axes[cookie] != nil, let límites = pad.bounds[cookie] {
                    ejes[cookie] = RetroPadNumbering.axisValue(
                        valor, physicalMin: límites.physicalMin, physicalMax: límites.physicalMax
                    )
                } else if pad.layout.buttons[cookie] != nil, valor != 0 {
                    hundidos.insert(cookie)
                }
            }
            axisBaseline[location] = ejes
            heldButtons[location] = hundidos
        }

        isListening = true
    }

    public func stopListening() {
        isListening = false
        handler = nil
        axisBaseline = [:]
        heldButtons = [:]
    }

    // MARK: - Lo que llega del mando

    private static let valueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let watcher = Unmanaged<GamepadWatcher>.fromOpaque(context).takeUnretainedValue()
        // Del evento solo cruza lo que se puede enviar entre hilos: el `IOHIDValue` se queda aquí.
        let elemento = IOHIDValueGetElement(value)
        let cookie = UInt32(IOHIDElementGetCookie(elemento))
        let entero = IOHIDValueGetIntegerValue(value)
        let location = locationID(of: IOHIDElementGetDevice(elemento))
        Task { @MainActor in watcher.handle(location: location, cookie: cookie, value: entero) }
    }

    private func handle(location: UInt32, cookie: UInt32, value: Int) {
        guard isListening, let pad = pads[location] else { return }

        if let número = pad.layout.buttons[cookie] {
            // Soltar un botón que ya venía hundido solo sirve para volver a admitirlo.
            if heldButtons[location]?.contains(cookie) == true {
                if value == 0 { heldButtons[location]?.remove(cookie) }
                return
            }
            guard value != 0, RetroPadNumbering.isUsable(button: número) else { return }
            emit(.button(número))
            return
        }

        if let eje = pad.layout.axes[cookie], let límites = pad.bounds[cookie] {
            let actual = RetroPadNumbering.axisValue(
                value, physicalMin: límites.physicalMin, physicalMax: límites.physicalMax
            )
            let partida = axisBaseline[location]?[cookie] ?? 0
            // Las dos condiciones hacen falta: la primera descarta un gatillo que nadie ha tocado,
            // la segunda descarta un medio recorrido que RetroArch tampoco daría por pulsado.
            guard abs(actual - partida) > Self.axisThreshold,
                  abs(actual) > Self.axisThreshold else { return }
            emit(.axis("\(actual < 0 ? "-" : "+")\(eje)"))
            return
        }

        if pad.layout.hat == cookie, let límites = pad.bounds[cookie] {
            guard let dirección = RetroPadNumbering.hatDirection(
                value: value, logicalMin: límites.logicalMin, logicalMax: límites.logicalMax
            ) else { return }
            emit(.hat(0, dirección))
        }
    }

    private func emit(_ binding: ControlBinding) {
        let handler = self.handler
        stopListening()
        handler?(binding)
    }

    // MARK: - Leer un aparato

    private static func read(_ device: IOHIDDevice) -> Pad? {
        guard let crudos = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] else { return nil }

        var info: [HIDElementInfo] = []
        var elements: [UInt32: IOHIDElement] = [:]
        var bounds: [UInt32: Bounds] = [:]

        for elemento in crudos {
            let cookie = UInt32(IOHIDElementGetCookie(elemento))
            info.append(HIDElementInfo(
                page: UInt32(IOHIDElementGetUsagePage(elemento)),
                usage: UInt32(IOHIDElementGetUsage(elemento)),
                cookie: cookie,
                kind: HIDElementInfo.Kind(iokitType: UInt32(IOHIDElementGetType(elemento).rawValue))
            ))
            elements[cookie] = elemento
            bounds[cookie] = Bounds(
                logicalMin: IOHIDElementGetLogicalMin(elemento),
                logicalMax: IOHIDElementGetLogicalMax(elemento),
                physicalMin: IOHIDElementGetPhysicalMin(elemento),
                physicalMax: IOHIDElementGetPhysicalMax(elemento)
            )
        }

        func propiedad(_ clave: String) -> Any? { IOHIDDeviceGetProperty(device, clave as CFString) }
        let vendor = (propiedad(kIOHIDVendorIDKey) as? Int) ?? 0
        let product = (propiedad(kIOHIDProductIDKey) as? Int) ?? 0
        let nombre = (propiedad(kIOHIDProductKey) as? String) ?? "?"
        let transporte = (propiedad(kIOHIDTransportKey) as? String) ?? ""

        let gamepad = ConnectedGamepad(
            id: "\(vendor)-\(product)-\(locationID(of: device))",
            name: nombre,
            family: .of(vendor: vendor, product: product),
            wireless: transporte.caseInsensitiveCompare("Bluetooth") == .orderedSame
        )
        return Pad(
            device: device,
            gamepad: gamepad,
            layout: RetroPadNumbering.layout(of: info),
            elements: elements,
            bounds: bounds
        )
    }

    /// El número con el que el sistema distingue dos mandos iguales. El nombre no vale: dos
    /// DualSense se llaman igual.
    private nonisolated static func locationID(of device: IOHIDDevice) -> UInt32 {
        UInt32(truncatingIfNeeded: (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0)
    }

    /// Lo que marca un elemento **ahora mismo**, sin esperar a que cambie. Es lo que permite
    /// tomarles la foto de partida a los ejes y a los botones antes de escuchar nada.
    private static func currentValue(of element: IOHIDElement, in device: IOHIDDevice) -> Int? {
        var valor: Unmanaged<IOHIDValue>?
        // `IOHIDDeviceGetValue` pide un puntero a un `Unmanaged` sin envolver, y uno no se puede
        // construir vacío. Un `Unmanaged?` ocupa lo mismo —es un puntero— así que se le presta.
        let estado = withUnsafeMutablePointer(to: &valor) { hueco in
            hueco.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) {
                IOHIDDeviceGetValue(device, element, $0)
            }
        }
        guard estado == kIOReturnSuccess, let leído = valor?.takeUnretainedValue() else { return nil }
        return IOHIDValueGetIntegerValue(leído)
    }
}
