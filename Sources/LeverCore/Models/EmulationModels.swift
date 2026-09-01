import Foundation

/// De qué generación es una máquina, que es lo que de verdad cambia lo que hace falta para
/// emularla: cuánta potencia, si lleva una o dos pantallas, y si hace falta una BIOS del aparato
/// original que Lever no puede darte.
public enum RetroArchitecture: String, Equatable, Sendable, CaseIterable {
    case bits8
    case bits16
    case bits32
    case bits64
    /// Consolas de dos pantallas y lápiz o dedo. La emulación va bien; lo que cambia es que hay
    /// que decidir cómo se apuntan dos pantallas en un Mac que solo tiene una.
    case dualScreen
    /// Las que no encajan en un número de bits: Dreamcast, PSP y compañía, con sus propios
    /// aceleradores y su propia manera de traducir el mando.
    case hybrid

    public var textKey: TextKey {
        switch self {
        case .bits8: return .archBits8
        case .bits16: return .archBits16
        case .bits32: return .archBits32
        case .bits64: return .archBits64
        case .dualScreen: return .archDualScreen
        case .hybrid: return .archHybrid
        }
    }
}

/// Una máquina que Lever sabe emular, con el núcleo de libretro que la ejecuta.
///
/// No es una lista de deseos: cada núcleo de aquí existe compilado para Apple silicon en el
/// servidor de libretro, que es de donde se baja. Comprobado uno a uno, no supuesto.
public struct RetroPlatform: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let architecture: RetroArchitecture
    /// Extensiones con las que suele venir. Es la primera pista, no la prueba: la prueba es la
    /// cabecera del archivo.
    public let extensions: [String]
    /// Núcleo de libretro que la ejecuta, sin el `_libretro.dylib` del final.
    public let core: String
    /// Otros núcleos que también valen. El primero es el que se usa; los demás se ofrecen porque
    /// para algunas máquinas la elección cambia mucho el resultado.
    public let alternativeCores: [String]
    /// Cuántas pantallas tiene el aparato de verdad.
    public let screens: Int
    /// Si se maneja tocando la pantalla. En un Mac eso acaba siendo el ratón, y hay que decirlo.
    public let hasTouch: Bool
    /// Archivos de BIOS que el núcleo exige y que **no** se pueden descargar: salen del aparato
    /// de cada uno. Sin ellos el núcleo arranca y se queda en negro, así que se avisa antes.
    public let requiredBios: [String]

    public init(
        id: String, name: String, architecture: RetroArchitecture, extensions: [String],
        core: String, alternativeCores: [String] = [], screens: Int = 1,
        hasTouch: Bool = false, requiredBios: [String] = []
    ) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.extensions = extensions
        self.core = core
        self.alternativeCores = alternativeCores
        self.screens = screens
        self.hasTouch = hasTouch
        self.requiredBios = requiredBios
    }

    /// Nombre del archivo del núcleo tal como lo publica libretro.
    public var coreFileName: String { "\(core)_libretro.dylib" }

    public var needsBios: Bool { !requiredBios.isEmpty }
}

/// Las máquinas contempladas, por generación.
///
/// La lista es corta a propósito: cada una está aquí porque su núcleo existe para Apple silicon
/// y porque se sabe reconocer su ROM. Añadir una es añadir una fila y su forma de reconocerse.
public enum RetroPlatforms {
    public static let all: [RetroPlatform] = [
        // ── 8 bits ──────────────────────────────────────────────────────────
        RetroPlatform(
            id: "nes", name: "NES / Famicom", architecture: .bits8,
            extensions: ["nes", "fds", "unf", "unif"],
            core: "nestopia", alternativeCores: ["mesen", "fceumm", "quicknes"]
        ),
        RetroPlatform(
            id: "gb", name: "Game Boy / Color", architecture: .bits8,
            extensions: ["gb", "gbc", "dmg"],
            core: "gambatte", alternativeCores: ["sameboy", "mgba"]
        ),
        RetroPlatform(
            id: "sms", name: "Master System / Game Gear", architecture: .bits8,
            extensions: ["sms", "gg"],
            core: "genesis_plus_gx", alternativeCores: ["picodrive", "smsplus"]
        ),
        // ── 16 bits ─────────────────────────────────────────────────────────
        RetroPlatform(
            id: "snes", name: "Super Nintendo", architecture: .bits16,
            extensions: ["sfc", "smc", "swc", "fig"],
            core: "snes9x", alternativeCores: ["bsnes_mercury_balanced", "mesen_s"]
        ),
        RetroPlatform(
            id: "megadrive", name: "Mega Drive / Genesis", architecture: .bits16,
            extensions: ["md", "gen", "smd", "bin"],
            core: "genesis_plus_gx", alternativeCores: ["picodrive", "blastem"]
        ),
        // ── 32 bits ─────────────────────────────────────────────────────────
        RetroPlatform(
            id: "gba", name: "Game Boy Advance", architecture: .bits32,
            extensions: ["gba", "agb"],
            core: "mgba", alternativeCores: ["vbam", "gpsp"]
        ),
        RetroPlatform(
            id: "psx", name: "PlayStation", architecture: .bits32,
            extensions: ["cue", "pbp", "chd", "m3u", "ccd"],
            core: "swanstation", alternativeCores: ["mednafen_psx_hw", "pcsx_rearmed"],
            // La BIOS de PlayStation no se distribuye: sale de una consola de verdad.
            requiredBios: ["scph5501.bin", "scph5500.bin", "scph5502.bin"]
        ),
        // ── 64 bits ─────────────────────────────────────────────────────────
        RetroPlatform(
            id: "n64", name: "Nintendo 64", architecture: .bits64,
            extensions: ["n64", "z64", "v64"],
            core: "mupen64plus_next", alternativeCores: ["parallel_n64"]
        ),
        // ── Dos pantallas y táctil ──────────────────────────────────────────
        RetroPlatform(
            id: "nds", name: "Nintendo DS", architecture: .dualScreen,
            extensions: ["nds", "dsi"],
            core: "melonds", alternativeCores: ["desmume", "melondsds"],
            screens: 2, hasTouch: true
        ),
        RetroPlatform(
            id: "3ds", name: "Nintendo 3DS", architecture: .dualScreen,
            extensions: ["3ds", "cci", "cxi", "3dsx"],
            core: "azahar", alternativeCores: ["citra"],
            screens: 2, hasTouch: true
        ),
        // ── Híbridas ────────────────────────────────────────────────────────
        RetroPlatform(
            id: "dreamcast", name: "Dreamcast", architecture: .hybrid,
            extensions: ["gdi", "cdi", "chd"],
            core: "flycast",
            requiredBios: ["dc_boot.bin", "dc_flash.bin"]
        ),
        RetroPlatform(
            id: "psp", name: "PSP", architecture: .hybrid,
            extensions: ["iso", "cso", "pbp"],
            core: "ppsspp"
        )
    ]

    public static func platform(id: String) -> RetroPlatform? {
        all.first { $0.id == id }
    }

    /// Las que podrían corresponder a una extensión. Son varias a menudo —`.bin` y `.chd` los usa
    /// media docena de máquinas—, y por eso la extensión sola no decide nada.
    public static func candidates(forExtension ext: String) -> [RetroPlatform] {
        let buscada = ext.lowercased()
        return all.filter { $0.extensions.contains(buscada) }
    }
}

/// Lo que se ha averiguado de un archivo de juego. Como en el resto del proyecto: solo hechos.
public struct RomFacts: Equatable, Sendable {
    /// La máquina reconocida, o `nil` si el archivo no se dejó identificar.
    public let platform: RetroPlatform?
    /// Cómo se reconoció. Importa para saber cuánto fiarse.
    public let evidence: RomEvidence
    /// El nombre interno que la ROM lleva escrito en su cabecera, cuando lo lleva. No es el nombre
    /// del archivo: es el que le puso quien la hizo.
    public let internalName: String?
    public let bytes: Int64

    public init(
        platform: RetroPlatform? = nil, evidence: RomEvidence = .none,
        internalName: String? = nil, bytes: Int64 = 0
    ) {
        self.platform = platform
        self.evidence = evidence
        self.internalName = internalName
        self.bytes = bytes
    }

    public var isRecognised: Bool { platform != nil }
}

/// Con qué seguridad se sabe qué es un archivo.
public enum RomEvidence: Equatable, Sendable {
    /// La cabecera del archivo lo dice. Es la buena: no depende de cómo se llame el archivo.
    case header
    /// Solo la extensión, porque esa máquina no marca sus ROMs de ninguna forma reconocible.
    /// Se acepta, pero se dice, porque un archivo mal nombrado se va a colar.
    case fileExtension
    /// No se pudo identificar.
    case none

    public var textKey: TextKey {
        switch self {
        case .header: return .romEvidenceHeader
        case .fileExtension: return .romEvidenceExtension
        case .none: return .romEvidenceNone
        }
    }
}
