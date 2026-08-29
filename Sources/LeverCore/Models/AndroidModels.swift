import Foundation

/// Juegos de instrucciones que un `.apk` puede traer compilados y que un aparato puede ejecutar.
///
/// Se guardan como texto porque es lo que devuelven tanto el `.apk` (las carpetas `lib/<abi>/`)
/// como el aparato (`ro.product.cpu.abilist`). Convertirlos a un `enum` cerrado obligaría a
/// inventar un caso «otros» y a decidir por el usuario qué hacer con un ABI que no conocemos:
/// es preferible comparar las dos listas tal cual vienen.
public enum AndroidAbi {
    public static let arm64 = "arm64-v8a"
    public static let arm32 = "armeabi-v7a"
    public static let intel64 = "x86_64"
    public static let intel32 = "x86"

    /// Los cuatro que Android define hoy, en el orden en que se enseñan.
    public static let known = [arm64, arm32, intel64, intel32]
}

/// Lo que se ha leído del `.apk` abriéndolo. Solo hechos: nada deducido ni supuesto.
///
/// Un `.apk` es un `.zip` con un `AndroidManifest.xml` en formato binario dentro. Todo esto se
/// saca de esos dos sitios, sin herramientas externas —igual que la arquitectura de un `.exe`
/// se lee de su cabecera PE.
public struct ApkFacts: Equatable, Sendable {
    public let packageName: String?
    public let versionName: String?
    public let versionCode: Int?
    public let minSdk: Int?
    /// ABIs para los que el paquete trae código nativo. Vacío significa que no trae ninguno:
    /// entonces corre en cualquier aparato, porque todo es código de la máquina virtual.
    public let abis: [String]
    /// Un `.apk` sin `classes.dex` es un trozo de un App Bundle (un «split»), no una app entera.
    /// Instalarlo suelto falla siempre, así que conviene decirlo antes.
    public let isSplit: Bool
    /// En qué postura declara arrancar la actividad de inicio.
    public let orientation: ScreenOrientation
    /// El archivo no se pudo leer como `.apk`: ni zip válido, ni manifiesto dentro.
    public let readFailed: Bool

    public init(
        packageName: String? = nil,
        versionName: String? = nil,
        versionCode: Int? = nil,
        minSdk: Int? = nil,
        abis: [String] = [],
        isSplit: Bool = false,
        orientation: ScreenOrientation = .free,
        readFailed: Bool = false
    ) {
        self.packageName = packageName
        self.versionName = versionName
        self.versionCode = versionCode
        self.minSdk = minSdk
        self.abis = abis
        self.isSplit = isSplit
        self.orientation = orientation
        self.readFailed = readFailed
    }

    /// Sin código nativo, el ABI del aparato da igual.
    public var isPortable: Bool { abis.isEmpty }

    /// Se puede lanzar solo si sabemos a qué paquete llamar.
    public var canBeLaunched: Bool { packageName?.isEmpty == false }
}

/// En qué postura arranca una app, según lo que declara su manifiesto.
///
/// Ojo con lo que esto **no** dice: muchos juegos hechos con Unity o Unreal dejan
/// `screenOrientation` sin fijar y deciden la postura en marcha, desde su propio código. El
/// manifiesto es lo único que se puede leer sin ejecutar nada, así que `libre` significa «el
/// manifiesto no lo fija», no «la app girará». Por eso el conmutador manual existe.
public enum ScreenOrientation: Equatable, Sendable {
    case portrait
    case landscape
    /// El manifiesto no fija ninguna, o deja decidir al sensor o al usuario.
    case free

    /// Traduce el valor crudo de `android:screenOrientation`, que es un entero.
    ///
    /// Los valores son los de `ActivityInfo`: 0 apaisado, 1 vertical, y las variantes que fijan
    /// un eje aunque permitan las dos direcciones de ese eje (`sensorPortrait`, `userLandscape`…)
    /// cuentan como ese eje. El resto —`unspecified`, `sensor`, `user`, `fullSensor`, `locked`…—
    /// no fija nada.
    public static func fromManifest(_ raw: Int?) -> ScreenOrientation {
        switch raw {
        case 1, 7, 9, 12: return .portrait     // portrait, sensorPortrait, reversePortrait, userPortrait
        case 0, 6, 8, 11: return .landscape    // landscape, sensorLandscape, reverseLandscape, userLandscape
        default: return .free
        }
    }

    /// El giro que hay que pedirle al aparato. `user_rotation` cuenta en cuartos de vuelta desde
    /// la postura natural del aparato, que en un móvil o un emulador de móvil es la vertical.
    public var deviceRotation: Int? {
        switch self {
        case .portrait: return 0
        case .landscape: return 1
        case .free: return nil
        }
    }

    public var textKey: TextKey {
        switch self {
        case .portrait: return .orientationPortrait
        case .landscape: return .orientationLandscape
        case .free: return .orientationFree
        }
    }
}

/// Lo que el usuario ha elegido en el conmutador de la pestaña.
public enum RotationChoice: String, CaseIterable, Identifiable, Sendable {
    /// Hacer lo que diga el manifiesto del `.apk`, y si no dice nada, dejar girar al aparato.
    case automatic
    case portrait
    case landscape

    public var id: String { rawValue }

    public var textKey: TextKey {
        switch self {
        case .automatic: return .orientationAuto
        case .portrait: return .orientationPortrait
        case .landscape: return .orientationLandscape
        }
    }

    /// La postura que hay que aplicar de verdad. En automático manda el `.apk`.
    public func resolved(declaring declared: ScreenOrientation) -> ScreenOrientation {
        switch self {
        case .automatic: return declared
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}

/// Traduce el nivel de API que guarda un `.apk` al número de Android que la gente conoce.
///
/// Existe porque «API 26» no le dice nada a nadie y «Android 8.0» sí. La tabla es la lista
/// pública de Android y solo cubre lo que sigue vivo; para un nivel que no esté, se enseña el
/// número de API tal cual en vez de aproximar.
public enum AndroidRelease {
    private static let names: [Int: String] = [
        21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1",
        28: "9", 29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14",
        35: "15", 36: "16"
    ]

    public static func name(forApi api: Int) -> String? { names[api] }
}

/// Un aparato Android visible para `adb`: un emulador arrancado o un móvil enchufado.
public struct AndroidDevice: Identifiable, Equatable, Sendable {
    /// En qué situación lo ve `adb`. Solo `ready` admite instalaciones.
    public enum Availability: Equatable, Sendable {
        case ready
        /// Enchufado, pero el usuario todavía no ha aceptado la depuración USB en la pantalla.
        case unauthorized
        /// Visible pero sin responder: arrancando, o con el puente caído.
        case offline
    }

    public let serial: String
    public let availability: Availability
    public let model: String?
    /// Todos los ABIs que ejecuta, de `ro.product.cpu.abilist`.
    public let abis: [String]
    public let sdk: Int?
    public let release: String?

    public var id: String { serial }

    /// Los emuladores se identifican por el propio serie (`emulator-5554`).
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }

    public init(
        serial: String,
        availability: Availability,
        model: String? = nil,
        abis: [String] = [],
        sdk: Int? = nil,
        release: String? = nil
    ) {
        self.serial = serial
        self.availability = availability
        self.model = model
        self.abis = abis
        self.sdk = sdk
        self.release = release
    }

    /// Nombre para enseñar: el modelo si lo dio, y si no el serie, que siempre está.
    public var displayName: String {
        guard let model, !model.isEmpty else { return serial }
        return model.replacingOccurrences(of: "_", with: " ")
    }
}

/// Por qué un `.apk` no va a instalarse en el aparato elegido. Se calcula antes de intentarlo:
/// `adb` tarda en fallar y su mensaje (`INSTALL_FAILED_NO_MATCHING_ABIS`) no dice qué hacer.
public enum ApkCompatibility: Equatable, Sendable {
    case fits
    /// El paquete es un trozo de un App Bundle: no es instalable por sí solo.
    case isSplit
    /// Ningún ABI del paquete coincide con los del aparato.
    case abiMismatch(apk: [String], device: [String])
    /// El paquete pide una versión de Android más nueva que la del aparato.
    case sdkTooOld(needs: Int, has: Int)
    /// No hay datos suficientes para decidir; se deja intentar.
    case unknown

    public var blocks: Bool {
        switch self {
        case .fits, .unknown: return false
        case .isSplit, .abiMismatch, .sdkTooOld: return true
        }
    }

    /// Compara lo leído del archivo con lo que el aparato dice de sí mismo.
    public static func check(apk: ApkFacts, device: AndroidDevice?) -> ApkCompatibility {
        if apk.isSplit { return .isSplit }
        guard let device else { return .unknown }

        if let needs = apk.minSdk, let has = device.sdk, needs > has {
            return .sdkTooOld(needs: needs, has: has)
        }

        // Sin código nativo el paquete corre en cualquier ABI; y sin la lista del aparato no
        // hay nada que comparar, así que se deja probar en vez de bloquear por si acaso.
        guard !apk.isPortable, !device.abis.isEmpty else { return .fits }

        let shared = Set(apk.abis).intersection(device.abis)
        return shared.isEmpty ? .abiMismatch(apk: apk.abis, device: device.abis) : .fits
    }
}
