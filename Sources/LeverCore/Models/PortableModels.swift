import Foundation

/// Un `.exe` que en realidad es un envoltorio: el juego viaja en datos que no dependen de Windows,
/// y el motor que los lee existe compilado para Mac.
///
/// Es la idea que hace posible saltarse Wine. Dos condiciones tienen que darse a la vez: que los
/// datos no estén cocinados para Windows —Unreal los cocina, por eso queda fuera— y que el motor
/// de macOS se pueda descargar en público —Unity no lo publica suelto, por eso también queda fuera.
public enum PortableEngine: Equatable, Sendable {
    case godot(GodotGame)
    case renpy(RenpyGame)
    case love(LoveGame)

    /// Nombre y versión, para el título del panel: «Godot 4.6.2», «Ren'Py 8.6.0».
    public var displayName: String {
        switch self {
        case .godot(let game): return "Godot \(game.version)"
        case .renpy(let game): return "Ren'Py \(game.version)"
        case .love(let game): return "LÖVE \(game.version)"
        }
    }

    /// Explicación de por qué este motor concreto se puede trasladar.
    public var bodyKey: TextKey {
        switch self {
        case .godot: return .portableBodyGodot
        case .renpy: return .portableBodyRenpy
        case .love: return .portableBodyLove
        }
    }

    /// `false` cuando se reconoce el motor pero esa versión no está contemplada. Se detecta igual
    /// para poder decirlo con claridad en vez de fallar a mitad del traslado.
    public var isSupported: Bool {
        switch self {
        case .godot(let game): return game.isSupported
        case .renpy(let game): return game.isSupported
        case .love(let game): return game.isSupported
        }
    }

    public var unsupportedKey: TextKey {
        switch self {
        case .godot: return .portableUnsupportedGodot
        case .renpy: return .portableUnsupportedRenpy
        case .love: return .portableUnsupportedLove
        }
    }

    /// Advertencia extra propia de este motor, si la hay.
    public var extraNoteKey: TextKey? {
        switch self {
        case .godot: return nil
        case .renpy(let game): return game.needsRosetta ? .portableRosettaNote : nil
        case .love(let game): return game.needsRosetta ? .portableRosettaNote : nil
        }
    }

    public var suggestedAppName: String {
        switch self {
        case .godot(let game): return game.suggestedAppName
        case .renpy(let game): return game.suggestedAppName
        case .love(let game): return game.suggestedAppName
        }
    }

    /// Partes nativas que se quedarán sin su versión de macOS si no se hace nada.
    public var unresolvedParts: [String] {
        switch self {
        case .godot(let game): return game.unresolvedExtensions.map(\.addonName)
        case .renpy: return []   // Ren'Py es Python puro: no hay nada nativo del juego que falte.
        // Módulos de Lua compilados que el juego trae para Windows. Nadie publica la versión de
        // macOS de un `.dll` suelto: se nombran para que se sepa qué parte del juego fallará.
        case .love(let game): return game.windowsLibraries
        }
    }

    /// Motor ya descargado de una vez anterior: no habrá espera.
    public func runtimeIsCached(in library: PortLibrary) -> Bool {
        switch self {
        case .godot(let game): return library.hasTemplate(for: game.version)
        case .renpy(let game): return library.hasRenpyRuntime(version: game.sdkVersion)
        case .love(let game): return library.hasLoveRuntime(version: game.version)
        }
    }

    /// Versión que hay que descargar, para poder decirla antes de empezar.
    public var runtimeVersionText: String {
        switch self {
        case .godot(let game): return game.version.description
        case .renpy(let game): return game.sdkVersion
        case .love(let game): return game.version
        }
    }

    /// Cuánto pesa la descarga del motor, redondeado y en texto, para avisar por adelantado.
    public var runtimeDownloadSize: String {
        switch self {
        case .godot: return "1,3 GB"
        case .renpy: return "160 MB"
        case .love(let game): return game.engineVersion.major >= 11 ? "10 MB" : "5 MB"
        }
    }

    public func requiredBytes(cached: Bool, buildingParts: Bool) -> Int64 {
        switch self {
        case .godot(let game):
            return GodotPorter.requiredBytes(for: game, hasTemplate: cached, buildingExtensions: buildingParts)
        case .renpy:
            return cached ? 400_000_000 : 1_200_000_000
        // El `.love` se copia entero fuera del `.exe`, así que su tamaño se sabe exacto y no hay
        // que estimarlo. Lo demás es el motor: veinticinco megas descomprimido.
        case .love(let game):
            return game.payloadBytes + (cached ? 60_000_000 : 120_000_000)
        }
    }
}

/// Resultado de un traslado terminado.
public struct PortOutcome: Sendable {
    /// El `.app` recién creado.
    public let app: URL
    /// Partes nativas que se han quedado sin su versión de macOS. El juego arrancará, pero fallará
    /// en lo que dependa de ellas: conviene decirlo, no esconderlo.
    public let unresolvedParts: [String]

    public init(app: URL, unresolvedParts: [String]) {
        self.app = app
        self.unresolvedParts = unresolvedParts
    }
}

/// Pasos del traslado, en el orden en que ocurren. Se enseñan de uno en uno porque el primero
/// puede tardar varios minutos y un mensaje fijo parecería que se ha colgado.
public enum PortStage: Equatable, Sendable {
    case reading
    case downloadingRuntime(String)
    case unpackingRuntime
    case buildingPart(String)
    case assembling
    case signing

    public var textKey: TextKey {
        switch self {
        case .reading: return .portStageReading
        case .downloadingRuntime: return .portStageDownloading
        case .unpackingRuntime: return .portStageUnpacking
        case .buildingPart: return .portStageBuilding
        case .assembling: return .portStageAssembling
        case .signing: return .portStageSigning
        }
    }
}

/// Motivos por los que el traslado no puede empezar o no puede terminar.
public enum PortFailure: Error, Equatable, Sendable {
    case unsupportedEngine(String)
    case notEnoughSpace(needed: Int64)
    case downloadFailed(Int32)
    case runtimeMissing
    case assemblyFailed(String)
    case cancelled

    public var textKey: TextKey {
        switch self {
        case .unsupportedEngine: return .errPortEngine
        case .notEnoughSpace: return .errPortNoSpace
        case .downloadFailed: return .errPortDownload
        case .runtimeMissing: return .errPortRuntime
        case .assemblyFailed: return .errPortAssembly
        case .cancelled: return .statusStopped
        }
    }
}

/// Reconoce el motor de un `.exe`, sea cual sea.
///
/// El orden importa poco porque las señales no se solapan: Godot se reconoce por el paquete
/// `GDPC`, Ren'Py por tener a la vez las carpetas `renpy/` y `game/`, y LÖVE por la `love.dll`
/// más un ZIP con `main.lua` dentro.
public enum PortableEngineDetector {
    public static func detect(
        program: URL,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default
    ) -> PortableEngine? {
        if let game = GodotInspector.inspect(program: program, library: library, fileManager: fileManager) {
            return .godot(game)
        }
        if let game = RenpyInspector.inspect(program: program, fileManager: fileManager) {
            return .renpy(game)
        }
        if let game = LoveInspector.inspect(program: program, fileManager: fileManager) {
            return .love(game)
        }
        return nil
    }
}
