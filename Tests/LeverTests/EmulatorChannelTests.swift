import Darwin
import Foundation
import LeverCore

/// El canal con el emulador, contra un servidor HTTP/2 de pega que hace lo que hizo el emulador de
/// verdad —y alguna cosa más que un emulador podría hacer—, y, si hay uno abierto, contra él.
enum EmulatorChannelTests {
    static func run() async throws {
        try testReadsCallsAndTrailers()
        try testWaitsForTheFlowWindow()
        try await testTalksToARealEmulator()
    }

    private static func testReadsCallsAndTrailers() throws {
        let servidor = try FakeHTTP2Server()
        let guion = servidor.serve { conexión in
            let prefacio = try conexión.read(24)
            try expect(prefacio == HTTP2Wire.preface, "el cliente abre con el prefacio de HTTP/2")
            conexión.write(HTTP2Wire.frame(.settings, stream: 0))

            let (cabecera, bloque) = try conexión.readFrame(ofType: .headers)
            let campos = HPACKDecoder().decode(bloque) ?? []
            try expect(campos.contains { $0.name == ":path" && $0.value == "/prueba/Uno" }, "la ruta va en :path")
            try expect(campos.contains { $0.name == "authorization" && $0.value == "Bearer secreto" }, "la llave va como Bearer")
            let (datos, cuerpo) = try conexión.readFrame(ofType: .data)
            try expect(datos.flags & HTTP2Wire.Flag.endStream != 0, "una llamada suelta cierra su lado")
            try expect(cuerpo == HTTP2Wire.grpcMessage(Data([7, 7])), "el mensaje va con su prefijo gRPC")

            // Respuesta: cabeceras, un mensaje partido en dos tramas —la segunda con relleno— y otro entero.
            conexión.write(HTTP2Wire.frame(.headers, flags: HTTP2Wire.Flag.endHeaders, stream: cabecera.stream, payload: Data([0x88])))
            let hola = HTTP2Wire.grpcMessage(Data("hola".utf8))
            conexión.write(HTTP2Wire.frame(.data, stream: cabecera.stream, payload: hola.prefix(3)))
            let conRelleno = Data([2]) + hola.dropFirst(3) + Data([0, 0])
            conexión.write(HTTP2Wire.frame(.data, flags: HTTP2Wire.Flag.padded, stream: cabecera.stream, payload: conRelleno))
            conexión.write(HTTP2Wire.frame(.data, stream: cabecera.stream, payload: HTTP2Wire.grpcMessage(Data("adiós".utf8))))

            // Un PING en medio: tiene que volver con el visto bueno y el mismo contenido.
            conexión.write(HTTP2Wire.frame(.ping, stream: 0, payload: Data([1, 2, 3, 4, 5, 6, 7, 8])))
            let (ping, eco) = try conexión.readFrame(ofType: .ping)
            try expect(ping.flags & HTTP2Wire.Flag.ack != 0 && eco == Data([1, 2, 3, 4, 5, 6, 7, 8]), "el PING vuelve")

            // Los trailers reales del emulador: grpc-status 0, entrando en la tabla dinámica.
            let fin = HTTP2Wire.Flag.endHeaders | HTTP2Wire.Flag.endStream
            conexión.write(HTTP2Wire.frame(.headers, flags: fin, stream: cabecera.stream, payload: hexData("400b677270632d7374617475730130")))

            // La segunda llamada: solo trailers, con grpc-status por su índice (0xbe), como el emulador.
            let (segunda, _) = try conexión.readFrame(ofType: .headers)
            conexión.write(HTTP2Wire.frame(.headers, flags: fin, stream: segunda.stream, payload: Data([0x88, 0xBE])))

            // La tercera, rechazada: grpc-status 16.
            let (tercera, _) = try conexión.readFrame(ofType: .headers)
            let rechazo = Data([0x88, 0x00]) + HTTP2Wire.hpackString("grpc-status") + HTTP2Wire.hpackString("16")
            conexión.write(HTTP2Wire.frame(.headers, flags: fin, stream: tercera.stream, payload: rechazo))
        }

        let canal = try EmulatorChannel(port: servidor.port, token: "secreto")
        defer { canal.close() }

        let primera = Recogida()
        canal.startCall(path: "/prueba/Uno", message: Data([7, 7]), endStream: true,
                        onMessage: { primera.add($0) }, onEnd: { primera.end($0) })
        try primera.waitForEnd()
        try expect(primera.messages == [Data("hola".utf8), Data("adiós".utf8)], "los dos mensajes, el partido entero y en orden")
        try expect(primera.ending?.status == 0, "grpc-status 0 se lee de los trailers")

        let segunda = Recogida()
        canal.startCall(path: "/prueba/Dos", message: Data(), endStream: true,
                        onMessage: { segunda.add($0) }, onEnd: { segunda.end($0) })
        try segunda.waitForEnd()
        try expect(segunda.ending?.status == 0, "el estado nombrado por la tabla dinámica también se lee")

        let tercera = Recogida()
        canal.startCall(path: "/prueba/Tres", message: Data(), endStream: true,
                        onMessage: { tercera.add($0) }, onEnd: { tercera.end($0) })
        try tercera.waitForEnd()
        try expect(tercera.ending?.status == 16 && tercera.messages.isEmpty, "rechazada: su código y ningún mensaje")
        try guion.wait()
    }

    /// El emulador puede dar una ventana de flujo pequeña. Lo que no cabe espera, sin perderse ni
    /// adelantarse, hasta que la amplía.
    private static func testWaitsForTheFlowWindow() throws {
        let servidor = try FakeHTTP2Server()
        let guion = servidor.serve { conexión in
            _ = try conexión.read(24)
            // Ventana de 20 bytes por flujo: cabe un mensaje de 8 (13 con su prefijo), no dos.
            let ajustes = Data([0x00, 0x04]) + HTTP2Wire.bigEndian(20)
            conexión.write(HTTP2Wire.frame(.settings, stream: 0, payload: ajustes))
            let (cabecera, _) = try conexión.readFrame(ofType: .headers)
            let (_, primero) = try conexión.readFrame(ofType: .data)
            try expect(primero.count == 13, "el primer mensaje cabe y sale")
            try expect(conexión.isSilent(for: 0.3), "el segundo espera a que se amplíe la ventana")
            conexión.write(HTTP2Wire.windowUpdate(stream: cabecera.stream, increment: 100))
            let (_, segundo) = try conexión.readFrame(ofType: .data)
            try expect(segundo == HTTP2Wire.grpcMessage(Data("segundo!".utf8)), "al ampliarla sale, entero")
        }

        let canal = try EmulatorChannel(port: servidor.port, token: "x")
        defer { canal.close() }
        // Da tiempo a que lleguen los ajustes del servidor antes de abrir la llamada.
        Thread.sleep(forTimeInterval: 0.3)
        guard let flujo = canal.startCall(path: "/prueba/Entrada", message: nil, endStream: false,
                                          onMessage: { _ in }, onEnd: { _ in }) else {
            throw TestFailure(description: "no se abrió la llamada")
        }
        canal.send(message: Data("primero!".utf8), on: flujo)
        canal.send(message: Data("segundo!".utf8), on: flujo)
        try guion.wait()
    }

    /// Contra el emulador de verdad, si hay uno abierto: la llave del archivo abre el canal.
    private static func testTalksToARealEmulator() async throws {
        guard let emulador = EmulatorDiscovery.running().first else {
            print("SKIP EmulatorChannelTests: no hay ningún emulador abierto")
            return
        }
        let canal = try EmulatorChannel(port: emulador.grpcPort, token: emulador.token)
        defer { canal.close() }
        let respuesta = try await canal.unary(path: EmulatorMessages.Method.getStatus, message: Data())
        let estado = EmulatorMessages.status(from: respuesta)
        try expect(estado?.version.isEmpty == false, "el emulador dice su versión")
        print("INFO EmulatorChannelTests: emulador \(estado?.version ?? "?"), arrancado: \(estado?.booted == true)")
    }
}

/// Lo que llega por una llamada, recogido desde el hilo lector del canal.
private final class Recogida: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var received: [Data] = []
    private var ended: EmulatorChannel.Ending?

    var messages: [Data] { lock.lock(); defer { lock.unlock() }; return received }
    var ending: EmulatorChannel.Ending? { lock.lock(); defer { lock.unlock() }; return ended }

    func add(_ data: Data) {
        lock.lock()
        received.append(data)
        lock.unlock()
    }

    func end(_ ending: EmulatorChannel.Ending) {
        lock.lock()
        ended = ending
        lock.unlock()
        done.signal()
    }

    func waitForEnd() throws {
        guard done.wait(timeout: .now() + 5) == .success else {
            throw TestFailure(description: "la llamada no terminó")
        }
    }
}

/// Un servidor HTTP/2 de pega en 127.0.0.1, en un puerto libre, que atiende una conexión.
private final class FakeHTTP2Server: @unchecked Sendable {
    let port: Int
    private let listener: Int32

    init() throws {
        // Todo con una variable local: el cierre de `bind` no puede tocar `self` antes de que la
        // clase tenga sus dos propiedades.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw TestFailure(description: "no se pudo abrir el servidor de pega")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// Atiende una conexión en otro hilo con el guion dado. Lo que falle dentro se lanza al esperar.
    func serve(_ script: @escaping @Sendable (FakeConnection) throws -> Void) -> FakeServerRun {
        let run = FakeServerRun()
        let listener = self.listener
        let thread = Thread {
            let client = accept(listener, nil, nil)
            do {
                try script(FakeConnection(descriptor: client))
            } catch {
                run.fail(error)
            }
            // Da tiempo al cliente a leer lo último antes de cerrar.
            Thread.sleep(forTimeInterval: 0.2)
            close(client)
            close(listener)
            run.finish()
        }
        thread.start()
        return run
    }
}

private final class FakeServerRun: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var error: Error?

    func fail(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func finish() { done.signal() }

    /// Espera al guion y lanza lo que haya fallado dentro.
    func wait() throws {
        guard done.wait(timeout: .now() + 10) == .success else {
            throw TestFailure(description: "el servidor de pega no terminó su guion")
        }
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
    }
}

private struct FakeConnection {
    let descriptor: Int32

    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let read = recv(descriptor, base + offset, count - offset, 0)
                guard read > 0 else { return false }
                offset += read
            }
            return true
        }
        guard complete else { throw TestFailure(description: "el cliente cerró antes de tiempo") }
        return data
    }

    func readFrame() throws -> (HTTP2Wire.FrameHeader, Data) {
        guard let header = HTTP2Wire.FrameHeader(try read(9)) else {
            throw TestFailure(description: "cabecera de trama ilegible")
        }
        return (header, header.length > 0 ? try read(header.length) : Data())
    }

    /// Lee hasta dar con una trama del tipo pedido; las de control del cliente se saltan.
    func readFrame(ofType type: HTTP2Wire.FrameType) throws -> (HTTP2Wire.FrameHeader, Data) {
        while true {
            let frame = try readFrame()
            if frame.0.type == type.rawValue { return frame }
        }
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = send(descriptor, base, raw.count, 0)
        }
    }

    /// Si en ese tiempo no llega nada: para comprobar que el cliente **no** manda algo.
    func isSilent(for seconds: Double) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, Int32(seconds * 1000)) == 0
    }
}
