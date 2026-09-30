import Foundation

/// Una imagen de la pantalla del emulador, tal como llega.
public struct EmulatorFrame: Sendable {
    public let width: Int
    public let height: Int
    /// Cuartos de vuelta antihorarios de la piel del emulador (`SkinRotation`): 0 vertical,
    /// 1 apaisado, 2 vertical del revés, 3 apaisado del revés. La imagen llega ya girada así, que
    /// **no** es lo mismo que como la tenga girada Android.
    public let rotation: Int
    /// RGBA8888, fila a fila desde arriba: `width * height * 4` bytes.
    public let pixels: Data
    public let sequence: Int

    /// Con la pantalla apagada el emulador manda imágenes de 0×0.
    public var isEmpty: Bool { width == 0 || height == 0 }
}

/// Los mensajes del canal del emulador que hacen falta para la pantalla completa. Los números de
/// campo son los de `emulator_controller.proto`, que viaja con el emulador en `emulator/lib`.
public enum EmulatorMessages {
    public enum Method {
        private static let service = "/android.emulation.control.EmulatorController/"
        public static let getStatus = service + "getStatus"
        public static let streamScreenshot = service + "streamScreenshot"
        public static let streamInputEvent = service + "streamInputEvent"
        public static let sendMouse = service + "sendMouse"
        public static let sendKey = service + "sendKey"
    }

    /// `ImageFormat` con RGBA8888 (1). Ancho, alto y pantalla se dejan en cero —tamaño nativo y
    /// pantalla principal—, y en proto3 un campo en cero ni se escribe.
    public static func screenFormat() -> Data {
        ProtoWire.field(1, int: 1)
    }

    /// `MouseEvent`: coordenadas naturales del panel y el botón izquierdo pulsado o suelto. El
    /// emulador lo convierte en un dedo, igual que un clic en su propia ventana.
    public static func mouse(x: Int, y: Int, pressed: Bool) -> Data {
        ProtoWire.field(1, int: x) + ProtoWire.field(2, int: y) + ProtoWire.field(3, int: pressed ? 1 : 0)
    }

    /// `KeyboardEvent` con el código de tecla del Mac (`codeType` = Mac, 4). El emulador lo
    /// traduce solo a la tecla de Linux que le toca, así que Lever no necesita tabla propia.
    public static func key(macKeyCode: UInt16, down: Bool) -> Data {
        ProtoWire.field(1, int: 4) + ProtoWire.field(2, int: down ? 0 : 1) + ProtoWire.field(3, int: Int(macKeyCode))
    }

    /// `InputEvent`: el mismo mensaje dentro del hueco que le toca (tecla 1, ratón 3).
    public static func inputEvent(key: Data) -> Data { ProtoWire.field(1, bytes: key) }
    public static func inputEvent(mouse: Data) -> Data { ProtoWire.field(3, bytes: mouse) }

    /// Lee una `Image`. `nil` si el mensaje está roto o si los píxeles no cuadran con el tamaño.
    public static func frame(fromImage data: Data) -> EmulatorFrame? {
        guard let image = ProtoMessage(data) else { return nil }
        let format = image.message(1)
        let width = Int(format?.varint(3) ?? image.varint(2) ?? 0)
        let height = Int(format?.varint(4) ?? image.varint(3) ?? 0)
        let rotation = Int((format?.message(2)?.varint(1) ?? 0) & 3)
        let pixels = image.bytes(4) ?? Data()
        if width > 0, height > 0, pixels.count != width * height * 4 { return nil }
        return EmulatorFrame(
            width: width, height: height, rotation: rotation,
            pixels: pixels, sequence: Int(image.varint(5) ?? 0)
        )
    }

    /// Lo que interesa de `EmulatorStatus`: la versión y si ha terminado de arrancar.
    public static func status(from data: Data) -> (version: String, booted: Bool)? {
        guard let status = ProtoMessage(data) else { return nil }
        return (status.string(1) ?? "", status.varint(3) == 1)
    }
}
