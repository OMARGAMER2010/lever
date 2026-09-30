import CoreGraphics
import Foundation

/// Las ventanas de un emulador que se ven en pantalla.
public struct EmulatorWindows: Equatable, Sendable {
    public let pid: Int32
    /// La ventana con la pantalla del aparato.
    public let main: CGRect
    /// El menú lateral: la tira de botones pegada a su derecha.
    public let toolbar: CGRect
    public let toolbarNumber: Int
}

/// Encuentra las ventanas del emulador en el listado del sistema y decide dónde va el botón.
///
/// Todo en coordenadas de Quartz —origen arriba a la izquierda de la pantalla principal—, que son
/// las de `CGWindowListCopyWindowInfo`. Los marcos se leen sin ningún permiso; los títulos pedirían
/// el de grabación de pantalla, y por eso no se usan.
public enum EmulatorWindowLayout {
    public struct WindowInfo: Equatable, Sendable {
        public let number: Int
        public let ownerPID: Int32
        public let ownerName: String
        public let layer: Int
        public let bounds: CGRect

        public init(number: Int, ownerPID: Int32, ownerName: String, layer: Int, bounds: CGRect) {
            self.number = number
            self.ownerPID = ownerPID
            self.ownerName = ownerName
            self.layer = layer
            self.bounds = bounds
        }

        /// Desde una entrada de `CGWindowListCopyWindowInfo`.
        public init?(_ info: [String: Any]) {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            self.init(
                number: number,
                ownerPID: Int32(pid),
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds
            )
        }
    }

    /// Por cada proceso del emulador: su menú lateral —estrecho y alto— y la ventana principal que
    /// tiene pegada a la izquierda. Sin las dos no hay emulador que acompañar.
    public static func emulators(in windows: [WindowInfo]) -> [EmulatorWindows] {
        let candidates = windows.filter { $0.ownerName.hasPrefix("qemu-system") && $0.layer == 0 }
        var result: [EmulatorWindows] = []
        for pid in Set(candidates.map(\.ownerPID)).sorted() {
            let own = candidates.filter { $0.ownerPID == pid }
            guard let toolbar = own.first(where: isToolbar) else { continue }
            let attached = own.filter { window in
                window.number != toolbar.number
                    && window.bounds.width >= 100 && window.bounds.height >= 100
                    && abs(window.bounds.maxX - toolbar.bounds.minX) <= 16
                    && window.bounds.minY < toolbar.bounds.maxY && window.bounds.maxY > toolbar.bounds.minY
            }
            guard let main = attached.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
                continue
            }
            result.append(EmulatorWindows(pid: pid, main: main.bounds, toolbar: toolbar.bounds, toolbarNumber: toolbar.number))
        }
        return result
    }

    private static func isToolbar(_ window: WindowInfo) -> Bool {
        window.bounds.width >= 30 && window.bounds.width <= 100 && window.bounds.height >= window.bounds.width * 3
    }

    /// Dónde va el botón: debajo del menú lateral, con su mismo ancho. Si abajo no cabe dentro de la
    /// pantalla, encima.
    public static func buttonFrame(for toolbar: CGRect, within screen: CGRect, height: CGFloat = 44, gap: CGFloat = 6) -> CGRect {
        let below = CGRect(x: toolbar.minX, y: toolbar.maxY + gap, width: toolbar.width, height: height)
        if below.maxY <= screen.maxY { return below }
        return CGRect(x: toolbar.minX, y: toolbar.minY - gap - height, width: toolbar.width, height: height)
    }
}
