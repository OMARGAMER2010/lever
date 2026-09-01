import Foundation

/// Ajustes que sobreviven entre sesiones. Nada sensible: solo rutas y preferencias de uso.
@MainActor
public enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let overwritePolicy = "overwritePolicy"
        static let revealWhenDone = "revealWhenDone"
        static let extractIntoSubfolder = "extractIntoSubfolder"
        static let customWinePath = "customWinePath"
        static let lastDestinationPath = "lastDestinationPath"
        static let language = "language"
        static let rotationChoice = "rotationChoice"
        static let playFullscreen = "playFullscreen"
        static let resumeSessions = "resumeSessions"
        static let switchKeysPath = "switchKeysPath"
        static let switchEmulatorPath = "switchEmulatorPath"
    }

    /// Si los juegos de consola se abren ocupando la pantalla entera.
    ///
    /// De fábrica no, porque una ventana deja ver Lever al lado mientras se prueba algo. Pero es
    /// una decisión que se toma una vez y se queda: quien juega, juega a pantalla completa.
    public static var playFullscreen: Bool {
        get { defaults.object(forKey: Key.playFullscreen) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.playFullscreen) }
    }

    /// Si al cerrar el juego se guarda el momento exacto y al volver a abrirlo se retoma ahí.
    ///
    /// De fábrica **sí**. Un emulador que se cierra sin más pierde la partida entera de las
    /// consolas que no tenían pila, que son casi todas las de ocho bits, y en las que la tenían
    /// pierde todo lo hecho desde el último punto de guardado del propio juego.
    public static var resumeSessions: Bool {
        get { defaults.object(forKey: Key.resumeSessions) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.resumeSessions) }
    }

    /// Dónde tiene el usuario su `prod.keys`.
    ///
    /// **Se guarda la ruta, nunca el contenido.** Las llaves se leen del archivo cada vez que hacen
    /// falta y se olvidan; meterlas en los ajustes las dejaría en un `.plist` sin cifrar del que el
    /// usuario no sabe nada y que se sincroniza y se respalda con todo lo demás.
    public static var switchKeysURL: URL? {
        get {
            guard let ruta = defaults.string(forKey: Key.switchKeysPath), !ruta.isEmpty else { return nil }
            let url = URL(fileURLWithPath: ruta)
            return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
        }
        set { defaults.set(newValue?.path, forKey: Key.switchKeysPath) }
    }

    /// El emulador de la consola híbrida que el usuario haya señalado a mano, cuando no está en
    /// ninguno de los sitios de siempre.
    public static var switchEmulatorURL: URL? {
        get {
            guard let ruta = defaults.string(forKey: Key.switchEmulatorPath), !ruta.isEmpty else { return nil }
            let url = URL(fileURLWithPath: ruta)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set { defaults.set(newValue?.path, forKey: Key.switchEmulatorPath) }
    }

    public static var rotationChoice: RotationChoice {
        get {
            guard let raw = defaults.string(forKey: Key.rotationChoice),
                  let choice = RotationChoice(rawValue: raw) else { return .automatic }
            return choice
        }
        set { defaults.set(newValue.rawValue, forKey: Key.rotationChoice) }
    }

    public static var language: Language {
        get {
            guard let raw = defaults.string(forKey: Key.language),
                  let language = Language(rawValue: raw) else { return .systemDefault }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    public static var overwritePolicy: OverwritePolicy {
        get {
            guard let raw = defaults.string(forKey: Key.overwritePolicy),
                  let policy = OverwritePolicy(rawValue: raw) else { return .skip }
            return policy
        }
        set { defaults.set(newValue.rawValue, forKey: Key.overwritePolicy) }
    }

    public static var revealWhenDone: Bool {
        get { defaults.object(forKey: Key.revealWhenDone) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.revealWhenDone) }
    }

    public static var extractIntoSubfolder: Bool {
        get { defaults.object(forKey: Key.extractIntoSubfolder) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.extractIntoSubfolder) }
    }

    public static var customWineURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.customWinePath), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        set { defaults.set(newValue?.path, forKey: Key.customWinePath) }
    }

    public static var lastDestinationURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastDestinationPath), !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url
        }
        set { defaults.set(newValue?.path, forKey: Key.lastDestinationPath) }
    }
}
