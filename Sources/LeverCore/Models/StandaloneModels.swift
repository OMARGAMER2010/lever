import Foundation

/// Qué es un contenido: el juego, un parche o algo añadido.
///
/// El mismo vocabulario para todas las máquinas, aunque cada una lo diga a su manera. La consola
/// híbrida lo lleva escrito en los últimos tres dígitos del identificador; la familia PlayStation,
/// en un campo `CATEGORY` de dos letras. Son dos formas de averiguar lo mismo, y la interfaz lo
/// enseña igual en los dos casos.
public enum ContentKind: String, Equatable, Sendable, CaseIterable {
    /// El juego.
    case application
    /// Una actualización de un juego que ya tienes.
    case patch
    /// Contenido descargable.
    case addOn
    /// Algo que no es ninguna de las tres: una aplicación del sistema, datos guardados, un tema.
    case other

    public var textKey: TextKey {
        switch self {
        case .application: return .contentKindApplication
        case .patch: return .contentKindPatch
        case .addOn: return .contentKindAddOn
        case .other: return .contentKindOther
        }
    }
}

/// Cuánto se puede esperar de emular una máquina hoy.
///
/// Está aquí y no en un comentario porque es un **hecho que hay que enseñar**. La diferencia entre
/// una PS2 y una PS3 en un Mac no es de grado: una se juega y la otra arranca a veces. Callarlo
/// deja al usuario creyendo que ha hecho algo mal cuando lo que pasa es que eso todavía no va.
public enum EmulationMaturity: String, Equatable, Sendable, CaseIterable {
    /// Se juega. Puede haber juegos sueltos que fallen, pero la máquina va.
    case solid
    /// Arranca, a ratos, y depende mucho del juego. Vale la pena probar y no vale la pena
    /// prometer.
    case experimental
    /// **No existe emulador.** No es que Lever no lo traiga: es que no lo hay. Y lo que se anuncia
    /// por ahí como tal no es un emulador.
    case none

    public var textKey: TextKey {
        switch self {
        case .solid: return .maturitySolid
        case .experimental: return .maturityExperimental
        case .none: return .maturityNone
        }
    }
}

/// De dónde sale lo que el emulador necesita y Lever no puede darte.
///
/// La distinción importa y hasta ahora no existía en el código. La BIOS de una PS2 sale de una PS2:
/// no hay descarga legítima, y ofrecer una sería mentir. El firmware de una PS3 **lo publica Sony
/// en su web**, para cualquiera, y el emulador lo pide expresamente: ahí sí hay algo que decir, y
/// tratarlo como si fuera lo mismo que la BIOS deja al usuario atascado sin motivo.
public enum FirmwareSource: Equatable, Sendable {
    /// Sale del aparato de cada uno. No hay descarga.
    case console
    /// Lo publica el fabricante, y se puede ir a por él.
    case vendor(String)

    public var textKey: TextKey {
        switch self {
        case .console: return .firmwareFromConsole
        case .vendor: return .firmwareFromVendor
        }
    }
}

/// Lo que hace falta tener antes de que nada arranque.
public struct FirmwareNeed: Equatable, Sendable {
    /// Cómo se llaman los archivos, para poder decirlo con nombre y apellidos.
    public let files: [String]
    public let source: FirmwareSource

    public init(files: [String], source: FirmwareSource) {
        self.files = files
        self.source = source
    }
}

/// Un emulador instalado en el Mac, sea de la consola que sea.
///
/// Se describe por el nombre de su `.app` y por dónde guarda lo suyo. **No hay ninguna dirección de
/// descarga en ninguno**, y eso es una decisión: estos programas cambian de nombre, se bifurcan y
/// cierran —los dos de la consola híbrida cerraron en 2024— y una dirección fija en el código
/// apunta a un enlace roto en unos meses. Lever busca el que haya, igual que con Wine y RetroArch.
public struct StandaloneEmulator: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Nombres del `.app`, en orden de preferencia.
    public let bundleNames: [String]
    /// Carpeta de datos dentro de `Application Support`, que es donde espera lo suyo: las llaves de
    /// la consola híbrida, la BIOS de una PS2, el firmware de una PS3.
    public let dataFolder: String

    public init(id: String, name: String, bundleNames: [String], dataFolder: String) {
        self.id = id
        self.name = name
        self.bundleNames = bundleNames
        self.dataFolder = dataFolder
    }

    /// Donde este emulador guarda lo suyo.
    public func dataURL(fileManager: FileManager = .default) -> URL {
        let soporte = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return soporte.appendingPathComponent(dataFolder, isDirectory: true)
    }
}

/// Una máquina que **no** emula ningún núcleo de libretro.
///
/// Es la otra mitad del modelo, la que abrió la consola híbrida. `RetroPlatform` significa «máquina
/// que RetroArch ejecuta con un núcleo»; esto significa «máquina que ejecuta un programa entero
/// aparte, que instala el usuario». De la PS2 para arriba no hay núcleo que valga, y con la familia
/// Xbox va a pasar lo mismo.
public struct StandaloneMachine: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// A qué familia pertenece, para poder agruparlas al enseñarlas.
    public let family: String
    public let maturity: EmulationMaturity
    /// Los emuladores que la ejecutan en un Mac, de más recomendable a menos. Vacío cuando no hay
    /// ninguno, que es un caso real y no un descuido.
    public let emulators: [StandaloneEmulator]
    /// Extensiones con las que suele venir. Como siempre: una pista, no una prueba.
    public let extensions: [String]
    public let firmware: FirmwareNeed?
    /// Si el juego es una **carpeta** y no un archivo.
    ///
    /// Es lo que rompe el gesto de siempre. Un juego de PS3 o de PS4 volcado de su disco es un
    /// árbol de carpetas con un ejecutable dentro, no un archivo que se pueda arrastrar. Hay que
    /// aceptar carpetas o esas dos máquinas no entran por la puerta.
    public let contentIsFolder: Bool

    public init(
        id: String, name: String, family: String, maturity: EmulationMaturity,
        emulators: [StandaloneEmulator] = [], extensions: [String] = [],
        firmware: FirmwareNeed? = nil, contentIsFolder: Bool = false
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.maturity = maturity
        self.emulators = emulators
        self.extensions = extensions
        self.firmware = firmware
        self.contentIsFolder = contentIsFolder
    }

    public var isEmulated: Bool { maturity != .none }
    public var needsFirmware: Bool { firmware != nil }
}

/// Las máquinas que ejecuta un programa aparte.
///
/// La lista dice también lo que **no** se puede, y eso no es relleno: alguien que llega con un
/// juego de PS5 merece que se le diga que no existe ningún emulador, en vez de que su archivo
/// desaparezca sin comentarios. Lo que circula anunciado como emulador de PS5 no lo es.
public enum StandaloneMachines {
    /// Los emuladores de la consola híbrida. Los dos últimos están muertos y se buscan igual:
    /// mucha gente los tiene instalados de antes y siguen abriendo los juegos que abrían.
    static let hybridEmulators: [StandaloneEmulator] = [
        StandaloneEmulator(id: "ryujinx", name: "Ryujinx",
                           bundleNames: ["Ryujinx.app", "Ryubing.app"], dataFolder: "Ryujinx"),
        StandaloneEmulator(id: "sudachi", name: "Sudachi",
                           bundleNames: ["Sudachi.app", "sudachi.app"], dataFolder: "sudachi"),
        StandaloneEmulator(id: "citron", name: "Citron",
                           bundleNames: ["Citron.app", "citron.app"], dataFolder: "citron"),
        StandaloneEmulator(id: "eden", name: "Eden",
                           bundleNames: ["Eden.app", "eden.app"], dataFolder: "eden"),
        StandaloneEmulator(id: "yuzu", name: "yuzu",
                           bundleNames: ["yuzu.app"], dataFolder: "yuzu")
    ]

    public static let all: [StandaloneMachine] = [
        StandaloneMachine(
            id: "switch", name: "Switch", family: "nintendo", maturity: .experimental,
            emulators: hybridEmulators,
            extensions: SwitchContainer.allCases.map(\.fileExtension),
            firmware: FirmwareNeed(files: ["prod.keys"], source: .console)
        ),

        // ── La familia PlayStation ───────────────────────────────────────────
        // La 1 y la PSP no están aquí: esas sí las ejecuta un núcleo de libretro y ya funcionan
        // desde la pestaña de siempre. Repetirlas aquí sería ofrecer dos caminos para lo mismo.
        StandaloneMachine(
            id: "ps2", name: "PlayStation 2", family: "playstation", maturity: .solid,
            emulators: [StandaloneEmulator(id: "pcsx2", name: "PCSX2",
                                           bundleNames: ["PCSX2.app", "PCSX2-Qt.app"], dataFolder: "PCSX2")],
            extensions: ["iso", "bin", "chd", "cso", "gz", "mdf", "nrg", "img"],
            // La BIOS de una PS2 sale de una PS2. No hay descarga y el emulador no arranca sin ella.
            firmware: FirmwareNeed(files: ["SCPH-*.bin"], source: .console)
        ),
        StandaloneMachine(
            id: "ps3", name: "PlayStation 3", family: "playstation", maturity: .experimental,
            emulators: [StandaloneEmulator(id: "rpcs3", name: "RPCS3",
                                           bundleNames: ["RPCS3.app"], dataFolder: "rpcs3")],
            extensions: ["pkg", "iso", "self", "bin"],
            // **Este sí se descarga.** Lo publica Sony para cualquiera, y el emulador lo pide por
            // su nombre. Tratarlo como la BIOS de la PS2 dejaría al usuario atascado sin motivo.
            firmware: FirmwareNeed(files: ["PS3UPDAT.PUP"],
                                   source: .vendor("https://www.playstation.com/support/hardware/ps3/system-software/")),
            contentIsFolder: true
        ),
        StandaloneMachine(
            id: "ps4", name: "PlayStation 4", family: "playstation", maturity: .experimental,
            emulators: [StandaloneEmulator(id: "shadps4", name: "shadPS4",
                                           bundleNames: ["shadPS4.app"], dataFolder: "shadPS4")],
            extensions: ["pkg", "bin", "elf"],
            contentIsFolder: true
        ),
        StandaloneMachine(
            id: "vita", name: "PlayStation Vita", family: "playstation", maturity: .experimental,
            emulators: [StandaloneEmulator(id: "vita3k", name: "Vita3K",
                                           bundleNames: ["Vita3K.app"], dataFolder: "Vita3K")],
            extensions: ["vpk", "pkg"],
            contentIsFolder: true
        ),
        StandaloneMachine(
            id: "ps5", name: "PlayStation 5", family: "playstation", maturity: .none,
            // Sin emuladores y sin extensiones propias a propósito. Está en la lista para poder
            // **decir que no existe** cuando alguien traiga un juego suyo, no para ofrecer nada.
            extensions: []
        )
    ]

    public static func machine(id: String) -> StandaloneMachine? {
        all.first { $0.id == id }
    }

    public static func candidates(forExtension ext: String) -> [StandaloneMachine] {
        let buscada = ext.lowercased()
        return all.filter { $0.extensions.contains(buscada) }
    }

    /// Todas las extensiones que hay que dejar entrar por la pestaña de consolas.
    public static var allExtensions: [String] {
        Array(Set(all.flatMap(\.extensions))).sorted()
    }
}
