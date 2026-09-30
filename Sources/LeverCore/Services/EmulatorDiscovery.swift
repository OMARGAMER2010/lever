import Foundation

/// Cómo llegar al canal de control de un emulador de Android que está en marcha.
///
/// El emulador abre por su cuenta un canal gRPC en `127.0.0.1` y deja el puerto y la llave en un
/// archivo de descubrimiento con su PID en el nombre (`pid_<pid>.ini`). Es el mismo canal que usa
/// Android Studio para meter el emulador en su propia ventana, y el que usa Lever para la pantalla
/// completa.
public struct EmulatorEndpoint: Equatable, Sendable {
    /// PID del proceso `qemu-system-*`: el dueño de las ventanas del emulador.
    public let pid: Int32
    public let grpcPort: Int
    /// La llave del canal. No se escribe nunca en la actividad.
    public let token: String
    /// Puerto de consola, que es el número de la serie de `adb`: `emulator-5554`.
    public let consolePort: Int?
    public let avdName: String?

    public init(pid: Int32, grpcPort: Int, token: String, consolePort: Int?, avdName: String?) {
        self.pid = pid
        self.grpcPort = grpcPort
        self.token = token
        self.consolePort = consolePort
        self.avdName = avdName
    }

    /// La serie con la que `adb` conoce a este emulador.
    public var adbSerial: String? { consolePort.map { "emulator-\($0)" } }
}

public enum EmulatorDiscovery {
    /// Dónde deja el emulador sus archivos de descubrimiento. En macOS es la primera carpeta; la
    /// segunda cubre las versiones que usan la carpeta temporal del usuario.
    public static var runningDirectories: [URL] {
        [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("avd/running", isDirectory: true)
        ]
    }

    /// Lee un archivo de descubrimiento. `nil` si le falta el puerto o la llave: sin ellos no hay
    /// canal, y un emulador no deja entrar a nadie sin su llave.
    public static func endpoint(fromDiscovery text: String, pid: Int32) -> EmulatorEndpoint? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        guard let port = values["grpc.port"].flatMap({ Int($0) }), port > 0,
              let token = values["grpc.token"], !token.isEmpty else { return nil }
        return EmulatorEndpoint(
            pid: pid,
            grpcPort: port,
            token: token,
            consolePort: values["port.serial"].flatMap { Int($0) },
            avdName: values["avd.name"]
        )
    }

    /// El PID va en el nombre: `pid_76325.ini` → 76325.
    public static func pid(fromFileName name: String) -> Int32? {
        guard name.hasPrefix("pid_"), name.hasSuffix(".ini") else { return nil }
        return Int32(name.dropFirst("pid_".count).dropLast(".ini".count))
    }

    /// Los emuladores en marcha. El archivo de un emulador que se cerró de golpe se queda en la
    /// carpeta; por eso se comprueba que su proceso siga vivo antes de fiarse de él.
    public static func running(
        in directories: [URL] = runningDirectories,
        isAlive: (Int32) -> Bool = processIsAlive,
        fileManager: FileManager = .default
    ) -> [EmulatorEndpoint] {
        var found: [EmulatorEndpoint] = []
        var seen = Set<Int32>()
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() {
                guard let pid = pid(fromFileName: name), !seen.contains(pid), isAlive(pid),
                      let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                      let endpoint = endpoint(fromDiscovery: text, pid: pid) else { continue }
                seen.insert(pid)
                found.append(endpoint)
            }
        }
        return found
    }

    /// `kill` con la señal 0 no le hace nada al proceso: solo dice si existe.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
