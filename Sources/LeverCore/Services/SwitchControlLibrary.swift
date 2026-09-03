import Foundation

/// Guarda y recupera los perfiles de control de la consola híbrida.
///
/// **Por qué los guarda Lever y no el emulador.** El emulador no tiene configuración de entrada por
/// juego: en su carpeta, `games/<identificador>/` solo lleva la caché de sombreadores y cuatro
/// datos de la lista. La única lista de perfiles que existe es la global de su `Config.json`. Así
/// que «distinto en este juego» solo puede vivir aquí, y aplicarse al lanzar —ver
/// `EmulatorControls`—.
///
/// Dos niveles y no tres, al revés que en `ControlLibrary`: allí el escalón de en medio era la
/// máquina, y aquí solo hay una.
public final class SwitchControlLibrary: @unchecked Sendable {
    public static let shared = SwitchControlLibrary()

    private let fileManager: FileManager
    private let customRoot: URL?

    public init(fileManager: FileManager = .default, root: URL? = nil) {
        self.fileManager = fileManager
        self.customRoot = root
    }

    /// Carpeta aparte de la de RetroArch a propósito: son dos vocabularios distintos y un archivo
    /// de uno leído como del otro no da error, da controles mudos.
    public var folderURL: URL {
        if let customRoot { return customRoot }
        let soporte = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return soporte.appendingPathComponent("Lever/controles-hibrida", isDirectory: true)
    }

    public func save(_ profile: SwitchControlProfile, for scope: SwitchControlScope) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        let datos = try codificador.encode(profile)
        try datos.write(to: folderURL.appendingPathComponent(scope.fileName))
    }

    public func load(_ scope: SwitchControlScope) -> SwitchControlProfile? {
        let archivo = folderURL.appendingPathComponent(scope.fileName)
        guard let datos = try? Data(contentsOf: archivo) else { return nil }
        return try? JSONDecoder().decode(SwitchControlProfile.self, from: datos)
    }

    public func remove(_ scope: SwitchControlScope) {
        try? fileManager.removeItem(at: folderURL.appendingPathComponent(scope.fileName))
    }

    /// El perfil que de verdad se va a usar: el del juego si lo tiene, si no el global, y si no la
    /// traducción de fábrica. **El último escalón es el que importa**: un juego que nadie ha
    /// configurado se juega igualmente, con el mando traducido por posición y sin tocar nada.
    public func resolved(gameId: String?) -> SwitchControlProfile {
        if let gameId, let propio = load(.game(gameId)) { return propio }
        return load(.global) ?? .standard
    }

    /// Qué nivel manda ahora mismo, para poder decirlo en vez de dejar al usuario adivinando por
    /// qué sus cambios no se ven.
    public func effectiveScope(gameId: String?) -> SwitchControlScope {
        if let gameId, load(.game(gameId)) != nil { return .game(gameId) }
        return .global
    }
}
