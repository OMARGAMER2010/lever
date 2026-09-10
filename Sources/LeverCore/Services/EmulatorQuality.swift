import Foundation
import CoreFoundation

public enum EmulatorResolutionScale: Double, CaseIterable, Sendable {
    case performance = 0.5, balanced = 0.75, native = 1, oneAndHalf = 1.5, double = 2

    public var textKey: TextKey {
        switch self {
        case .native: return .switchQualityNative
        case .balanced: return .switchQualityBalanced
        case .performance: return .switchQualityPerformance
        case .oneAndHalf: return .switchQuality150
        case .double: return .switchQuality200
        }
    }
}

public enum EmulatorScalingFilter: String, CaseIterable, Sendable {
    case bilinear = "Bilinear", fsr = "Fsr"
}

public struct EmulatorQuality: Equatable, Sendable {
    public let scale: Double?
    public let filter: String?

    public enum Change: Sendable {
        case scale(EmulatorResolutionScale)
        case filter(EmulatorScalingFilter)
    }

    public enum UpdateResult: Equatable, Sendable {
        case applied, emulatorRunning, unsupportedScale, unreadableConfig, writeFailed
    }

    public static func effectiveConfig(in dataDirectory: URL, gameID: String?,
                                       fileManager: FileManager = .default) -> URL {
        if let gameID, gameID.utf8.count == 16,
           gameID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            let propio = dataDirectory.appendingPathComponent("games")
                .appendingPathComponent(gameID.lowercased()).appendingPathComponent("Config.json")
            // Ryujinx da prioridad al perfil completo del juego. Si no se puede leer,
            // devolver ese archivo permite explicar el problema sin mostrar otro valor.
            if fileManager.fileExists(atPath: propio.path) { return propio }
        }
        return dataDirectory.appendingPathComponent("Config.json")
    }

    public static func supportsReduction(inside app: URL) -> Bool {
        let archivo = app.appendingPathComponent("Contents/Info.plist")
        guard let datos = try? Data(contentsOf: archivo),
              let raíz = try? PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any],
              raíz["CFBundleIdentifier"] as? String == "org.ryujinx.Ryujinx",
              let revisión = raíz["LeverTextureScaleGeometryVersion"] as? NSNumber,
              CFGetTypeID(revisión) != CFBooleanGetTypeID() else { return false }
        return revisión.doubleValue == 1
    }

    public static func apply(_ change: Change, atConfig url: URL,
                             supportsReduction: Bool, isRunning: Bool = false) -> UpdateResult {
        guard !isRunning else { return .emulatorRunning }
        if case let .scale(escala) = change, escala.rawValue < 1, !supportsReduction {
            return .unsupportedScale
        }
        guard let datos = try? Data(contentsOf: url),
              var raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              read(root: raíz).scale != nil, raíz["scaling_filter"] is String else {
            return .unreadableConfig
        }
        switch change {
        case let .scale(escala):
            // Ryujinx reserva -1 para el valor fraccionario; escribir 0.75 en res_scale
            // rompería su deserialización porque ese campo es entero.
            raíz["res_scale"] = escala == .native ? 1 : -1
            raíz["res_scale_custom"] = escala.rawValue
        case let .filter(filtro): raíz["scaling_filter"] = filtro.rawValue
        }
        guard let salida = try? JSONSerialization.data(withJSONObject: raíz, options: [.prettyPrinted, .sortedKeys])
        else { return .writeFailed }
        let respaldo = url.appendingPathExtension("lever-before-quality.json")
        do {
            // Conservar una sola copia inicial evita convertir cambios sucesivos en el
            // supuesto original. La escritura atómica deja siempre un JSON completo.
            if !FileManager.default.fileExists(atPath: respaldo.path) {
                try datos.write(to: respaldo, options: .withoutOverwriting)
            }
            try salida.write(to: url, options: .atomic)
            return .applied
        } catch { return .writeFailed }
    }

    public static func read(atConfig url: URL) -> EmulatorQuality? {
        guard let datos = try? Data(contentsOf: url),
              let raíz = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { return nil }
        return read(root: raíz)
    }

    public static func read(root: [String: Any]) -> EmulatorQuality {
        func número(_ clave: String) -> Double? {
            guard let valor = root[clave] as? NSNumber,
                  CFGetTypeID(valor) != CFBooleanGetTypeID(), valor.doubleValue.isFinite else { return nil }
            return valor.doubleValue
        }
        let base = número("res_scale").flatMap { valor -> Double? in
            guard valor.rounded() == valor, valor >= -1, valor <= Double(Int32.max) else { return nil }
            return valor
        }
        let escala = base == -1 ? número("res_scale_custom") : base
        return EmulatorQuality(scale: escala.flatMap { $0 > 0 && $0 <= Double(Float.greatestFiniteMagnitude) ? $0 : nil },
                               filter: root["scaling_filter"] as? String)
    }
}
