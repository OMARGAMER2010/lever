import Foundation
import LeverCore

enum EmulatorQualityTests {
    static func run() throws {
        try testEffectiveConfigurationUsesTheGamesOverride()
        try testHigherResolutionDoesNotRequireTheReductionPatch()
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        let original = Data(#"{"res_scale":1,"res_scale_custom":1,"scaling_filter":"Bilinear","input_config":[{"id":"physical"}],"future":{"keep":42},"docked_mode":false}"#.utf8)
        try original.write(to: archivo)
        try expect(EmulatorQuality.apply(.scale(.balanced), atConfig: archivo,
                                        supportsReduction: false) == .unsupportedScale,
                   "el motor original no recibe una reducción que puede cerrarlo")
        let rechazado = try Data(contentsOf: archivo)
        try expect(rechazado == original, "el rechazo no escribe")
        try expect(EmulatorQuality.apply(.scale(.balanced), atConfig: archivo,
                                        supportsReduction: true, isRunning: true) == .emulatorRunning,
                   "no se escribe mientras el emulador pueda sobreescribir la configuración")
        try expect(EmulatorQuality.apply(.scale(.balanced), atConfig: archivo,
                                        supportsReduction: true) == .applied, "se aplica el 75 % validado")
        var raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        try expect(raíz["res_scale"] as? Int == -1 && raíz["res_scale_custom"] as? Double == 0.75,
                   "las fracciones usan el campo personalizado de Ryujinx")
        try expect((raíz["future"] as? [String: Int])?["keep"] == 42
                   && (raíz["input_config"] as? [[String: String]])?.first?["id"] == "physical",
                   "cambiar calidad conserva controles y campos desconocidos")
        try expect(EmulatorQuality.apply(.filter(.fsr), atConfig: archivo,
                                        supportsReduction: true) == .applied, "el filtro se cambia aparte")
        raíz = try JSONSerialization.jsonObject(with: Data(contentsOf: archivo)) as! [String: Any]
        try expect(raíz["scaling_filter"] as? String == "Fsr" && raíz["res_scale_custom"] as? Double == 0.75,
                   "el filtro no cambia la resolución")
        try expect(EmulatorQuality.apply(.scale(.native), atConfig: archivo,
                                        supportsReduction: false) == .applied, "siempre se puede volver a escala nativa")
        try expect(EmulatorQuality.read(atConfig: archivo)?.scale == 1, "se lee la escala efectiva")
        let respaldo = archivo.appendingPathExtension("lever-before-quality.json")
        let copia = try Data(contentsOf: respaldo)
        try expect(copia == original, "el primer respaldo conserva los bytes originales")

        for inválido in [#"{"res_scale":true,"res_scale_custom":1,"scaling_filter":"Bilinear"}"#,
                         #"{"res_scale":0.75,"scaling_filter":"Bilinear"}"#,
                         #"{"res_scale":1.5,"scaling_filter":"Bilinear"}"#,
                         #"{"res_scale":-1,"res_scale_custom":false,"scaling_filter":"Bilinear"}"#,
                         #"{"res_scale":1}"#, "{broken"] {
            let datos = Data(inválido.utf8)
            try datos.write(to: archivo)
            try expect(EmulatorQuality.apply(.scale(.native), atConfig: archivo,
                                            supportsReduction: true) == .unreadableConfig,
                       "un formato desconocido no se reconstruye a ciegas")
            let conservado = try Data(contentsOf: archivo)
            try expect(conservado == datos, "se conserva el archivo inválido")
            try expect(EmulatorQuality.apply(.filter(.fsr), atConfig: archivo,
                                            supportsReduction: true) == .unreadableConfig,
                       "cambiar el filtro tampoco conserva una escala inválida")
        }
        try expect(!EmulatorQuality.supportsReduction(inside: sitio.directoryURL), "no se inventa una capacidad")
        let contents = sitio.directoryURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = contents.appendingPathComponent("Info.plist")
        for (marca, esperado) in [(1 as Any, true), (true as Any, false), (2 as Any, false)] {
            let datos = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "org.ryujinx.Ryujinx", "LeverTextureScaleGeometryVersion": marca
            ], format: .xml, options: 0)
            try datos.write(to: info)
            try expect(EmulatorQuality.supportsReduction(inside: sitio.directoryURL) == esperado,
                       "solo se reconoce la revisión de escalado implementada")
        }
    }

    private static func testHigherResolutionDoesNotRequireTheReductionPatch() throws {
        let sitio = try TemporaryFixture()
        let archivo = sitio.directoryURL.appendingPathComponent("Config.json")
        try Data(#"{"res_scale":1,"res_scale_custom":1,"scaling_filter":"Bilinear","input_config":[{"id":"physical"}]}"#.utf8).write(to: archivo)
        for valor in [1.5, 2.0] {
            guard let escala = EmulatorResolutionScale(rawValue: valor) else {
                throw TestFailure(description: "el selector debe ofrecer \(valor) × para equipos con más margen")
            }
            let antes = try Data(contentsOf: archivo)
            try expect(EmulatorQuality.apply(.scale(escala), atConfig: archivo,
                                            supportsReduction: false, isRunning: true) == .emulatorRunning,
                       "tampoco se aumenta la resolución con el juego abierto")
            let después = try Data(contentsOf: archivo)
            try expect(antes == después, "el rechazo conserva todos los bytes")
            try expect(EmulatorQuality.apply(.scale(escala), atConfig: archivo,
                                            supportsReduction: false) == .applied,
                       "aumentar la resolución no necesita el parche de reducción")
            try expect(EmulatorQuality.read(atConfig: archivo)?.scale == valor,
                       "la escala alta elegida se conserva al leerla")
        }
    }

    private static func testEffectiveConfigurationUsesTheGamesOverride() throws {
        let sitio = try TemporaryFixture()
        let global = sitio.directoryURL.appendingPathComponent("Config.json")
        let datosGlobales = Data(#"{"res_scale":1,"res_scale_custom":1,"scaling_filter":"Bilinear"}"#.utf8)
        try datosGlobales.write(to: global)
        let juego = "0100000000010000"
        try expect(EmulatorQuality.effectiveConfig(in: sitio.directoryURL, gameID: juego) == global,
                   "sin perfil propio se usa el global")
        let perfil = sitio.directoryURL.appendingPathComponent("games/\(juego)/Config.json")
        try FileManager.default.createDirectory(at: perfil.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"res_scale":-1,"res_scale_custom":0.75,"scaling_filter":"Fsr"}"#.utf8).write(to: perfil)
        let efectivo = EmulatorQuality.effectiveConfig(in: sitio.directoryURL, gameID: juego)
        try expect(efectivo == perfil && EmulatorQuality.read(atConfig: efectivo)?.scale == 0.75,
                   "el perfil propio gana igual que en Ryujinx")
        try expect(EmulatorQuality.apply(.scale(.native), atConfig: efectivo,
                                        supportsReduction: true) == .applied, "se modifica el perfil efectivo")
        let globalConservado = try Data(contentsOf: global)
        try expect(globalConservado == datosGlobales, "el global no se toca cuando existe un perfil")
        try Data("{broken".utf8).write(to: perfil)
        try expect(EmulatorQuality.effectiveConfig(in: sitio.directoryURL, gameID: juego) == perfil,
                   "un perfil ilegible no se oculta leyendo otro archivo")
        try expect(EmulatorQuality.effectiveConfig(in: sitio.directoryURL, gameID: "../../escape") == global,
                   "el identificador no puede salir de la carpeta de juegos")
    }
}
