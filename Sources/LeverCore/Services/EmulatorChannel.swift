import Foundation

/// Una conexión con el canal gRPC del emulador: un socket TCP local y un hilo que lo lee.
///
/// Implementa lo justo de HTTP/2 —ver `HTTP2Wire`— para abrir llamadas, recibir sus mensajes y
/// mandar los de la entrada, con control de flujo en los dos sentidos. Todo lo que llega se
/// entrega en el hilo lector: quien lo reciba y tenga que tocar la interfaz, que salte al hilo
/// principal.
///
/// Dos cerrojos: `writeLock` ordena lo que sale por el socket y `stateLock` protege el estado. Si
/// hacen falta los dos, siempre en ese orden.
public final class EmulatorChannel: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case cannotConnect
        case closed
        case timedOut
        case refused(status: Int?)
    }

    /// Cómo acabó una llamada.
    public struct Ending: Equatable, Sendable {
        /// `grpc-status` si se pudo leer. 0 es que acabó bien.
        public let status: Int?
        /// Cortada sin trailers: el emulador la reseteó o se cayó la conexión.
        public let wasReset: Bool
        /// Llegó algún mensaje antes del final.
        public let receivedMessages: Bool

        public var succeeded: Bool { status == 0 || (status == nil && !wasReset && receivedMessages) }
    }

    private final class Call {
        var reader = GrpcMessageReader()
        let onMessage: @Sendable (Data) -> Void
        let onEnd: @Sendable (Ending) -> Void
        var sendWindow: Int
        var queued: [(payload: Data, endStream: Bool)] = []
        var receivedMessages = false
        var unacknowledged = 0
        var localEnded = false

        init(sendWindow: Int, onMessage: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (Ending) -> Void) {
            self.sendWindow = sendWindow
            self.onMessage = onMessage
            self.onEnd = onEnd
        }
    }

    /// Cada cuánto se le devuelve al emulador la ventana de lo recibido.
    private static let acknowledgeEvery = 8 << 20

    private let socket: Int32
    private let token: String
    private let authority: String
    private let writeLock = NSLock()
    private let stateLock = NSLock()

    // Con `writeLock`.
    private var descriptorClosed = false
    // Con `stateLock`.
    private var nextStreamID: UInt32 = 1
    private var calls: [UInt32: Call] = [:]
    private var connectionSendWindow = 65_535
    private var peerInitialWindow = 65_535
    private var peerMaxFrameSize = HTTP2Wire.defaultMaxFrameSize
    private var unacknowledgedReceived = 0
    private var isClosed = false
    // Solo desde el hilo lector.
    private let hpack = HPACKDecoder()
    private var pendingHeaders: (stream: UInt32, flags: UInt8, block: Data)?

    public init(port: Int, token: String) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.cannotConnect }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw Failure.cannotConnect
        }
        var one: Int32 = 1
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // Sin esto, escribir en un socket que el emulador ya cerró mataría a Lever con SIGPIPE.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        socket = descriptor
        self.token = token
        authority = "127.0.0.1:\(port)"

        let opening = HTTP2Wire.preface + HTTP2Wire.clientSettings()
            + HTTP2Wire.windowUpdate(stream: 0, increment: HTTP2Wire.maxWindow - 65_535)
        guard write(opening) else {
            Darwin.close(descriptor)
            throw Failure.cannotConnect
        }

        let reader = Thread { [self] in readLoop() }
        reader.name = "Lever: canal del emulador"
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    deinit {
        close()
    }

    // MARK: - Llamadas

    /// Abre una llamada y manda su primer mensaje. Con `endStream`, la petición se da por terminada
    /// ahí (llamadas sueltas y la secuencia de imágenes); sin él, se pueden mandar más con `send`.
    @discardableResult
    public func startCall(
        path: String,
        message: Data?,
        endStream: Bool,
        onMessage: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (Ending) -> Void
    ) -> UInt32? {
        writeLock.lock()
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            writeLock.unlock()
            return nil
        }
        // El número se reparte con `writeLock` tomado para que las cabeceras salgan en orden:
        // HTTP/2 exige que cada flujo nuevo tenga un número mayor que todos los anteriores.
        let id = nextStreamID
        nextStreamID += 2
        calls[id] = Call(sendWindow: peerInitialWindow, onMessage: onMessage, onEnd: onEnd)
        stateLock.unlock()
        let headers = HTTP2Wire.frame(
            .headers, flags: HTTP2Wire.Flag.endHeaders, stream: id,
            payload: HTTP2Wire.requestHeaders(path: path, authority: authority, token: token)
        )
        let written = rawWrite(headers)
        writeLock.unlock()
        guard written else {
            failConnection()
            return nil
        }
        if let message {
            send(message: message, on: id, endStream: endStream)
        } else if endStream {
            finish(stream: id)
        }
        return id
    }

    /// Manda un mensaje más por una llamada abierta. Si no cabe en la ventana de flujo del
    /// emulador, espera en cola y sale en cuanto la amplía, sin adelantar a nadie.
    public func send(message: Data, on stream: UInt32, endStream: Bool = false) {
        enqueue(HTTP2Wire.grpcMessage(message), on: stream, endStream: endStream)
    }

    /// Da por terminada la parte de Lever de una llamada.
    public func finish(stream: UInt32) {
        enqueue(Data(), on: stream, endStream: true)
    }

    /// Corta una llamada: `RST_STREAM` con `CANCEL` (8). No avisa a quien la abrió.
    public func cancel(stream: UInt32) {
        stateLock.lock()
        let existed = calls.removeValue(forKey: stream) != nil
        let closed = isClosed
        stateLock.unlock()
        guard existed, !closed else { return }
        write(HTTP2Wire.frame(.resetStream, stream: stream, payload: HTTP2Wire.bigEndian(8)))
    }

    /// Cierra la conexión. Las llamadas abiertas acaban como reseteadas.
    public func close() {
        failConnection()
    }

    /// Una llamada suelta: manda un mensaje y espera la respuesta.
    public func unary(path: String, message: Data, timeout: TimeInterval = 5) async throws -> Data {
        let box = UnaryBox()
        return try await withCheckedThrowingContinuation { continuation in
            box.set(continuation)
            let stream = startCall(
                path: path, message: message, endStream: true,
                onMessage: { box.store($0) },
                onEnd: { box.finish($0) }
            )
            guard let stream else {
                box.fail(.closed)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if box.fail(.timedOut) { self?.cancel(stream: stream) }
            }
        }
    }

    // MARK: - Salida

    private func enqueue(_ payload: Data, on stream: UInt32, endStream: Bool) {
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        guard !isClosed, let call = calls[stream], !call.localEnded else {
            stateLock.unlock()
            return
        }
        if endStream { call.localEnded = true }
        call.queued.append((payload, endStream))
        let frames = takeSendable(from: call, stream: stream)
        stateLock.unlock()
        for frame in frames where !rawWrite(frame) {
            break
        }
    }

    /// Saca de la cola lo que cabe en las dos ventanas y lo convierte en tramas DATA, troceando
    /// si pasa del tamaño de trama del emulador. Con `stateLock` tomado.
    private func takeSendable(from call: Call, stream: UInt32) -> [Data] {
        var frames: [Data] = []
        while let next = call.queued.first {
            let size = next.payload.count
            guard size <= call.sendWindow, size <= connectionSendWindow else { break }
            call.queued.removeFirst()
            call.sendWindow -= size
            connectionSendWindow -= size
            var offset = 0
            repeat {
                let end = min(offset + peerMaxFrameSize, size)
                let chunk = next.payload.subdata(in: offset..<end)
                offset = end
                let flags = offset >= size && next.endStream ? HTTP2Wire.Flag.endStream : 0
                frames.append(HTTP2Wire.frame(.data, flags: flags, stream: stream, payload: chunk))
            } while offset < size
        }
        return frames
    }

    /// Tras ampliarse una ventana, sale lo que esperaba, flujo a flujo y en orden.
    private func flushQueued() {
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        var frames: [Data] = []
        for (id, call) in calls.sorted(by: { $0.key < $1.key }) where !call.queued.isEmpty {
            frames += takeSendable(from: call, stream: id)
        }
        stateLock.unlock()
        for frame in frames where !rawWrite(frame) {
            break
        }
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return rawWrite(data)
    }

    /// Escribe con `writeLock` ya tomado.
    private func rawWrite(_ data: Data) -> Bool {
        guard !descriptorClosed else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(socket, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    // MARK: - Entrada

    private func readLoop() {
        var header = Data(count: 9)
        while readExactly(into: &header, count: 9), let frame = HTTP2Wire.FrameHeader(header) {
            var payload = Data(count: frame.length)
            guard frame.length == 0 || readExactly(into: &payload, count: frame.length) else { break }
            guard handle(frame, payload) else { break }
        }
        failConnection()
        writeLock.lock()
        descriptorClosed = true
        Darwin.close(socket)
        writeLock.unlock()
    }

    private func readExactly(into buffer: inout Data, count: Int) -> Bool {
        buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let read = Darwin.recv(socket, base + offset, count - offset, 0)
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { return false }
                offset += read
            }
            return true
        }
    }

    /// `false` es un error del otro lado: se cierra la conexión.
    private func handle(_ frame: HTTP2Wire.FrameHeader, _ payload: Data) -> Bool {
        // Unas cabeceras partidas en CONTINUATION no admiten nada en medio.
        if let pending = pendingHeaders {
            guard frame.type == HTTP2Wire.FrameType.continuation.rawValue, frame.stream == pending.stream else { return false }
            let block = pending.block + payload
            if frame.flags & HTTP2Wire.Flag.endHeaders != 0 {
                pendingHeaders = nil
                headersArrived(stream: pending.stream, flags: pending.flags, block: block)
            } else {
                pendingHeaders = (pending.stream, pending.flags, block)
            }
            return true
        }
        switch HTTP2Wire.FrameType(rawValue: frame.type) {
        case .data:
            return dataArrived(frame, payload)
        case .headers:
            guard let block = HTTP2Wire.content(of: payload, flags: frame.flags, isHeaders: true) else { return false }
            if frame.flags & HTTP2Wire.Flag.endHeaders != 0 {
                headersArrived(stream: frame.stream, flags: frame.flags, block: block)
            } else {
                pendingHeaders = (frame.stream, frame.flags, block)
            }
            return true
        case .resetStream:
            endCall(frame.stream, status: nil, reset: true)
            return true
        case .settings:
            if frame.flags & HTTP2Wire.Flag.ack == 0 {
                applySettings(payload)
                write(HTTP2Wire.frame(.settings, flags: HTTP2Wire.Flag.ack, stream: 0))
                flushQueued()
            }
            return true
        case .ping:
            if frame.flags & HTTP2Wire.Flag.ack == 0 {
                write(HTTP2Wire.frame(.ping, flags: HTTP2Wire.Flag.ack, stream: 0, payload: payload))
            }
            return true
        case .windowUpdate:
            guard let raw = HTTP2Wire.readBigEndian(payload, at: 0) else { return false }
            stateLock.lock()
            let increment = Int(raw & 0x7FFF_FFFF)
            if frame.stream == 0 {
                connectionSendWindow += increment
            } else {
                calls[frame.stream]?.sendWindow += increment
            }
            stateLock.unlock()
            flushQueued()
            return true
        case .goAway, .pushPromise, .continuation:
            // El empuje se apaga en los ajustes y un CONTINUATION suelto no tiene sentido.
            return false
        case .priority, .none:
            return true
        }
    }

    private func dataArrived(_ frame: HTTP2Wire.FrameHeader, _ payload: Data) -> Bool {
        guard let content = HTTP2Wire.content(of: payload, flags: frame.flags, isHeaders: false) else { return false }
        stateLock.lock()
        var updates = Data()
        var messages: [Data] = []
        let call = calls[frame.stream]
        unacknowledgedReceived += frame.length
        if let call {
            call.unacknowledged += frame.length
            messages = call.reader.append(content)
            if !messages.isEmpty { call.receivedMessages = true }
            if call.unacknowledged >= Self.acknowledgeEvery {
                updates += HTTP2Wire.windowUpdate(stream: frame.stream, increment: call.unacknowledged)
                call.unacknowledged = 0
            }
        }
        if unacknowledgedReceived >= Self.acknowledgeEvery {
            updates += HTTP2Wire.windowUpdate(stream: 0, increment: unacknowledgedReceived)
            unacknowledgedReceived = 0
        }
        stateLock.unlock()
        if !updates.isEmpty { write(updates) }
        for message in messages { call?.onMessage(message) }
        if frame.flags & HTTP2Wire.Flag.endStream != 0 { endCall(frame.stream, status: nil, reset: false) }
        return true
    }

    private func headersArrived(stream: UInt32, flags: UInt8, block: Data) {
        // Se leen siempre, aunque no interesen: la tabla dinámica solo cuadra si se lee todo.
        let headers = hpack.decode(block)
        guard flags & HTTP2Wire.Flag.endStream != 0 else { return }
        let status = headers?.last(where: { $0.name == "grpc-status" }).flatMap { Int($0.value) }
        endCall(stream, status: status, reset: false)
    }

    private func applySettings(_ payload: Data) {
        stateLock.lock()
        for (id, value) in HTTP2Wire.settings(in: payload) {
            switch id {
            case HTTP2Wire.Setting.initialWindowSize:
                // HTTP/2: cambiar la ventana inicial mueve la de todos los flujos abiertos.
                let delta = Int(value) - peerInitialWindow
                peerInitialWindow = Int(value)
                for call in calls.values { call.sendWindow += delta }
            case HTTP2Wire.Setting.maxFrameSize:
                peerMaxFrameSize = max(HTTP2Wire.defaultMaxFrameSize, Int(value))
            default:
                break
            }
        }
        stateLock.unlock()
    }

    private func endCall(_ stream: UInt32, status: Int?, reset: Bool) {
        stateLock.lock()
        let call = calls.removeValue(forKey: stream)
        stateLock.unlock()
        guard let call else { return }
        call.onEnd(Ending(status: status, wasReset: reset, receivedMessages: call.receivedMessages))
    }

    /// Se acabó la conexión: todas las llamadas terminan como reseteadas.
    private func failConnection() {
        stateLock.lock()
        let wasClosed = isClosed
        isClosed = true
        let ended = calls
        calls.removeAll()
        stateLock.unlock()
        guard !wasClosed else { return }
        // Despierta al hilo lector; el descriptor lo cierra él al salir.
        Darwin.shutdown(socket, SHUT_RDWR)
        for call in ended.values {
            call.onEnd(Ending(status: nil, wasReset: true, receivedMessages: call.receivedMessages))
        }
    }
}

/// La respuesta de una llamada suelta, con un solo final aunque lleguen dos (la respuesta y el
/// tiempo agotado).
private final class UnaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var response: Data?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func store(_ data: Data) {
        lock.lock()
        response = data
        lock.unlock()
    }

    func finish(_ ending: EmulatorChannel.Ending) {
        lock.lock()
        let response = self.response
        lock.unlock()
        if ending.status == 0 || (ending.status == nil && !ending.wasReset && response != nil) {
            resume(.success(response ?? Data()))
        } else {
            resume(.failure(EmulatorChannel.Failure.refused(status: ending.status)))
        }
    }

    @discardableResult
    func fail(_ failure: EmulatorChannel.Failure) -> Bool {
        resume(.failure(failure))
    }

    @discardableResult
    private func resume(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard !resumed, let continuation else {
            lock.unlock()
            return false
        }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
