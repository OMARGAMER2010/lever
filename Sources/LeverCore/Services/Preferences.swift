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
