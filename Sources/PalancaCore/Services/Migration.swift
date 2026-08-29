import Foundation

/// La app se llamó «EXE & RAR» antes de llamarse Palanca. Cambiar el nombre cambió también el
/// identificador del paquete y la carpeta de soporte, y eso deja huérfanas dos cosas que costaron
/// tiempo real: el entorno de Windows —que tarda minutos en construirse— y los ajustes.
///
/// Esto se ejecuta una vez al arrancar y se las lleva al sitio nuevo. Nunca pisa nada: si ya hay
/// datos nuevos, no toca los viejos.
@MainActor
public enum Migration {
    private static let oldBundleIdentifier = "com.local.exerar"
    private static let oldSupportFolder = "ExeRar"
    private static let newSupportFolder = "Palanca"

    public static func runIfNeeded(fileManager: FileManager = .default) {
        moveSupportFolder(fileManager: fileManager)
        copyPreferences()
    }

    /// Mueve `Application Support/ExeRar` a `Application Support/Palanca`, con el entorno de
    /// Windows dentro. Se mueve, no se copia: pesa cerca de un giga.
    private static func moveSupportFolder(fileManager: FileManager) {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let old = support.appendingPathComponent(oldSupportFolder, isDirectory: true)
        let new = support.appendingPathComponent(newSupportFolder, isDirectory: true)

        guard fileManager.fileExists(atPath: old.path) else { return }
        guard !fileManager.fileExists(atPath: new.path) else { return }

        try? fileManager.moveItem(at: old, to: new)
    }

    /// Copia los ajustes del dominio antiguo. Solo los que la app entiende: las claves de
    /// posición de ventana que guarda AppKit se quedan atrás a propósito, porque llevan dentro
    /// el nombre del tipo de la vista antigua y ya no valen para nada.
    private static func copyPreferences() {
        let defaults = UserDefaults.standard
        guard let old = UserDefaults(suiteName: oldBundleIdentifier) else { return }

        let carried = [
            "language", "overwritePolicy", "revealWhenDone",
            "extractIntoSubfolder", "customWinePath", "lastDestinationPath"
        ]

        for key in carried where defaults.object(forKey: key) == nil {
            guard let value = old.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
    }
}
