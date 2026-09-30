import Foundation

/// Lo que Android dice de su pantalla: cuánto la ha girado, qué barras del sistema están a la
/// vista y qué marco ocupa la app que tiene delante. Todo en coordenadas de Android.
public struct AndroidScreenState: Equatable, Sendable {
    /// Cuartos de vuelta de `Surface.ROTATION_*`. `nil` si no se pudo leer.
    public var rotation: Int?
    /// Las barras de navegación y de estado que se ven ahora mismo.
    public var visibleBars: [PixelRect]
    /// El marco de la ventana principal de la app que está delante: la mayor de las suyas, para no
    /// confundirla con un diálogo que tenga abierto.
    public var appFrame: PixelRect?

    public init(rotation: Int? = nil, visibleBars: [PixelRect] = [], appFrame: PixelRect? = nil) {
        self.rotation = rotation
        self.visibleBars = visibleBars
        self.appFrame = appFrame
    }

    /// Lee la salida de `AndroidLauncher.screenStateCommand`. Lo que no entiende lo deja vacío:
    /// una lectura a medias es mejor que un dato inventado.
    public static func parse(_ output: String) -> AndroidScreenState {
        var state = AndroidScreenState()
        var focusedPackage: String?
        var currentWindow: String?
        var windows: [(name: String, frame: PixelRect)] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.contains("InsetsSource") {
                if let bar = visibleBar(in: line), !state.visibleBars.contains(bar) {
                    state.visibleBars.append(bar)
                }
            } else if let degrees = captures(#"mCurrentRotation=ROTATION_(\d+)"#, in: line)?.first.flatMap({ Int($0) }) {
                if state.rotation == nil { state.rotation = ScreenGeometry.normalized(degrees / 90) }
            } else if let package = captures(#"mFocusedApp=ActivityRecord\{\S+ u\d+ ([^/\s]+)/"#, in: line)?.first {
                focusedPackage = package
            } else if let name = captures(#"Window #\d+ Window\{\S+ u\d+ ([^}]+)\}"#, in: line)?.first {
                currentWindow = name
            } else if line.contains("Frames:"), let name = currentWindow, let frame = rect(after: " frame=", in: line) {
                windows.append((name, frame))
                currentWindow = nil
            }
        }

        if let package = focusedPackage {
            state.appFrame = windows
                .filter { $0.name.hasPrefix(package + "/") }
                .max { $0.frame.area < $1.frame.area }?
                .frame
        }
        return state
    }

    /// La parte de la pantalla que enseña la app: su marco, menos las barras a la vista que lo
    /// pisen desde un borde. Si queda algo absurdo —menos de un cuarto de la pantalla por algún
    /// lado—, la pantalla entera: sin recorte se ve todo, con un recorte malo se pierde el juego.
    public func visibleArea(in size: PixelSize) -> PixelRect {
        let screen = PixelRect(x: 0, y: 0, width: size.width, height: size.height)
        var area = appFrame.map { $0.intersection(screen) } ?? screen
        if area.isEmpty { area = screen }
        var left = area.x, top = area.y, right = area.maxX, bottom = area.maxY
        for bar in visibleBars {
            let piece = bar.intersection(screen)
            guard !piece.isEmpty else { continue }
            if piece.width >= piece.height {
                if piece.y == 0 {
                    top = max(top, piece.maxY)
                } else if piece.maxY == size.height {
                    bottom = min(bottom, piece.y)
                }
            } else {
                if piece.x == 0 {
                    left = max(left, piece.maxX)
                } else if piece.maxX == size.width {
                    right = min(right, piece.x)
                }
            }
        }
        let result = PixelRect(left: left, top: top, right: right, bottom: bottom)
        guard result.width * 4 >= size.width, result.height * 4 >= size.height else { return screen }
        return result
    }

    // MARK: - Lectura

    /// Las barras que se recortan: navegación y estado, con el nombre de Android 13–14 y el de
    /// Android 11–12.
    private static let barTypes: Set<String> = [
        "navigationBars", "statusBars",
        "ITYPE_NAVIGATION_BAR", "ITYPE_STATUS_BAR", "ITYPE_EXTRA_NAVIGATION_BAR"
    ]

    private static func visibleBar(in line: String) -> PixelRect? {
        guard let type = captures(#"type=(\S+)"#, in: line)?.first, barTypes.contains(type),
              line.contains("visible=true"),
              let frame = rect(after: " frame=", in: line), !frame.isEmpty else { return nil }
        return frame
    }

    private static func rect(after marker: String, in line: String) -> PixelRect? {
        let pattern = NSRegularExpression.escapedPattern(for: marker) + #"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]"#
        guard let numbers = captures(pattern, in: line)?.compactMap({ Int($0) }), numbers.count == 4 else { return nil }
        return PixelRect(left: numbers[0], top: numbers[1], right: numbers[2], bottom: numbers[3])
    }

    private static func captures(_ pattern: String, in line: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
    }
}
