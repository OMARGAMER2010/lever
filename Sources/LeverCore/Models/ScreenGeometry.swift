import CoreGraphics

/// Un tamaño en píxeles del panel del aparato.
public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// El mismo panel girado un cuarto de vuelta: ancho y alto se cambian.
    public var swapped: PixelSize { PixelSize(width: height, height: width) }

    public func rotated(by quarterTurns: Int) -> PixelSize {
        ScreenGeometry.normalized(quarterTurns) % 2 == 0 ? self : swapped
    }
}

/// Un rectángulo en píxeles, con el origen arriba a la izquierda.
public struct PixelRect: Equatable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Como los da `adb`: `[izquierda,arriba][derecha,abajo]`.
    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.init(x: left, y: top, width: right - left, height: bottom - top)
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { isEmpty ? 0 : width * height }

    public func intersection(_ other: PixelRect) -> PixelRect {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        return PixelRect(left: left, top: top, right: right, bottom: bottom)
    }

    public var description: String { "[\(x),\(y) \(width)×\(height)]" }
}

/// Dónde y cómo se pinta la pantalla del emulador en la pantalla completa, y el camino de vuelta de
/// un clic al panel del aparato.
///
/// Tres sistemas de coordenadas, todos en píxeles del panel y con el origen arriba a la izquierda:
/// - **natural**: el panel tal como es (1080×2400 en el Pixel 6). Es el que entiende `sendMouse`,
///   gire como gire todo lo demás.
/// - **Android**: el natural girado lo que Android haya girado su pantalla (`mCurrentRotation`). Es
///   el que ve el juego, y en el que `adb` da las barras y los marcos de las ventanas.
/// - **imagen**: el natural girado lo que diga la piel del emulador. Así llegan los fotogramas.
///
/// Los giros van en cuartos de vuelta antihorarios, igual que `Surface.ROTATION_*` y que la piel.
/// La imagen se enseña girada como Android, que es como la ve el juego: derecha.
public struct ScreenGeometry: Equatable, Sendable {
    public let natural: PixelSize
    public let androidRotation: Int
    public let imageRotation: Int
    /// La parte que se enseña, en coordenadas de Android y siempre dentro de la pantalla.
    public let visibleArea: PixelRect
    /// El tamaño de la vista, en puntos.
    public let viewSize: CGSize

    public init(natural: PixelSize, androidRotation: Int, imageRotation: Int, visibleArea: PixelRect?, viewSize: CGSize) {
        self.natural = natural
        self.androidRotation = Self.normalized(androidRotation)
        self.imageRotation = Self.normalized(imageRotation)
        let size = natural.rotated(by: androidRotation)
        let screen = PixelRect(x: 0, y: 0, width: size.width, height: size.height)
        let clipped = visibleArea?.intersection(screen) ?? screen
        self.visibleArea = clipped.isEmpty ? screen : clipped
        self.viewSize = viewSize
    }

    public var androidSize: PixelSize { natural.rotated(by: androidRotation) }
    public var imageSize: PixelSize { natural.rotated(by: imageRotation) }

    /// Cuartos de vuelta antihorarios que hay que girar la imagen recibida para verla derecha.
    public var extraRotation: Int { Self.normalized(androidRotation - imageRotation) }

    /// La parte visible en coordenadas de la imagen recibida: lo que se recorta de cada fotograma.
    public var cropInImage: PixelRect {
        Self.rotate(visibleArea, quarterTurns: imageRotation - androidRotation, in: androidSize)
    }

    /// Puntos de vista por píxel del panel, para que quepa entera sin deformarse.
    public var scale: CGFloat {
        guard visibleArea.width > 0, visibleArea.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 0 }
        return min(viewSize.width / CGFloat(visibleArea.width), viewSize.height / CGFloat(visibleArea.height))
    }

    /// Dónde queda la imagen en la vista, centrada. Origen arriba a la izquierda, en puntos.
    public var displayRect: CGRect {
        let width = CGFloat(visibleArea.width) * scale
        let height = CGFloat(visibleArea.height) * scale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width, height: height)
    }

    /// Un punto de la vista (origen arriba a la izquierda) en coordenadas naturales del panel.
    /// `nil` si cae fuera de la imagen; con `clamped` se pega al borde, porque un arrastre que se
    /// sale de la imagen no debe soltar el dedo.
    public func naturalPoint(fromView point: CGPoint, clamped: Bool = false) -> (x: Int, y: Int)? {
        let rect = displayRect
        guard scale > 0 else { return nil }
        var inside = point
        if clamped {
            inside.x = min(max(inside.x, rect.minX), rect.maxX)
            inside.y = min(max(inside.y, rect.minY), rect.maxY)
        } else if !rect.contains(point) {
            return nil
        }
        let androidX = Double(visibleArea.x) + Double((inside.x - rect.minX) / scale)
        let androidY = Double(visibleArea.y) + Double((inside.y - rect.minY) / scale)
        let back = Self.rotate(x: androidX, y: androidY, quarterTurns: -androidRotation, in: androidSize)
        let x = min(max(Int(back.x.rounded(.down)), 0), natural.width - 1)
        let y = min(max(Int(back.y.rounded(.down)), 0), natural.height - 1)
        return (x, y)
    }

    public static func normalized(_ quarterTurns: Int) -> Int { ((quarterTurns % 4) + 4) % 4 }

    /// Gira un punto `quarterTurns` cuartos de vuelta antihorarios dentro de un espacio de ese
    /// tamaño. Un cuarto: (x, y) → (y, ancho − x), y el espacio pasa a ser alto × ancho.
    public static func rotate(x: Double, y: Double, quarterTurns: Int, in size: PixelSize) -> (x: Double, y: Double) {
        var point = (x: x, y: y)
        var space = size
        for _ in 0..<normalized(quarterTurns) {
            point = (x: point.y, y: Double(space.width) - point.x)
            space = space.swapped
        }
        return point
    }

    public static func rotate(_ rect: PixelRect, quarterTurns: Int, in size: PixelSize) -> PixelRect {
        var result = rect
        var space = size
        for _ in 0..<normalized(quarterTurns) {
            result = PixelRect(x: result.y, y: space.width - result.x - result.width, width: result.height, height: result.width)
            space = space.swapped
        }
        return result
    }
}
