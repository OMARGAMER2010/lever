import AppKit
import LeverCore

/// Abre la ventana de pantalla completa y se acuerda de ella: como mucho hay una.
@MainActor
final class AndroidFullscreenPresenter {
    static let shared = AndroidFullscreenPresenter()

    private var current: AndroidFullscreenWindowController?

    /// `emulatorPID` lo da el botón pegado al menú lateral; sin él, el emulador de la pestaña
    /// Android. `screen`, dónde abrirla: la del emulador, si se sabe.
    func present(model: AppModel, emulatorPID: Int32?, screen: NSScreen?) {
        if let current {
            current.bringToFront()
            return
        }
        guard let target = screen ?? NSScreen.main ?? NSScreen.screens.first,
              let session = model.openAndroidFullscreen(emulatorPID: emulatorPID) else { return }
        let controller = AndroidFullscreenWindowController(session: session, model: model, screen: target)
        controller.onClose = { [weak self] in self?.current = nil }
        current = controller
        controller.show()
    }
}

/// La ventana de pantalla completa: enseña lo que manda el emulador, derecho y sin barras, y le
/// devuelve el ratón y el teclado.
@MainActor
final class AndroidFullscreenWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let session: AndroidFullscreenSession
    private let model: AppModel
    private let window: NSWindow
    private let screenView: EmulatorScreenView
    private let mailbox = FrameMailbox()
    private let openedAt = Date()
    private var lastFrame: EmulatorFrame?
    private var screenState = AndroidScreenState()
    private var knowsScreenState = false
    private var retryScheduled = false
    private var isClosing = false
    private var finger: (x: Int, y: Int)?

    init(session: AndroidFullscreenSession, model: AppModel, screen: NSScreen) {
        self.session = session
        self.model = model
        screenView = EmulatorScreenView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        super.init()

        window.title = model.strings[.androidFullscreen]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentView = screenView
        window.delegate = self

        screenView.hintText = model.strings[.androidFullscreenExitHint]
        screenView.onMouse = { [weak self] point, phase in self?.mouse(at: point, phase) }
        screenView.onKey = { [weak self] code, down in self?.session.sendKey(macKeyCode: code, down: down) }
        screenView.onClose = { [weak self] in self?.window.performClose(nil) }
        screenView.onResize = { [weak self] in self?.render() }
    }

    func show() {
        let mailbox = self.mailbox
        // Los avisos llegan en hilos de fondo. Se copia la referencia débil a una constante antes
        // de saltar al hilo principal: Swift 6 no deja capturar la variable débil dos veces.
        session.start(AndroidFullscreenSession.Handlers(
            frame: { [weak self] frame in
                guard mailbox.put(frame) else { return }
                let controller = self
                DispatchQueue.main.async { MainActor.assumeIsolated { controller?.drainFrames() } }
            },
            screenState: { [weak self] state in
                let controller = self
                DispatchQueue.main.async { MainActor.assumeIsolated { controller?.screenStateArrived(state) } }
            },
            ended: { [weak self] end in
                let controller = self
                DispatchQueue.main.async { MainActor.assumeIsolated { controller?.sessionEnded(end) } }
            }
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(screenView)
        window.toggleFullScreen(nil)
        screenView.showHint()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Imagen

    private func drainFrames() {
        guard !isClosing, let frame = mailbox.take() else { return }
        lastFrame = frame
        render()
    }

    private func screenStateArrived(_ state: AndroidScreenState) {
        guard !isClosing else { return }
        screenState = state
        knowsScreenState = true
        render()
    }

    /// Hasta que Android no dice cómo tiene girada su pantalla no se pinta nada —medio segundo
    /// como mucho—: así el juego no aparece de lado un instante nada más abrir.
    private func render() {
        guard !isClosing, let frame = lastFrame else { return }
        if !knowsScreenState, Date().timeIntervalSince(openedAt) < 0.6 {
            guard !retryScheduled else { return }
            retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    self?.retryScheduled = false
                    self?.render()
                }
            }
            return
        }
        guard !frame.isEmpty else {
            screenView.clear()
            return
        }
        let natural = PixelSize(width: frame.width, height: frame.height).rotated(by: frame.rotation)
        let androidRotation = screenState.rotation ?? frame.rotation
        let visible = screenState.rotation == nil ? nil : screenState.visibleArea(in: natural.rotated(by: androidRotation))
        let geometry = ScreenGeometry(
            natural: natural, androidRotation: androidRotation, imageRotation: frame.rotation,
            visibleArea: visible, viewSize: screenView.bounds.size
        )
        screenView.show(frame, geometry: geometry)
    }

    // MARK: - Ratón

    private func mouse(at point: CGPoint, _ phase: EmulatorScreenView.MousePhase) {
        guard let geometry = screenView.geometry else { return }
        switch phase {
        case .down:
            guard let panel = geometry.naturalPoint(fromView: point) else { return }
            finger = panel
            session.sendMouse(x: panel.x, y: panel.y, pressed: true)
        case .dragged:
            guard finger != nil, let panel = geometry.naturalPoint(fromView: point, clamped: true) else { return }
            finger = panel
            session.sendMouse(x: panel.x, y: panel.y, pressed: true)
        case .up:
            guard finger != nil, let panel = geometry.naturalPoint(fromView: point, clamped: true) else { return }
            finger = nil
            session.sendMouse(x: panel.x, y: panel.y, pressed: false)
        }
    }

    /// Al perder el foco se suelta todo: un dedo o una tecla que se quedaran abajo seguirían
    /// pulsados en el juego aunque ya nadie los toque.
    private func releaseEverything() {
        screenView.releaseKeys()
        if let finger {
            session.sendMouse(x: finger.x, y: finger.y, pressed: false)
            self.finger = nil
        }
    }

    // MARK: - Cierre

    func windowDidResignKey(_ notification: Notification) {
        releaseEverything()
    }

    /// Salir de la pantalla completa es salir: esta ventana no tiene sentido en pequeño.
    func windowDidExitFullScreen(_ notification: Notification) {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        releaseEverything()
        let media = session.averageFramesPerSecond
        session.stop()
        model.androidFullscreenEnded(.closedByUser, framesPerSecond: media)
        onClose?()
    }

    private func sessionEnded(_ end: AndroidFullscreenSession.End) {
        guard !isClosing else { return }
        isClosing = true
        model.androidFullscreenEnded(end, framesPerSecond: session.averageFramesPerSecond)
        window.close()
        onClose?()
    }
}

/// La vista que pinta la pantalla del emulador y recoge el ratón y el teclado.
final class EmulatorScreenView: NSView {
    enum MousePhase {
        case down, dragged, up
    }

    var onMouse: (@MainActor (CGPoint, MousePhase) -> Void)?
    var onKey: (@MainActor (UInt16, Bool) -> Void)?
    var onClose: (@MainActor () -> Void)?
    var onResize: (@MainActor () -> Void)?
    var hintText = ""
    private(set) var geometry: ScreenGeometry?

    private let imageLayer = CALayer()
    private var heldKeys = Set<UInt16>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    /// Pinta un fotograma recortado y girado según la geometría. La capa gira alrededor de su
    /// centro, así que basta con darle el tamaño de lo recortado y ponerla en el centro del hueco.
    func show(_ frame: EmulatorFrame, geometry: ScreenGeometry) {
        self.geometry = geometry
        let crop = geometry.cropInImage
        guard let image = Self.image(from: frame, crop: crop) else { return }
        let rect = geometry.displayRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.bounds = CGRect(x: 0, y: 0,
                                   width: CGFloat(crop.width) * geometry.scale,
                                   height: CGFloat(crop.height) * geometry.scale)
        // La vista no está volteada: su origen está abajo y el de la geometría, arriba.
        imageLayer.position = CGPoint(x: rect.midX, y: bounds.height - rect.midY)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(geometry.extraRotation) * .pi / 2))
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }

    static func image(from frame: EmulatorFrame, crop: PixelRect) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let full = CGImage(
                width: frame.width, height: frame.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        if crop == PixelRect(x: 0, y: 0, width: frame.width, height: frame.height) { return full }
        return full.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)) ?? full
    }

    // MARK: - Ratón

    override func mouseDown(with event: NSEvent) { onMouse?(topLeft(event), .down) }
    override func mouseDragged(with event: NSEvent) { onMouse?(topLeft(event), .dragged) }
    override func mouseUp(with event: NSEvent) { onMouse?(topLeft(event), .up) }

    private func topLeft(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    // MARK: - Teclado

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        // Mantener una tecla la repite el propio Android: reenviar las repeticiones del Mac
        // haría que cada pulsación larga contara doble.
        guard !event.isARepeat else { return }
        heldKeys.insert(event.keyCode)
        onKey?(event.keyCode, true)
    }

    override func keyUp(with event: NSEvent) {
        guard heldKeys.remove(event.keyCode) != nil else { return }
        onKey?(event.keyCode, false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let flag = Self.forwardedModifier(for: event.keyCode) else { return }
        let down = event.modifierFlags.contains(flag)
        if down {
            heldKeys.insert(event.keyCode)
        } else {
            heldKeys.remove(event.keyCode)
        }
        onKey?(event.keyCode, down)
    }

    /// Mayúsculas, control y opción van al juego. ⌘ y fn se quedan en el Mac, que las necesita
    /// para salir y para sus atajos.
    static func forwardedModifier(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        default: return nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func releaseKeys() {
        for key in heldKeys { onKey?(key, false) }
        heldKeys.removeAll()
    }

    // MARK: - Aviso

    /// «⌘W para salir» arriba, unos segundos: la pantalla completa no tiene botones a la vista.
    func showHint() {
        let label = NSTextField(labelWithString: hintText)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        addSubview(box)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 48)
        ])
        // Sin `runAnimationGroup`: su cierre no es `Sendable` y Swift 6 no deja pasarlo desde aquí.
        // El `animator()` suelto anima igual, con la duración de siempre.
        Task { @MainActor [weak box] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            box?.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 400_000_000)
            box?.removeFromSuperview()
        }
    }
}

/// Guarda la última imagen hasta que el hilo principal pueda pintarla. Si llega otra antes, la
/// vieja se tira: es mejor saltarse un fotograma que ir cada vez más atrasado.
final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: EmulatorFrame?
    private var isScheduled = false

    /// `true` si hay que avisar al hilo principal; `false` si ya estaba avisado.
    func put(_ frame: EmulatorFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = frame
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    func take() -> EmulatorFrame? {
        lock.lock()
        defer { lock.unlock() }
        isScheduled = false
        let frame = pending
        pending = nil
        return frame
    }
}
