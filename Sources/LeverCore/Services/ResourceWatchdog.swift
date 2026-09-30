import Darwin
import Foundation

/// Por qué se cortó un proceso aislado.
public enum ResourceLimitReason: String, Codable, Equatable, Sendable {
    /// Un archivo pasó del tamaño máximo por archivo (`SIGXFSZ`).
    case fileSize
    /// Escribió más de lo que el comprimido decía contener.
    case bytesWritten
    /// El disco se quedaba por debajo de la reserva.
    case diskSpace
    /// La memoria del proceso se disparó.
    case memory
}

/// Vigila un proceso aislado y lo corta si se pasa.
///
/// Mira contadores del kernel, no carpetas: `proc_pid_rusage` dice cuántos bytes ha escrito el
/// proceso y cuánta memoria ocupa, sin recorrer miles de archivos, y el espacio libre del volumen
/// sale de `statfs`. Una bomba de descompresión se delata en cualquiera de las tres cosas.
public final class ResourceWatchdog: @unchecked Sendable {
    private let session: ProcessSession
    private let volume: URL
    private let maximumBytesWritten: Int64?
    private let diskReserve: Int64
    private let maximumFootprint: Int64?
    private let lock = NSLock()
    private var reason: ResourceLimitReason?
    private var task: Task<Void, Never>?

    public init(
        session: ProcessSession,
        volume: URL,
        maximumBytesWritten: Int64?,
        diskReserve: Int64 = SafeArchiveAnalyzer.diskReserveBytes,
        maximumFootprint: Int64?
    ) {
        self.session = session
        self.volume = volume
        self.maximumBytesWritten = maximumBytesWritten
        self.diskReserve = diskReserve
        self.maximumFootprint = maximumFootprint
    }

    public var tripped: ResourceLimitReason? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    public func start(interval: Duration = .milliseconds(400)) {
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let reason = self.check() {
                    self.trip(reason)
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Una comprobación. Pública para poder probar la lógica sin esperar a un proceso real.
    public func check() -> ResourceLimitReason? {
        if let free = Self.freeBytes(on: volume), free < diskReserve { return .diskSpace }
        guard let pid = session.processIdentifier, let usage = Self.usage(of: pid) else { return nil }
        if let maximumBytesWritten, Int64(usage.written) > maximumBytesWritten { return .bytesWritten }
        if let maximumFootprint, Int64(usage.footprint) > maximumFootprint { return .memory }
        return nil
    }

    private func trip(_ reason: ResourceLimitReason) {
        lock.lock()
        self.reason = reason
        lock.unlock()
        if let pid = session.processIdentifier { kill(pid, SIGKILL) }
        session.cancel()
    }

    public static func usage(of pid: pid_t) -> (written: UInt64, footprint: UInt64)? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_diskio_byteswritten, info.ri_phys_footprint)
    }

    public static func freeBytes(on url: URL) -> Int64? {
        var info = statfs()
        var probe = url
        // El destino puede no existir todavía: vale cualquier carpeta del mismo volumen.
        while statfs(probe.path, &info) != 0 {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Un techo razonable de memoria para un extractor: la mitad de la del Mac, y nunca menos de
    /// 4 GB, que es lo que puede pedir de verdad un diccionario grande de LZMA o de Zstd.
    public static var defaultExtractionFootprint: Int64 {
        max(4 * 1_073_741_824, Int64(ProcessInfo.processInfo.physicalMemory / 2))
    }
}
