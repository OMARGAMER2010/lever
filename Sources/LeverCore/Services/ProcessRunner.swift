import Foundation

public enum ProcessRunnerError: Error, LocalizedError {
    case cannotStart(URL, String)

    public var errorDescription: String? {
        switch self {
        case .cannotStart(let executable, let reason):
            return "No se pudo iniciar \(executable.lastPathComponent): \(reason)"
        }
    }
}

/// Mando a distancia de un proceso en marcha: permite detenerlo desde la interfaz.
public final class ProcessSession: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = cancelRequested
        lock.unlock()
        if shouldStop { stop(process) }
    }

    /// Pide el cierre ordenado del proceso. Si ya terminó, no hace nada.
    public func cancel() {
        lock.lock()
        cancelRequested = true
        let running = process
        lock.unlock()
        if let running { stop(running) }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // Si a los tres segundos sigue vivo, se corta en seco.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

public final class ProcessRunner: @unchecked Sendable {
    public init() {}

    /// Ejecuta la orden y devuelve el resultado cuando el proceso termina.
    ///
    /// - Parameters:
    ///   - session: mando para poder cancelar desde fuera.
    ///   - onLine: se llama con cada línea completa según va apareciendo, sin esperar al final.
    public func run(
        _ command: ProcessCommand,
        session: ProcessSession? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let buffer = OutputBuffer(onLine: onLine)
            let readHandle = pipe.fileHandleForReading
            let finished = OnceFlag()

            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.currentDirectoryURL = command.currentDirectoryURL
            process.standardOutput = pipe
            process.standardError = pipe
            // Sin esto, una herramienta que pida contraseña se quedaría esperando para siempre.
            process.standardInput = FileHandle.nullDevice

            if let extra = command.environment {
                var environment = ProcessInfo.processInfo.environment
                extra.forEach { environment[$0.key] = $0.value }
                process.environment = environment
            }

            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { buffer.append(data) }
            }

            process.terminationHandler = { process in
                readHandle.readabilityHandler = nil
                let trailing = readHandle.readDataToEndOfFile()
                let output = buffer.finish(with: trailing)
                try? readHandle.close()
                guard finished.claim() else { return }
                continuation.resume(
                    returning: ProcessResult(
                        exitCode: process.terminationStatus,
                        output: output,
                        wasCancelled: session?.isCancelled ?? false
                    )
                )
            }

            do {
                try process.run()
                session?.attach(process)
            } catch {
                readHandle.readabilityHandler = nil
                try? readHandle.close()
                guard finished.claim() else { return }
                continuation.resume(
                    throwing: ProcessRunnerError.cannotStart(
                        command.executableURL,
                        error.localizedDescription
                    )
                )
            }
        }
    }
}

/// Garantiza que la continuación se reanuda una sola vez.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Acumula la salida del proceso y va entregando líneas completas.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        complete.append(chunk)
        pending.append(chunk)
        let lines = Self.drainLines(from: &pending)
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func finish(with trailing: Data) -> String {
        lock.lock()
        complete.append(trailing)
        pending.append(trailing)
        var lines = Self.drainLines(from: &pending)
        if !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        let output = String(decoding: complete, as: UTF8.self)
        lock.unlock()
        lines.filter { !$0.isEmpty }.forEach { onLine?($0) }
        return output
    }

    /// Separa por salto de línea y por retorno de carro: `7zz` usa `\r` para el porcentaje.
    private static func drainLines(from data: inout Data) -> [String] {
        var lines: [String] = []
        let separators: Set<UInt8> = [0x0A, 0x0D]
        var start = data.startIndex
        var index = data.startIndex

        while index < data.endIndex {
            if separators.contains(data[index]) {
                if index > start {
                    let text = String(decoding: data[start..<index], as: UTF8.self)
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { lines.append(trimmed) }
                }
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }

        data = start < data.endIndex ? Data(data[start...]) : Data()
        return lines
    }
}
