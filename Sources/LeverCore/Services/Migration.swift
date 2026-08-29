import Foundation

/// La app ha cambiado de nombre dos veces: «EXE & RAR» → «Palanca» → «Lever». Cada cambio movió
/// el identificador del paquete y la carpeta de soporte, y eso deja huérfanas dos cosas que
/// costaron tiempo real: el entorno de Windows —que tarda minutos en construirse— y los ajustes.
///
/// Por eso los nombres anteriores son una lista y no un valor suelto: alguien que venga de la
/// primera versión y alguien que venga de la segunda tienen que acabar en el mismo sitio.
///
/// Se ejecuta una vez al arrancar y nunca pisa nada: si ya hay datos con el nombre actual, los
/// viejos se dejan como están.
@MainActor
public enum Migration {
    /// De más reciente a más antiguo: gana el primero que se encuentre.
    private static let legacyBundleIdentifiers = ["com.local.palanca", "com.local.exerar"]
    private static let legacySupportFolders = ["Palanca", "ExeRar"]
    private static let supportFolder = "Lever"

    /// Claves que la app entiende. Las que guarda AppKit con la posición de la ventana se quedan
    /// atrás a propósito: llevan dentro el nombre del tipo de la vista antigua y ya no valen.
    private static let carriedKeys = [
        "language", "overwritePolicy", "revealWhenDone",
        "extractIntoSubfolder", "customWinePath", "lastDestinationPath"
    ]

    public static func runIfNeeded(fileManager: FileManager = .default) {
        moveSupportFolder(fileManager: fileManager)
        copyPreferences()
    }

    /// Mueve la carpeta de soporte antigua, con el entorno de Windows dentro. Se mueve y no se
    /// copia: pesa cerca de un giga.
    private static func moveSupportFolder(fileManager: FileManager) {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }

        let destination = support.appendingPathComponent(supportFolder, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        for legacy in legacySupportFolders {
            let source = support.appendingPathComponent(legacy, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
            return
        }
    }

    /// Copia los ajustes del primer dominio antiguo que los tenga.
    private static func copyPreferences() {
        let defaults = UserDefaults.standard

        for identifier in legacyBundleIdentifiers {
            guard let legacy = UserDefaults(suiteName: identifier) else { continue }
            let available = carriedKeys.filter { legacy.object(forKey: $0) != nil }
            guard !available.isEmpty else { continue }

            for key in available where defaults.object(forKey: key) == nil {
                defaults.set(legacy.object(forKey: key), forKey: key)
            }
            return
        }
    }
}
