import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// El modo de pantalla de la consola híbrida, que es el ajuste de rendimiento que más se nota.
///
/// La consola real dibuja a 1080p puesta en su base y a 720p en la mano, y el emulador hace lo
/// mismo. Son la mitad de píxeles: en un Mac que va justo, es la diferencia entre ir fluido y dar
/// tirones. Se paga en nitidez, y por eso lo elige el usuario y no Lever.
public enum EmulatorDisplayMode: String, Equatable, Sendable, CaseIterable {
    /// Como en la base: 1080p. Más nítido y más caro.
    case docked
    /// Como en la mano: 720p. La mitad de píxeles.
    case handheld

    public var textKey: TextKey {
        switch self {
        case .docked: return .displayModeDocked
        case .handheld: return .displayModeHandheld
        }
    }

    public var other: EmulatorDisplayMode { self == .docked ? .handheld : .docked }
}

/// Lee y cambia ajustes concretos de un emulador de programa aparte.
///
/// **Aquí Lever sí escribe, y merece explicación** porque `EmulatorInputReader` justo al lado solo
/// lee. La diferencia es el tamaño del compromiso: un mapa de controles son decenas de campos
/// anidados que cada versión del emulador reorganiza, y escribirlo es firmarse a romperse. Esto es
/// **una clave booleana** con nombre estable desde hace años, y se cambia leyendo el archivo
/// entero, tocando solo esa clave y volviéndolo a escribir. Lo que no se entiende, no se toca.
public enum EmulatorSettings {
    /// El identificador de paquete de la familia Ryujinx, para saber si está abierto.
    static let ryujinxBundleId = "org.ryujinx.Ryujinx"

    static func configURL(for emulator: StandaloneEmulator, fileManager: FileManager) -> URL {
        emulator.dataURL(fileManager: fileManager).appendingPathComponent("Config.json")
    }

    /// En qué modo está, o `nil` si no se sabe leer la configuración de este emulador.
    public static func displayMode(
        of emulator: StandaloneEmulator, fileManager: FileManager = .default
    ) -> EmulatorDisplayMode? {
        displayMode(atConfig: configURL(for: emulator, fileManager: fileManager))
    }

    /// La misma lectura sobre un archivo concreto. Separada para poder probarla contra un
    /// `Config.json` fabricado: esto **escribe** en la configuración de otro programa, y eso no se
    /// prueba por primera vez sobre la del usuario.
    public static func displayMode(atConfig url: URL) -> EmulatorDisplayMode? {
        guard let datos = try? Data(contentsOf: url),
              let raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let enBase = raíz["docked_mode"] as? Bool
        else { return nil }
        return enBase ? .docked : .handheld
    }

    /// Cambia el modo. Devuelve `false` si no se pudo, sin dejar el archivo a medias.
    ///
    /// Se escribe a un archivo aparte y se mueve encima: si algo falla a mitad, lo que queda es la
    /// configuración de antes y no un `Config.json` truncado, que dejaría al emulador sin arrancar.
    @discardableResult
    public static func setDisplayMode(
        _ mode: EmulatorDisplayMode, for emulator: StandaloneEmulator,
        fileManager: FileManager = .default
    ) -> Bool {
        setDisplayMode(mode, atConfig: configURL(for: emulator, fileManager: fileManager),
                       fileManager: fileManager)
    }

    /// La misma escritura sobre un archivo concreto, para poder probarla sin tocar la del usuario.
    @discardableResult
    public static func setDisplayMode(
        _ mode: EmulatorDisplayMode, atConfig archivo: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let datos = try? Data(contentsOf: archivo),
              var raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any]
        else { return false }

        raíz["docked_mode"] = (mode == .docked)
        guard let salida = try? JSONSerialization.data(
            withJSONObject: raíz, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        let temporal = archivo.deletingLastPathComponent()
            .appendingPathComponent("Config.json.lever-\(UUID().uuidString)")
        guard (try? salida.write(to: temporal)) != nil else { return false }
        guard (try? fileManager.replaceItemAt(archivo, withItemAt: temporal)) != nil else {
            try? fileManager.removeItem(at: temporal)
            return false
        }
        return true
    }

    /// Si el emulador está abierto ahora mismo.
    ///
    /// Importa porque estos emuladores **reescriben su configuración al cerrarse**: cambiar el modo
    /// con el emulador abierto se pierde en cuanto se cierra, y el usuario vería el botón hacer algo
    /// que luego se deshace solo. Sabiéndolo se puede avisar antes.
    @MainActor
    public static func isRunning(_ emulator: StandaloneEmulator) -> Bool {
        #if canImport(AppKit)
        let nombre = emulator.bundleNames.first?
            .replacingOccurrences(of: ".app", with: "").lowercased()
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == ryujinxBundleId
                || app.localizedName?.lowercased() == nombre
        }
        #else
        return false
        #endif
    }
}
