import Foundation

/// En qué formato llega una app de Android.
///
/// Un `.apk` es la app entera y se instala tal cual. Los otros tres son envoltorios: dentro hay
/// varios `.apk` que solo valen juntos, porque Google partió las apps en trozos —uno por
/// procesador, uno por densidad de pantalla, uno por idioma— y el aparato recibe solo los suyos.
/// Ese reparto lo hacía Play; fuera de Play hay que rehacerlo a mano, y eso es lo que falta aquí.
public enum AndroidPackageKind: String, Equatable, Sendable, CaseIterable {
    /// Una app entera, o un trozo suelto que no se puede instalar solo.
    case apk
    /// Lo que reparte APKPure: un ZIP con `base.apk`, sus `config.*.apk`, un `manifest.json`
    /// y a veces los `.obb` bajo `Android/obb/<paquete>/`.
    case xapk
    /// Lo que produce `bundletool build-apks`: un ZIP con `splits/` o `standalones/` y un
    /// `toc.pb` que dice qué trozo es para qué aparato.
    case apks
    /// El App Bundle que sube el desarrollador a Play. **No es instalable**: hay que generar
    /// los `.apk` a partir de él.
    case aab

    /// A partir de la extensión del archivo. `.apkm` es el envoltorio de APKMirror, que por
    /// dentro es lo mismo que un `.xapk`: un ZIP con los trozos y una ficha JSON.
    public static func fromExtension(_ pathExtension: String) -> AndroidPackageKind? {
        switch pathExtension.lowercased() {
        case "apk": return .apk
        case "xapk", "apkm": return .xapk
        case "apks": return .apks
        case "aab": return .aab
        default: return nil
        }
    }

    /// Los que hay que desmontar antes de instalar nada.
    public var isBundle: Bool { self != .apk }

    /// `bundletool` es el dueño del formato y el único que sabe leer su `toc.pb`, donde está
    /// escrito qué variante le toca a cada aparato. Un `.xapk` no lo necesita: sus trozos vienen
    /// planos y se eligen por el nombre.
    public var needsBundletool: Bool { self == .apks || self == .aab }
}

/// Uno de los `.apk` que van dentro de un envoltorio.
public struct AndroidPart: Equatable, Sendable {
    /// Para qué sirve el trozo. Es lo que decide si se instala o se descarta: del procesador y
    /// de la densidad va **uno solo**, el que le toque al aparato; de los idiomas, todos.
    public enum Role: Equatable, Sendable {
        /// El trozo principal: el código y todo lo que no depende del aparato.
        case base
        /// Librerías nativas para un juego de instrucciones (`arm64-v8a`…).
        case abi(String)
        /// Recursos para una densidad de pantalla (`xxhdpi`…).
        case density(String)
        /// Textos de un idioma (`es`, `pt-rBR`…).
        case language(String)
        /// Un módulo que la app pide aparte cuando le hace falta.
        case feature(String)
    }

    /// Ruta dentro del ZIP, que es como se saca después.
    public let entryName: String
    /// Nombre del trozo tal y como lo declara su manifiesto (`config.arm64_v8a`), o `nil` en el
    /// principal. Es lo que Android usa para distinguirlos; el nombre del archivo es adorno.
    public let splitId: String?
    public let role: Role
    public let size: Int

    public init(entryName: String, splitId: String?, role: Role, size: Int) {
        self.entryName = entryName
        self.splitId = splitId
        self.role = role
        self.size = size
    }

    public var isBase: Bool { role == .base }
}

/// Un archivo de expansión: los datos que no caben en el `.apk` y viven aparte, en la memoria
/// del aparato. Los juegos grandes de antes de los App Bundle los usan casi todos.
public struct AndroidExpansion: Equatable, Sendable {
    public let entryName: String
    /// El paquete al que pertenece, sacado de la ruta `Android/obb/<paquete>/`.
    public let packageName: String
    public let fileName: String
    public let size: Int

    public init(entryName: String, packageName: String, fileName: String, size: Int) {
        self.entryName = entryName
        self.packageName = packageName
        self.fileName = fileName
        self.size = size
    }

    /// Dónde tiene que acabar en el aparato. La ruta es fija: Android busca los `.obb` de una app
    /// solo ahí.
    public var deviceDirectory: String { "/sdcard/Android/obb/\(packageName)" }
    public var devicePath: String { "\(deviceDirectory)/\(fileName)" }
}

/// Si el `.apk` viene firmado. Android rechaza uno sin firma: no es un aviso, es un no.
public enum ApkSignature: Equatable, Sendable {
    /// Trae al menos un esquema de firma reconocible.
    case signed
    /// Ni firma vieja (`META-INF`) ni bloque de firma moderno.
    case missing
    /// No se pudo mirar: el archivo no se dejó leer, o es un envoltorio y la pregunta se hace
    /// sobre los trozos de dentro, no sobre el envoltorio.
    case unknown
}

/// Lo que se ha leído del archivo elegido, sea un `.apk` suelto o un envoltorio.
///
/// Todo sale del archivo. Lo que no se puede leer se queda vacío, nunca se rellena con lo
/// probable —que es justo lo que hace de menos el `manifest.json` de un `.xapk`, que dice lo que
/// su autor quiso y no siempre lo que hay dentro.
public struct AndroidPackage: Equatable, Sendable {
    public let kind: AndroidPackageKind
    /// Lo leído del `.apk` principal. En un envoltorio, del que hace de base.
    public let facts: ApkFacts
    /// Los `.apk` de dentro. Vacío en un `.apk` suelto.
    public let parts: [AndroidPart]
    public let expansions: [AndroidExpansion]
    /// Módulos de un `.aab` que no son `base`: los que Play entrega aparte.
    public let extraModules: [String]
    public let signature: ApkSignature
    /// El envoltorio no se dejó abrir como ZIP, o no tenía ningún `.apk` dentro.
    public let readFailed: Bool

    public init(
        kind: AndroidPackageKind,
        facts: ApkFacts = ApkFacts(),
        parts: [AndroidPart] = [],
        expansions: [AndroidExpansion] = [],
        extraModules: [String] = [],
        signature: ApkSignature = .unknown,
        readFailed: Bool = false
    ) {
        self.kind = kind
        self.facts = facts
        self.parts = parts
        self.expansions = expansions
        self.extraModules = extraModules
        self.signature = signature
        self.readFailed = readFailed
    }

    /// Un `.apk` suelto sin firma es lo único que Lever tiene que arreglar antes de instalar.
    /// En un envoltorio los trozos vienen firmados por quien los generó y volver a firmarlos
    /// obligaría a rehacerlos todos con la misma clave.
    public var needsSigning: Bool { kind == .apk && signature == .missing }

    /// Los trozos distintos que hay dentro, contando una sola vez los que `bundletool` repite
    /// para varias variantes de Android. Es lo que se enseña: los treinta y tres archivos de un
    /// `.apks` son once trozos vistos tres veces.
    public var distinctPartCount: Int {
        Set(parts.map { $0.splitId ?? "base" }).count
    }
}

/// Elige qué trozos de un envoltorio le tocan a un aparato.
///
/// Es la parte que Play hacía por su cuenta y que fuera de Play no hace nadie. Instalarlos todos
/// no vale: dos trozos del mismo procesador o de dos densidades se pisan, y Android rechaza el
/// conjunto. Instalar solo la base tampoco: la app queda sin librerías nativas y se cierra al
/// abrirla.
public enum AndroidSplitChooser {
    /// Las densidades que Android define, con los puntos por pulgada a los que corresponden.
    /// El orden importa: se recorre de menos a más.
    static let densityBuckets: [(name: String, dpi: Int)] = [
        ("ldpi", 120), ("mdpi", 160), ("tvdpi", 213), ("hdpi", 240),
        ("xhdpi", 320), ("xxhdpi", 480), ("xxxhdpi", 640)
    ]

    /// Densidad por omisión cuando el aparato no la dice. `mdpi` es la de referencia de Android.
    static let defaultDensityDpi = 160

    public static func choose(
        parts: [AndroidPart],
        deviceAbis: [String],
        densityDpi: Int?
    ) -> [AndroidPart] {
        var chosen = parts.filter { $0.isBase }

        // Del procesador va uno solo, y manda el orden en el que el aparato lista los suyos:
        // `ro.product.cpu.abilist` va del que ejecuta mejor al que solo emula.
        let abiParts = parts.compactMap { part -> (String, AndroidPart)? in
            guard case .abi(let abi) = part.role else { return nil }
            return (abi, part)
        }
        if !abiParts.isEmpty {
            // Sin lista del aparato no se puede elegir, así que se lleva el primero que haya:
            // equivocarse deja la app sin librerías, pero no llevar ninguna la deja igual.
            let preferred = deviceAbis.first { abi in abiParts.contains { $0.0 == abi } }
            if let preferred, let match = abiParts.first(where: { $0.0 == preferred }) {
                chosen.append(match.1)
            } else if deviceAbis.isEmpty, let first = abiParts.first {
                chosen.append(first.1)
            }
        }

        // De la densidad, la que más se acerque por arriba: una pantalla de 420 puntos usa los
        // recursos de xxhdpi (480) encogidos, que se ven bien; los de xhdpi (320) estirados, no.
        let densityParts = parts.compactMap { part -> (String, AndroidPart)? in
            guard case .density(let bucket) = part.role else { return nil }
            return (bucket, part)
        }
        if let best = bestDensity(among: densityParts.map(\.0), for: densityDpi ?? defaultDensityDpi),
           let match = densityParts.first(where: { $0.0 == best }) {
            chosen.append(match.1)
        }

        // De los idiomas van **todos**. Pesan poco —son tablas de texto— y elegir por el idioma
        // del aparato deja el juego en inglés en cuanto alguien cambia el idioma del móvil, que
        // es un fallo que nadie relaciona nunca con cómo se instaló.
        chosen += parts.filter { if case .language = $0.role { return true }; return false }

        // Los módulos aparte se llevan también: fuera de Play no hay quien los descargue después,
        // y sin ellos la app se abre y se queda a medias.
        chosen += parts.filter { if case .feature = $0.role { return true }; return false }

        return chosen
    }

    /// La densidad que mejor le va a una pantalla: la primera que llega o pasa sus puntos por
    /// pulgada y, si el paquete no trae ninguna tan grande, la mayor que traiga.
    static func bestDensity(among available: [String], for dpi: Int) -> String? {
        guard !available.isEmpty else { return nil }
        let ordered = densityBuckets.filter { available.contains($0.name) }
        guard !ordered.isEmpty else { return available.first }
        return (ordered.first { $0.dpi >= dpi } ?? ordered[ordered.count - 1]).name
    }

    /// Clasifica un trozo por su nombre de split.
    ///
    /// El nombre lo pone quien parte la app y sigue una convención fija: `config.<qué>` para los
    /// trozos del propio paquete y `<módulo>.config.<qué>` para los de un módulo aparte. El
    /// «qué» no lleva etiqueta, así que se reconoce por su forma: los procesadores y las
    /// densidades son listas cerradas, y lo que no está en ninguna y parece un código de idioma,
    /// lo es.
    public static func role(forSplitId splitId: String?) -> AndroidPart.Role {
        guard let splitId, !splitId.isEmpty, splitId != "base" else { return .base }

        let pieces = splitId.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let index = pieces.firstIndex(of: "config"), index + 1 < pieces.count else {
            // Sin `config` es un módulo entero, no una variante de uno.
            return .feature(splitId)
        }
        let qualifier = pieces[(index + 1)...].joined(separator: ".")

        // Los ABI viajan con guion bajo en el nombre del split y con guion en todo lo demás:
        // `config.arm64_v8a` es el trozo de `arm64-v8a`.
        let asAbi = qualifier.replacingOccurrences(of: "_", with: "-")
        if AndroidAbi.known.contains(asAbi) { return .abi(asAbi) }
        if densityBuckets.contains(where: { $0.name == qualifier }) { return .density(qualifier) }
        if isLanguageCode(qualifier) { return .language(qualifier) }

        // Un `<módulo>.config.<algo>` desconocido sigue siendo del módulo: se lleva con él.
        return .feature(splitId)
    }

    /// Un código de idioma de Android: dos o tres letras, y opcionalmente una región detrás
    /// (`es`, `pt-rBR`, `b+sr+Latn`).
    static func isLanguageCode(_ text: String) -> Bool {
        let language = text.split(separator: "-").first.map(String.init) ?? text
        guard (2...3).contains(language.count) else { return false }
        return language.allSatisfy { $0.isLetter && $0.isASCII }
    }
}
