import Foundation

/// Una pantalla completa en marcha: el canal con el emulador, las imágenes que llegan, la entrada
/// que sale y lo que Android dice de su pantalla cada segundo.
///
/// No sabe nada de ventanas. Entrega lo que llega en hilos de fondo; quien pinta decide cuándo.
public final class AndroidFullscreenSession: @unchecked Sendable {
    public enum End: Equatable, Sendable {
        /// La cerró el usuario.
        case closedByUser
        /// El emulador se cerró o se cortó la conexión.
        case connectionLost
        /// El emulador no dejó ver su pantalla: llave rechazada, un método que no tiene…
        case refused(status: Int?)
    }

    public struct Handlers: Sendable {
        public var frame: @Sendable (EmulatorFrame) -> Void
        public var screenState: @Sendable (AndroidScreenState) -> Void
        public var ended: @Sendable (End) -> Void

        public init(
            frame: @escaping @Sendable (EmulatorFrame) -> Void,
            screenState: @escaping @Sendable (AndroidScreenState) -> Void,
            ended: @escaping @Sendable (End) -> Void
        ) {
            self.frame = frame
            self.screenState = screenState
            self.ended = ended
        }
    }

    /// Cada cuánto se pregunta a Android por su pantalla. Un juego que cambia de postura tarda
    /// como mucho esto en verse derecho.
    public static let pollInterval: TimeInterval = 1

    public let endpoint: EmulatorEndpoint

    private let channel: EmulatorChannel
    private let runner: ProcessRunner
    private let adb: URL?
    private let lock = NSLock()
    private var handlers: Handlers?
    private var screenStream: UInt32?
    private var inputStream: UInt32?
    private var inputIsBroken = false
    private var hasEnded = false
    private var framesReceived = 0
    private var startedAt: Date?
    private var pollTask: Task<Void, Never>?

    public init(endpoint: EmulatorEndpoint, channel: EmulatorChannel, runner: ProcessRunner, adb: URL?) {
        self.endpoint = endpoint
        self.channel = channel
        self.runner = runner
        self.adb = adb
    }

    public func start(_ handlers: Handlers) {
        lock.lock()
        self.handlers = handlers
        startedAt = Date()
        lock.unlock()

        let screen = channel.startCall(
            path: EmulatorMessages.Method.streamScreenshot,
            message: EmulatorMessages.screenFormat(),
            endStream: true,
            onMessage: { [weak self] data in self?.frameArrived(data) },
            onEnd: { [weak self] ending in self?.screenEnded(ending) }
        )
        // La entrada va por un flujo abierto y no por llamadas sueltas: así llega en orden. Un
        // «soltar» que adelantara a su «arrastrar» dejaría el dedo pegado a la pantalla.
        let input = channel.startCall(
            path: EmulatorMessages.Method.streamInputEvent,
            message: nil,
            endStream: false,
            onMessage: { _ in },
            onEnd: { [weak self] _ in self?.inputEnded() }
        )
        lock.lock()
        screenStream = screen
        inputStream = input
        lock.unlock()

        guard screen != nil else {
            end(.connectionLost)
            return
        }
        if let adb, let serial = endpoint.adbSerial { startPolling(adb: adb, serial: serial) }
    }

    public func sendMouse(x: Int, y: Int, pressed: Bool) {
        let mouse = EmulatorMessages.mouse(x: x, y: y, pressed: pressed)
        send(EmulatorMessages.inputEvent(mouse: mouse), fallbackPath: EmulatorMessages.Method.sendMouse, fallback: mouse)
    }

    public func sendKey(macKeyCode: UInt16, down: Bool) {
        let key = EmulatorMessages.key(macKeyCode: macKeyCode, down: down)
        send(EmulatorMessages.inputEvent(key: key), fallbackPath: EmulatorMessages.Method.sendKey, fallback: key)
    }

    public func stop() {
        end(.closedByUser)
    }

    /// Imágenes por segundo de media desde que empezó. `nil` durante el primer segundo.
    public var averageFramesPerSecond: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed >= 1 ? Double(framesReceived) / elapsed : nil
    }

    // MARK: - Por dentro

    /// Por el flujo de entrada. Si el emulador no lo tiene —versiones viejas—, por llamadas
    /// sueltas: pueden llegar desordenadas, pero llegan.
    private func send(_ event: Data, fallbackPath: String, fallback: Data) {
        lock.lock()
        let stream = inputStream, broken = inputIsBroken, ended = hasEnded
        lock.unlock()
        guard !ended else { return }
        if let stream, !broken {
            channel.send(message: event, on: stream)
        } else {
            channel.startCall(path: fallbackPath, message: fallback, endStream: true, onMessage: { _ in }, onEnd: { _ in })
        }
    }

    private func frameArrived(_ data: Data) {
        guard let frame = EmulatorMessages.frame(fromImage: data) else { return }
        lock.lock()
        framesReceived += 1
        let handlers = self.handlers
        let ended = hasEnded
        lock.unlock()
        guard !ended else { return }
        handlers?.frame(frame)
    }

    private func screenEnded(_ ending: EmulatorChannel.Ending) {
        lock.lock()
        let received = framesReceived
        lock.unlock()
        if received == 0, let status = ending.status, status != 0 {
            end(.refused(status: status))
        } else {
            end(.connectionLost)
        }
    }

    private func inputEnded() {
        lock.lock()
        inputIsBroken = true
        inputStream = nil
        lock.unlock()
    }

    private func startPolling(adb: URL, serial: String) {
        let runner = self.runner
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let command = AndroidLauncher.screenStateCommand(adb: adb, serial: serial)
                if let result = try? await runner.run(command), result.succeeded {
                    self?.stateArrived(AndroidScreenState.parse(result.output))
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
        lock.lock()
        pollTask = task
        let ended = hasEnded
        lock.unlock()
        if ended { task.cancel() }
    }

    private func stateArrived(_ state: AndroidScreenState) {
        lock.lock()
        let handlers = self.handlers
        let ended = hasEnded
        lock.unlock()
        guard !ended else { return }
        handlers?.screenState(state)
    }

    private func end(_ reason: End) {
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        let handlers = self.handlers
        let screen = screenStream, input = inputStream
        let task = pollTask
        lock.unlock()

        task?.cancel()
        if let input { channel.finish(stream: input) }
        if let screen { channel.cancel(stream: screen) }
        channel.close()
        handlers?.ended(reason)
    }
}
