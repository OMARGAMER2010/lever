import Combine
import Foundation
import GameController

/// Un mando conectado al Mac, tal como lo ve el sistema.
public struct ConnectedGamepad: Identifiable, Equatable, Sendable {
    public let id: String
    /// Lo que el mando dice llamarse.
    public let name: String
    /// De qué familia es. No es un adorno: decide qué botones enseñar y con qué nombres.
    public let family: Family
    /// Por cable o por Bluetooth.
    public let wireless: Bool
    public let batteryPercent: Int?

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
    }

    public init(id: String, name: String, family: Family, wireless: Bool, batteryPercent: Int? = nil) {
        self.id = id
        self.name = name
        self.family = family
        self.wireless = wireless
        self.batteryPercent = batteryPercent
    }
}

/// Vigila qué mandos hay conectados y, cuando se le pide, escucha cuál es el siguiente botón que
/// se pulsa.
///
/// **Por qué no hay nada de XInput ni de DirectInput aquí**: son dos APIs de Windows. En macOS los
/// mismos mandos —los de Xbox, los de PlayStation y los genéricos de Bluetooth— llegan por
/// `GameController`, que es el marco del sistema y los reconoce sin instalar ningún controlador,
/// por cable o emparejados. Pedirle a un Mac que hable XInput sería pedirle que fuera Windows.
@MainActor
public final class GamepadWatcher: ObservableObject {
    /// Los que hay ahora mismo.
    @Published public private(set) var gamepads: [ConnectedGamepad] = []
    /// El último botón pulsado mientras se estaba escuchando, con el nombre que le da el sistema.
    @Published public private(set) var lastPressed: String?
    @Published public private(set) var isListening = false

    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Empieza a mirar. Incluye la búsqueda de mandos inalámbricos, que es lo que hace que uno
    /// emparejado por Bluetooth aparezca sin tener que ir a los ajustes del sistema.
    public func start() {
        refresh()
        let centro = NotificationCenter.default
        for nombre in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(centro.addObserver(forName: nombre, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    public func stop() {
        GCController.stopWirelessControllerDiscovery()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        stopListening()
    }

    public func refresh() {
        gamepads = GCController.controllers().map { mando in
            ConnectedGamepad(
                id: mando.productCategory + (mando.vendorName ?? "") + String(UInt(bitPattern: ObjectIdentifier(mando).hashValue)),
                name: mando.vendorName ?? mando.productCategory,
                family: Self.family(of: mando),
                wireless: mando.battery != nil,
                batteryPercent: mando.battery.map { Int($0.batteryLevel * 100) }
            )
        }
    }

    /// De qué familia es, por lo que el sistema dice de él. `GCDualSenseGamepad` y compañía son
    /// las clases concretas que Apple expone cuando reconoce el mando.
    static func family(of controller: GCController) -> ConnectedGamepad.Family {
        if controller.physicalInputProfile is GCDualSenseGamepad { return .dualSense }
        if controller.physicalInputProfile is GCDualShockGamepad { return .dualShock }
        if controller.physicalInputProfile is GCXboxGamepad { return .xbox }
        return .generic
    }

    // MARK: - Escuchar una asignación

    /// Escucha hasta que se pulse un botón, y devuelve cuál.
    ///
    /// Es lo que hace funcionar el diagrama: se pulsa el botón dibujado y luego el de verdad. Se
    /// escucha **el que se suelta**, no el que se pulsa, porque al entrar en este modo el usuario
    /// suele venir de dejar un botón apretado y si no se filtraría ese mismo.
    public func listen(_ handler: @escaping (String) -> Void) {
        isListening = true
        lastPressed = nil
        for mando in GCController.controllers() {
            mando.extendedGamepad?.valueChangedHandler = { [weak self] _, elemento in
                guard let self, isListening else { return }
                guard let botón = elemento as? GCControllerButtonInput, !botón.isPressed else { return }
                let nombre = elemento.localizedName ?? elemento.unmappedLocalizedName ?? "?"
                Task { @MainActor in
                    self.lastPressed = nombre
                    self.stopListening()
                    handler(nombre)
                }
            }
        }
    }

    public func stopListening() {
        isListening = false
        for mando in GCController.controllers() { mando.extendedGamepad?.valueChangedHandler = nil }
    }
}
