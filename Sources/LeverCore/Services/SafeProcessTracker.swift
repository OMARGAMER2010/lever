import Darwin
import Foundation

/// Encuentra y cierra los procesos de una sesión aislada.
///
/// No se fía del árbol de padres: un proceso puede desligarse del suyo y seguir vivo cuando todo
/// lo demás se ha cerrado. Lo que no puede cambiar sin volver a ejecutarse es **qué binario es**, y
/// dentro del aislamiento solo puede ejecutar los del motor clonado para esa sesión. Así que «todo
/// proceso cuyo ejecutable está dentro de ese clon» es exactamente la sesión, con sus huérfanos.
public enum SafeProcessTracker {
    public static func processes(executableUnder root: URL) -> [pid_t] {
        executables(under: root).map(\.pid)
    }

    /// Los procesos de la sesión con la ruta de su ejecutable.
    public static func executables(under root: URL) -> [(pid: pid_t, path: String)] {
        guard let real = try? SandboxPath.canonical(root) else { return [] }
        let prefix = real.hasSuffix("/") ? real : real + "/"
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        let me = getpid()
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, pid != me else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let path = String(cString: buffer)
            return path.hasPrefix(prefix) ? (pid, path) : nil
        }
    }

    /// Pide que se cierren, espera un poco y corta en seco a los que sigan. Devuelve cuántos había.
    @discardableResult
    public static func terminate(executableUnder root: URL, grace: Duration = .seconds(3)) async -> Int {
        let initial = processes(executableUnder: root)
        guard !initial.isEmpty else { return 0 }
        initial.forEach { kill($0, SIGTERM) }
        let deadline = ContinuousClock.now.advanced(by: grace)
        while ContinuousClock.now < deadline, !processes(executableUnder: root).isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Los que se hayan desligado mientras tanto también caen: se vuelve a buscar.
        for _ in 0..<5 {
            let remaining = processes(executableUnder: root)
            guard !remaining.isEmpty else { break }
            remaining.forEach { kill($0, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return initial.count
    }

    /// Versión sin espera, para cuando Lever se cierra y no hay tiempo de ser educado.
    public static func killNow(executableUnder root: URL) {
        for _ in 0..<3 {
            let remaining = processes(executableUnder: root)
            guard !remaining.isEmpty else { return }
            remaining.forEach { kill($0, SIGKILL) }
            usleep(50_000)
        }
    }
}
