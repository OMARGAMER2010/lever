import Foundation

public enum ProcessRunnerError: Error, LocalizedError {
    case cannotStart(URL, String)

    public var errorDescription: String? {
        switch self {
        case .cannotStart(let executable, let reason):
            return "No se pudo iniciar \(executable.path): \(reason)"
        }
    }
}

public final class ProcessRunner: @unchecked Sendable {
    public init() {}

    public func run(_ command: ProcessCommand) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let outputBuffer = OutputBuffer()
            let readHandle = pipe.fileHandleForReading

            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.currentDirectoryURL = command.currentDirectoryURL
            process.standardOutput = pipe
            process.standardError = pipe

            readHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    outputBuffer.append(data)
                }
            }

            process.terminationHandler = { process in
                readHandle.readabilityHandler = nil
                let trailingData = readHandle.readDataToEndOfFile()
                let output = outputBuffer.string(with: trailingData)
                try? readHandle.close()
                continuation.resume(
                    returning: ProcessResult(
                        exitCode: process.terminationStatus,
                        output: output
                    )
                )
            }

            do {
                try process.run()
            } catch {
                readHandle.readabilityHandler = nil
                try? readHandle.close()
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

private final class OutputBuffer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.exerar.process-output")
    private var data = Data()

    func append(_ chunk: Data) {
        queue.sync {
            data.append(chunk)
        }
    }

    func string(with trailingData: Data) -> String {
        queue.sync {
            var completeData = data
            completeData.append(trailingData)
            return String(decoding: completeData, as: UTF8.self)
        }
    }
}
