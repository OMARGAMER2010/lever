import Foundation
import LeverCore

enum LocalizationTests {
    static func run() throws {
        try testEveryLanguageCoversEveryKey()
        try testNoTextIsLeftInTheOtherLanguage()
        try testFormatPlaceholdersMatchAcrossLanguages()
        try testLanguageHasFlagAndNativeName()
    }

    /// La razón de que las claves sean un enum: se puede comprobar que no falta ninguna,
    /// en vez de descubrir un hueco cuando el usuario cambia de idioma.
    private static func testEveryLanguageCoversEveryKey() throws {
        for language in Language.allCases {
            let table = Strings.rawTable(for: language)
            let missing = TextKey.allCases.filter { table[$0] == nil }
            try expect(
                missing.isEmpty,
                "\(language.rawValue) no traduce: \(missing.map(\.rawValue).joined(separator: ", "))"
            )
        }
    }

    /// Una traducción idéntica en los dos idiomas casi siempre significa que se olvidó traducirla.
    /// Se permiten los nombres propios y las palabras que no cambian.
    private static func testNoTextIsLeftInTheOtherLanguage() throws {
        let allowed: Set<TextKey> = [
            .toolWine, .toolExtractor, .wineOptionGptk, .wineOptionCrossover,
            .archArm, .wineSettings, .arch64, .arch32,
            // Nombres propios y una marca: «Android» y «Android Studio» se escriben igual en
            // los dos idiomas, y traducirlos sería inventar.
            .tabAndroid, .toolAndroid, .deviceAndroidVersion, .androidOptionStudio
        ]
        let spanish = Strings.rawTable(for: .spanish)
        let english = Strings.rawTable(for: .english)

        let identical = TextKey.allCases.filter { key in
            !allowed.contains(key) && spanish[key] == english[key]
        }
        try expect(
            identical.isEmpty,
            "sin traducir: \(identical.map(\.rawValue).joined(separator: ", "))"
        )
    }

    /// Si un idioma tiene `%@` y el otro no, `String(format:)` produce basura o se traga el dato.
    private static func testFormatPlaceholdersMatchAcrossLanguages() throws {
        let spanish = Strings.rawTable(for: .spanish)
        let english = Strings.rawTable(for: .english)

        for key in TextKey.allCases {
            let inSpanish = spanish[key]?.components(separatedBy: "%@").count ?? 0
            let inEnglish = english[key]?.components(separatedBy: "%@").count ?? 0
            try expect(
                inSpanish == inEnglish,
                "\(key.rawValue) usa distinto número de %@ en cada idioma"
            )
        }
    }

    private static func testLanguageHasFlagAndNativeName() throws {
        for language in Language.allCases {
            try expect(!language.flag.isEmpty, "\(language.rawValue) necesita bandera")
            try expect(!language.nativeName.isEmpty, "\(language.rawValue) necesita nombre")
        }
        try expect(Language.allCases.count == 2, "hay dos idiomas: español e inglés")
    }
}
