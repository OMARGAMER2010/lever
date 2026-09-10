import Foundation
import AppKit

/// La biblioteca se carga solo en el proceso de esa partida. No se cambia el entorno del Mac ni
/// la firma del emulador, y las teclas se guardan como asignaciones, nunca como un registro de uso.
public struct SwitchMouseSession: Sendable {
    public let folder: URL
    public let environment: [String: String]
    public let device: SDLGamepads.Device
    public let sdlGUID: String

    /// Evita repetir avisos durante el arranque y permite confirmar un mando que apareció tarde.
    public struct StartupMonitor {
        public private(set) var status: TextKey?

        public init() {}

        public mutating func update(isReady: Bool, hasFailed: Bool, timedOut: Bool) -> TextKey? {
            guard status != .switchMouseReady else { return nil }
            let siguiente: TextKey?
            if isReady { siguiente = .switchMouseReady }
            else if hasFailed || timedOut { siguiente = .switchMouseFailed }
            else { siguiente = nil }
            guard let siguiente, siguiente != status else { return nil }
            status = siguiente
            return siguiente
        }
    }

    public enum Failure: Error, Equatable {
        case unavailable, invalidSettings, launchFailed

        public var textKey: TextKey {
            switch self {
            case .unavailable: return .switchMouseUnavailable
            case .invalidSettings: return .switchMouseInvalidSettings
            case .launchFailed: return .switchMouseFailed
            }
        }
    }

    public struct Configuration: Codable, Sendable {
        public let version: Int
        public let sdlPath: String
        public let buttonKeys: [Int]
        public let triggerKeys: [Int]
        public let directionKeys: [Int]
        public let sensitivity: Double
        public let invertY: Bool
    }

    public static var moduleURL: URL? {
        let candidatas = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libLeverInputBridge.dylib"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libLeverInputBridge.dylib")
        ].compactMap { $0 }
        return candidatas.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func isAvailable(inside app: URL) -> Bool {
        moduleURL != nil && SDLGamepads.supportsMouseBridge(inside: app) && sdlURL(inside: app) != nil
    }

    private static func sdlURL(inside app: URL) -> URL? {
        SDLGamepads.libraryNames.map { app.appendingPathComponent("Contents/Frameworks/" + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func configuration(profile: SwitchControlProfile, sdl: URL) throws -> Configuration {
        guard profile.mouseSensitivity.isFinite, (0.2...4).contains(profile.mouseSensitivity) else {
            throw Failure.invalidSettings
        }
        func código(_ control: SwitchPadInput?) throws -> Int {
            guard let control else { return -1 }
            let nombre = profile.keyboardBinding(for: control)
            if nombre == SwitchKeyNames.unbound { return -1 }
            guard let tecla = SwitchKeyNames.keyCode(for: nombre), ![53, 54, 55].contains(tecla) else {
                throw Failure.invalidSettings
            }
            return Int(tecla)
        }
        // El mando virtual usa el orden público SDL, independientemente del rombo elegido para
        // el mando físico. De lo contrario «por etiqueta» cambiaría también el teclado sin pedirlo.
        let botones: [SwitchPadInput?] = [.b, .a, .y, .x, .minus, nil, .plus,
            .leftStickButton, .rightStickButton, .l, .r, .dpadUp, .dpadDown, .dpadLeft, .dpadRight]
        return try Configuration(version: 1, sdlPath: sdl.path,
            buttonKeys: botones.map(código), triggerKeys: [.zl, .zr].map(código),
            directionKeys: [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight,
                .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight].map(código),
            sensitivity: profile.mouseSensitivity, invertY: profile.invertMouseY)
    }

    @MainActor
    public static func prepare(profile: SwitchControlProfile, emulator: URL, root: URL? = nil) throws -> SwitchMouseSession {
        guard let módulo = moduleURL, SDLGamepads.supportsMouseBridge(inside: emulator),
              let biblioteca = sdlURL(inside: emulator),
              let puente = SDLGamepads.Library(path: módulo.path)
        else { throw Failure.unavailable }
        let config = try configuration(profile: profile, sdl: biblioteca)
        typealias Probe = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int32) -> Int32
        guard let sondeo = puente.symbol("LeverBridgeProbe", as: Probe.self) else { throw Failure.unavailable }
        var buffer = [CChar](repeating: 0, count: 33)
        let resultado = biblioteca.path.withCString { sondeo($0, &buffer, 33) }
        let guid = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard resultado == 0, let id = SDLGamepads.ryujinx133ID(forSDLGuid: guid) else { throw Failure.unavailable }
        let carpeta = (root ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("lever-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let archivo = carpeta.appendingPathComponent("session.json")
            try JSONEncoder().encode(config).write(to: archivo, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archivo.path)
            return SwitchMouseSession(folder: carpeta,
                environment: ["DYLD_INSERT_LIBRARIES": módulo.path, "LEVER_INPUT_SESSION": archivo.path],
                device: SDLGamepads.Device(id: id, name: EmulatorControls.virtualDeviceName), sdlGUID: guid)
        } catch {
            try? FileManager.default.removeItem(at: carpeta)
            throw error
        }
    }

    public var isReady: Bool {
        guard let datos = try? Data(contentsOf: folder.appendingPathComponent("status.json")),
              let estado = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else { return false }
        return estado["state"] as? String == "ready" && estado["guid"] as? String == sdlGUID
            && estado["controllerOpened"] as? Bool == true
    }

    public var hasFailed: Bool {
        guard let datos = try? Data(contentsOf: folder.appendingPathComponent("status.json")),
              let estado = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else { return false }
        return estado["state"] as? String == "failed" || estado["state"] as? String == "stopped"
    }

    @MainActor
    public func open(emulator: URL, game: URL) async throws -> NSRunningApplication {
        let configuración = NSWorkspace.OpenConfiguration()
        configuración.arguments = [game.path]
        var entorno = environment
        // Medición explícita del motor de laboratorio; no se hereda el resto del entorno.
        if let registro = ProcessInfo.processInfo.environment["LEVER_FRAME_LOG"],
           (registro as NSString).isAbsolutePath {
            entorno["LEVER_FRAME_LOG"] = registro
        }
        configuración.environment = entorno
        configuración.activates = true
        configuración.createsNewApplicationInstance = true
        return try await NSWorkspace.shared.openApplication(at: emulator, configuration: configuración)
    }

    public func finish() {
        try? FileManager.default.removeItem(at: folder)
    }
}
