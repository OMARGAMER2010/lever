import Foundation

/// El envoltorio con el que circula un juego de la consola híbrida.
///
/// Cuatro nombres para dos decisiones. La primera es de dónde salió: un `.xci` es la copia de un
/// cartucho entero —con su partición de actualización y el hueco vacío que le sobra al plástico— y
/// un `.nsp` es lo que la consola se baja de la tienda, que es solo el contenido. La segunda es si
/// alguien lo pasó por el compresor: `.nsz` y `.xcz` son exactamente lo mismo con las piezas
/// grandes encogidas, y por eso comparten el árbol de archivos con sus originales.
///
/// **La extensión no decide.** Por dentro un `.nsp` y un `.nsz` son el mismo archivo de
/// particiones: lo que los separa es que en el comprimido las piezas se llaman `.ncz` en vez de
/// `.nca`. Un archivo renombrado se descubre solo, sin que haya que fiarse del nombre.
public enum SwitchContainer: String, Equatable, Sendable, CaseIterable {
    /// Paquete de la tienda: una sola partición con todo dentro.
    case nsp
    /// El mismo paquete con las piezas comprimidas.
    case nsz
    /// Copia de un cartucho: varias particiones, uno o dos gigas de hueco vacío al final.
    case xci
    /// El mismo cartucho con las piezas comprimidas.
    case xcz

    /// Si las piezas de dentro están encogidas y hay que rehacerlas antes de jugar.
    public var isCompressed: Bool { self == .nsz || self == .xcz }

    /// Si viene de un cartucho. Cambia dónde hay que mirar: en un cartucho el contenido está en la
    /// partición `secure`, no en la raíz.
    public var isCartridge: Bool { self == .xci || self == .xcz }

    /// El mismo envoltorio ya descomprimido, que es lo que hay que escribir al rehacerlo.
    public var decompressed: SwitchContainer {
        switch self {
        case .nsz: return .nsp
        case .xcz: return .xci
        default: return self
        }
    }

    public var fileExtension: String { rawValue }
}

/// Qué es un contenido dentro del paquete, con el vocabulario común de `ContentKind`.
///
/// No hace falta descifrar nada para saberlo: va escrito en el propio identificador del título.
/// Nintendo reservó los últimos tres dígitos para esto y todas las herramientas del mundo lo leen
/// igual, así que es un hecho, no una suposición. La familia PlayStation llega a lo mismo por otro
/// camino —un campo de dos letras— y por eso el vocabulario es compartido.
public typealias SwitchContentKind = ContentKind

/// Un contenido concreto de los que vienen dentro del archivo.
///
/// Un `.nsp` puede traer el juego solo, o el juego con tres actualizaciones y ocho DLC metidos en
/// el mismo paquete. Enseñar «un archivo» sería mentir: son varias cosas y cada una tiene su
/// identificador y su versión.
public struct SwitchTitle: Equatable, Sendable, Identifiable {
    /// Los dieciséis dígitos que identifican el contenido. Es la identidad de verdad: el nombre
    /// del archivo lo pone quien lo comparte y no significa nada.
    public let titleId: UInt64
    /// El identificador del juego al que pertenece. Para el juego es el suyo; para un parche o un
    /// DLC es el del juego que parchean, que es lo que permite agruparlos.
    public let baseTitleId: UInt64
    public let kind: SwitchContentKind
    /// La versión, en el número que usa la consola: 65536 por cada versión de verdad.
    public let version: UInt32?
    /// Cuánto ocupa este contenido dentro del archivo, cuando se ha podido medir.
    public let bytes: Int64?

    public init(
        titleId: UInt64, baseTitleId: UInt64? = nil, kind: SwitchContentKind? = nil,
        version: UInt32? = nil, bytes: Int64? = nil
    ) {
        self.titleId = titleId
        self.kind = kind ?? SwitchTitle.kind(of: titleId)
        self.baseTitleId = baseTitleId ?? SwitchTitle.base(of: titleId)
        self.version = version
        self.bytes = bytes
    }

    public var id: UInt64 { titleId }

    /// Los dieciséis dígitos en mayúsculas, que es como los escriben la consola y todas las
    /// herramientas. Enseñarlos en minúsculas obliga al usuario a traducir mentalmente.
    public var formattedId: String { String(format: "%016llX", titleId) }

    /// La versión como la cuenta la gente. La consola guarda 65536 por versión: la 3 es 196608.
    public var displayVersion: String? {
        guard let version else { return nil }
        return "v\(version / 65536)"
    }

    /// De qué tipo es un identificador, por sus últimos tres dígitos.
    ///
    /// `…000` el juego, `…800` su actualización, y lo que quede es contenido añadido: los DLC se
    /// numeran a partir del juego más `0x1000`, uno detrás de otro.
    public static func kind(of titleId: UInt64) -> SwitchContentKind {
        switch titleId & 0xFFF {
        case 0x000 where titleId & 0x1000 == 0: return .application
        case 0x800: return .patch
        default: return .addOn
        }
    }

    /// El identificador del juego al que pertenece un contenido.
    public static func base(of titleId: UInt64) -> UInt64 {
        switch kind(of: titleId) {
        case .application: return titleId
        case .patch: return titleId & ~0xFFF
        // Los DLC empiezan un bloque de 0x1000 por encima del juego, así que hay que bajar ese
        // bloque además de redondear: sin restarlo, un DLC parecería ser de un juego que no existe.
        case .addOn: return (titleId & ~0xFFF) &- 0x1000
        // `kind(of:)` nunca devuelve esto para un identificador de esta consola: sus tres dígitos
        // finales siempre caen en uno de los tres casos. Está por el vocabulario compartido.
        case .other: return titleId
        }
    }
}

/// Con qué seguridad se sabe lo que hay dentro.
///
/// Mismo criterio que con las ROMs, pero aquí hay un escalón más: el paquete está cifrado, así que
/// hay cosas que solo se saben con las llaves del usuario delante. Decir cuál de los cuatro
/// niveles es evita la pregunta de «¿por qué no me sale el nombre del juego?».
public enum SwitchEvidence: Equatable, Sendable {
    /// La cabecera de la pieza, descifrada con las llaves. Es la buena: la escribió Nintendo.
    case ncaHeader
    /// El ticket que viaja en el paquete. Lleva el identificador del título sin cifrar.
    case ticket
    /// El `cnmt.xml` que acompaña a muchos volcados. Es fiable pero lo genera una herramienta, no
    /// la consola, así que puede faltar o estar mal.
    case metaXml
    /// Solo el árbol de archivos: se sabe que es un paquete válido y qué piezas trae, nada más.
    case container
    case none

    public var textKey: TextKey {
        switch self {
        case .ncaHeader: return .switchEvidenceNca
        case .ticket: return .switchEvidenceTicket
        case .metaXml: return .switchEvidenceXml
        case .container: return .switchEvidenceContainer
        case .none: return .romEvidenceNone
        }
    }
}

/// Si la copia de un cartucho trae dentro el firmware de la consola.
///
/// Un cartucho de verdad lleva tres particiones: `update`, `normal` y `secure`. En `secure` va el
/// juego —que es lo único que Lever necesitaba hasta ahora— y en `update` va la versión del sistema
/// con la que salió a la venta. Esa partición es firmware instalable: los emuladores saben sacarla
/// de un `.xci` y registrarla.
///
/// **Pero casi ningún volcado que circula la conserva.** Recortar un `.xci` —vaciar la partición de
/// actualización y quitar el hueco vacío del final— ahorra sitio y es lo que hace todo el mundo. El
/// archivo sigue siendo válido y el juego sigue entero, así que no hay forma de notarlo mirando el
/// juego.
///
/// Y tampoco basta con mirar si la partición sigue ahí: al recortar **no se borra**, se vacía. Lo
/// que queda es una cabecera `HFS0` legítima de 512 bytes con cero archivos dentro, que por tamaño
/// parece contenido. Solo contando lo que trae se distingue una cosa de la otra.
///
/// Merece la pena decirlo porque es la diferencia entre «tu emulador puede sacar el firmware de
/// aquí mismo» y «vas a tener que conseguirlo por tu cuenta», y esas dos son tardes distintas.
public enum CartridgeUpdate: Equatable, Sendable {
    /// Trae la partición de actualización con contenido: de ahí se puede instalar el firmware.
    case included(bytes: Int64)
    /// Volcado recortado. La partición está declarada pero vacía: no hay firmware que sacar.
    case trimmed

    public var hasFirmware: Bool {
        if case .included = self { return true }
        return false
    }

    public var textKey: TextKey {
        switch self {
        case .included: return .switchCartridgeFirmwareIncluded
        case .trimmed: return .switchCartridgeTrimmed
        }
    }
}

/// Una pieza de las que van dentro del paquete.
public struct SwitchEntry: Equatable, Sendable {
    public let name: String
    public let offset: Int64
    public let size: Int64

    public init(name: String, offset: Int64, size: Int64) {
        self.name = name
        self.offset = offset
        self.size = size
    }

    /// Si es una pieza comprimida por el compresor de la comunidad.
    public var isCompressedContent: Bool { name.lowercased().hasSuffix(".ncz") }
    /// Si es una pieza de contenido tal cual la escribe la consola.
    public var isContent: Bool { name.lowercased().hasSuffix(".nca") }
    /// Si es un ticket: lleva el identificador del título sin cifrar.
    public var isTicket: Bool { name.lowercased().hasSuffix(".tik") }
}

/// Lo que se ha averiguado de un archivo de la consola híbrida. Como en el resto del proyecto:
/// solo hechos, y con qué seguridad se saben.
public struct SwitchFacts: Equatable, Sendable {
    /// El envoltorio reconocido por lo que hay dentro, o `nil` si el archivo no lo es.
    public let container: SwitchContainer?
    public let evidence: SwitchEvidence
    /// Todo lo que trae, ya separado en juego, actualizaciones y añadidos.
    public let titles: [SwitchTitle]
    /// Las piezas del paquete, con dónde empieza cada una.
    public let entries: [SwitchEntry]
    public let bytes: Int64
    /// Llaves que hacen falta para saber más de lo que aquí se dice. Vacío cuando ya se sabe todo.
    public let missingKeys: [String]
    /// La generación de llaves con la que se cifró el contenido, cuando se ha podido leer.
    ///
    /// **Es el número que decide si un `prod.keys` sirve.** Uno de hace dos años abre los juegos de
    /// hace dos años y nada más; con un juego más nuevo el emulador no arranca y no dice por qué.
    /// Teniendo el número se puede avisar antes, que es la diferencia entre entender el problema y
    /// dar por hecho que el volcado está roto.
    public let requiredKeyGeneration: Int?
    /// La pieza que lleva el nombre y el icono del juego. La única de la que sale eso.
    public let controlContent: SwitchEntry?
    /// Si el cartucho trae el firmware dentro. `nil` cuando no es un cartucho: un paquete de la
    /// tienda no tiene partición de actualización y preguntarlo no significa nada.
    public let cartridgeUpdate: CartridgeUpdate?

    public init(
        container: SwitchContainer? = nil, evidence: SwitchEvidence = .none,
        titles: [SwitchTitle] = [], entries: [SwitchEntry] = [], bytes: Int64 = 0,
        missingKeys: [String] = [], requiredKeyGeneration: Int? = nil,
        controlContent: SwitchEntry? = nil, cartridgeUpdate: CartridgeUpdate? = nil
    ) {
        self.container = container
        self.evidence = evidence
        self.titles = titles
        self.entries = entries
        self.bytes = bytes
        self.missingKeys = missingKeys
        self.requiredKeyGeneration = requiredKeyGeneration
        self.controlContent = controlContent
        self.cartridgeUpdate = cartridgeUpdate
    }

    public var isRecognised: Bool { container != nil }

    /// El juego base, que es el que da nombre a todo el paquete.
    public var application: SwitchTitle? {
        titles.first { $0.kind == .application } ?? titles.first
    }

    public var patches: [SwitchTitle] { titles.filter { $0.kind == .patch } }
    public var addOns: [SwitchTitle] { titles.filter { $0.kind == .addOn } }

    /// Si las llaves que hay se quedan cortas para este juego.
    ///
    /// - Parameter available: cuántas generaciones trae el `prod.keys` del usuario.
    public func keysAreTooOld(available: Int) -> Bool {
        guard let requiredKeyGeneration, available > 0 else { return false }
        return requiredKeyGeneration >= available
    }

    /// Si hay que rehacer las piezas antes de poder jugar.
    public var needsDecompression: Bool {
        container?.isCompressed == true || entries.contains(where: \.isCompressedContent)
    }
}
