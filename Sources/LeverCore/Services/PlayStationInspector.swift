import Foundation

/// Cómo viaja un juego de la familia PlayStation.
public enum PlayStationContainer: String, Equatable, Sendable {
    /// Una **carpeta**. Es lo normal en PS3 y PS4, y es lo que rompe el gesto de arrastrar un
    /// archivo: un juego volcado de su disco es un árbol de carpetas, no un archivo.
    case folder
    /// Una imagen de disco: `.iso`, o un volcado en crudo con su `.cue` al lado.
    case discImage
    /// Un paquete de la tienda, `.pkg`.
    case package
    /// El `.vpk` de Vita, que por dentro es un zip.
    case vitaPackage
}

/// Con qué seguridad se sabe lo que es.
public enum PlayStationEvidence: Equatable, Sendable {
    /// El `PARAM.SFO` del propio juego. Es la buena: la escribió quien hizo el juego, va sin
    /// cifrar, y trae el título de verdad y la versión.
    case paramSfo
    /// La cabecera del `.pkg`, que lleva el identificador de contenido en claro.
    case packageHeader
    /// El `SYSTEM.CNF` de un disco de PS1 o PS2, que dice por qué archivo arranca. De ahí sale el
    /// número de serie, que es como se identifica un juego de esas dos.
    case bootConfig
    /// Solo la forma de las carpetas. Se sabe de qué máquina es y poco más.
    case layout
    case none

    public var textKey: TextKey {
        switch self {
        case .paramSfo: return .psEvidenceParamSfo
        case .packageHeader: return .psEvidencePackage
        case .bootConfig: return .psEvidenceBoot
        case .layout: return .psEvidenceLayout
        case .none: return .romEvidenceNone
        }
    }
}

/// Lo averiguado de un juego de la familia PlayStation.
public struct PlayStationFacts: Equatable, Sendable {
    /// La máquina, por su identificador en el registro: `ps2`, `ps3`, `ps4`, `vita`, `ps5`… También
    /// puede ser `ps1` o `psp`, que **no** se ejecutan con un programa aparte sino con un núcleo de
    /// libretro, y por eso hay que reconocerlas: para mandarlas por el camino bueno.
    public let machineId: String?
    public let container: PlayStationContainer?
    public let evidence: PlayStationEvidence
    /// El nombre que le puso quien hizo el juego, no el del archivo.
    public let title: String?
    /// `BLUS30443`, `CUSA01234`, `SLUS-20230`. La identidad de verdad.
    public let titleId: String?
    public let version: String?
    public let kind: ContentKind
    public let bytes: Int64
    /// Lo que hay que darle al emulador, que **no siempre es lo que se soltó**: de una carpeta de
    /// PS3 se lanza el ejecutable de dentro, no la carpeta.
    public let launchTarget: URL?

    public init(
        machineId: String? = nil, container: PlayStationContainer? = nil,
        evidence: PlayStationEvidence = .none, title: String? = nil, titleId: String? = nil,
        version: String? = nil, kind: ContentKind = .application, bytes: Int64 = 0,
        launchTarget: URL? = nil
    ) {
        self.machineId = machineId
        self.container = container
        self.evidence = evidence
        self.title = title
        self.titleId = titleId
        self.version = version
        self.kind = kind
        self.bytes = bytes
        self.launchTarget = launchTarget
    }

    public var isRecognised: Bool { machineId != nil }

    /// La máquina en el registro de las que ejecuta un programa aparte. Es `nil` para PS1 y PSP:
    /// esas las lleva RetroArch y no están en ese registro a propósito.
    public var machine: StandaloneMachine? { machineId.flatMap(StandaloneMachines.machine(id:)) }

    /// Si se reconoce la máquina pero no existe emulador de ella. Es el caso de PS5, y merece
    /// respuesta propia: el archivo está bien, lo que no hay es con qué abrirlo.
    public var hasNoEmulator: Bool { machine?.maturity == EmulationMaturity.none }
}

/// Reconoce un juego de la familia PlayStation, sea una carpeta, una imagen de disco o un paquete.
///
/// Todo lo que hace falta va **sin cifrar**, y esa es la diferencia con la consola híbrida: el
/// `PARAM.SFO` que llevan dentro PS3, PS4, PSP y Vita da el título de verdad, la versión y qué es
/// el contenido sin ninguna llave. Lo que en el sprint anterior costaba un `prod.keys` aquí sale
/// solo.
public enum PlayStationInspector {
    public static func inspect(_ url: URL, fileManager: FileManager = .default) -> PlayStationFacts {
        var esCarpeta = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &esCarpeta) else {
            return PlayStationFacts()
        }
        if esCarpeta.boolValue { return inspectFolder(url, fileManager: fileManager) }

        let tamaño = url.fileSizeInBytes ?? 0
        let extensión = url.pathExtension.lowercased()
        if extensión == "pkg", let paquete = inspectPackage(url, bytes: tamaño) { return paquete }
        if extensión == "vpk", let vita = inspectVitaPackage(url, bytes: tamaño) { return vita }
        return inspectDiscImage(url, bytes: tamaño)
    }

    // MARK: - Carpetas

    /// Un juego volcado de su disco. La forma del árbol dice de qué máquina es.
    static func inspectFolder(_ url: URL, fileManager: FileManager) -> PlayStationFacts {
        // PS3: todo cuelga de `PS3_GAME`, y el ejecutable está en `USRDIR`.
        if let sfo = paramSFO(at: url.appendingPathComponent("PS3_GAME/PARAM.SFO"))
            ?? paramSFO(at: url.appendingPathComponent("PARAM.SFO")) {
            let arranque = url.appendingPathComponent("PS3_GAME/USRDIR/EBOOT.BIN")
            return facts(
                from: sfo, container: .folder, bytes: 0,
                // RPCS3 abre el ejecutable, no la carpeta. Darle la carpeta no hace nada y no dice
                // por qué.
                launchTarget: fileManager.isReadableFile(atPath: arranque.path) ? arranque : url,
                fallbackMachine: "ps3"
            )
        }

        // PS4 y Vita comparten la forma —`sce_sys/param.sfo`— y se distinguen por el identificador
        // que hay dentro: `CUSA` es PS4 y `PCS` es Vita.
        if let sfo = paramSFO(at: url.appendingPathComponent("sce_sys/param.sfo"))
            ?? paramSFO(at: url.appendingPathComponent("sce_sys/PARAM.SFO")) {
            let eboot = url.appendingPathComponent("eboot.bin")
            return facts(
                from: sfo, container: .folder, bytes: 0,
                launchTarget: fileManager.isReadableFile(atPath: eboot.path) ? eboot : url,
                fallbackMachine: "ps4"
            )
        }

        // Sin `PARAM.SFO` queda la forma del árbol, que ya dice la máquina aunque no el juego.
        if fileManager.fileExists(atPath: url.appendingPathComponent("PS3_GAME").path) {
            return PlayStationFacts(machineId: "ps3", container: .folder, evidence: .layout, launchTarget: url)
        }
        return PlayStationFacts()
    }

    // MARK: - Paquetes de la tienda

    /// Un `.pkg`. La cabecera lleva el identificador de contenido **sin cifrar**, y de ahí sale
    /// todo: la máquina, el juego y si es un parche o un añadido.
    static func inspectPackage(_ url: URL, bytes: Int64) -> PlayStationFacts? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let cabecera = try? handle.read(upToCount: 0x80), cabecera.count >= 0x64 else { return nil }
        let datos = [UInt8](cabecera)
        // `\x7FCNT`: la misma marca en PS3, PS4 y Vita.
        guard PartitionFileSystem.matches(datos, at: 0, [0x7F, 0x43, 0x4E, 0x54]) else { return nil }

        // **El identificador está en dos sitios distintos según la generación**: en 0x30 en PS3 y
        // en 0x40 en PS4. En vez de adivinar la generación para saber dónde mirar —que es circular,
        // porque la generación sale justo de ahí— se prueban los dos y se acepta el que tenga forma
        // de identificador.
        guard let contentId = [0x30, 0x40].lazy.compactMap({ contentIdentifier(datos, at: $0) }).first
        else { return nil }

        let titleId = PlayStationInspector.titleId(inContentId: contentId)
        return PlayStationFacts(
            machineId: ParamSFO.machineId(forTitleId: titleId),
            container: .package, evidence: .packageHeader,
            titleId: titleId, kind: .application, bytes: bytes, launchTarget: url
        )
    }

    /// Un identificador de contenido: `UP0001-BLUS30443_00-0000000000000000`. Treinta y seis
    /// caracteres imprimibles con un guion y un guion bajo en su sitio; cualquier otra cosa en ese
    /// desplazamiento es que ahí no estaba.
    public static func contentIdentifier(_ bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, offset + 0x24 <= bytes.count else { return nil }
        let crudo = bytes[offset..<offset + 0x24].prefix { $0 != 0 }
        guard crudo.count >= 20, crudo.allSatisfy({ $0 >= 0x2D && $0 < 0x7F }) else { return nil }
        let texto = String(decoding: crudo, as: UTF8.self)
        guard texto.contains("-"), texto.contains("_") else { return nil }
        return texto
    }

    /// El identificador del juego, que va entre el guion y el guion bajo.
    public static func titleId(inContentId contentId: String) -> String? {
        guard let guion = contentId.firstIndex(of: "-") else { return nil }
        let resto = contentId[contentId.index(after: guion)...]
        let hasta = resto.firstIndex(of: "_") ?? resto.endIndex
        let identificador = String(resto[..<hasta])
        return identificador.isEmpty ? nil : identificador
    }

    /// Un `.vpk` de Vita, que por dentro es un zip con el `PARAM.SFO` en `sce_sys`.
    static func inspectVitaPackage(_ url: URL, bytes: Int64) -> PlayStationFacts? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let zip = try? ZipDirectory.read(from: handle) else { return nil }
        guard let entrada = zip.entries.first(where: {
            $0.name.lowercased().hasSuffix("sce_sys/param.sfo")
        }), let datos = try? ZipDirectory.contents(of: entrada, from: handle) else { return nil }
        guard let sfo = ParamSFO([UInt8](datos)) else { return nil }
        return facts(from: sfo, container: .vitaPackage, bytes: bytes,
                     launchTarget: url, fallbackMachine: "vita")
    }

    // MARK: - Imágenes de disco

    /// Una imagen de disco. Cuatro sitios donde mirar, y el orden importa: el `PARAM.SFO` dice
    /// mucho más que el `SYSTEM.CNF`, así que se busca primero.
    static func inspectDiscImage(_ url: URL, bytes: Int64) -> PlayStationFacts {
        guard let imagen = IsoImage(url: url) else { return PlayStationFacts(bytes: bytes) }

        for (ruta, máquina) in [("PS3_GAME/PARAM.SFO", "ps3"), ("PSP_GAME/PARAM.SFO", "psp")] {
            guard let entrada = imagen.entry(atPath: ruta),
                  let datos = imagen.contents(of: entrada, limit: ParamSFO.maximumLength),
                  let sfo = ParamSFO([UInt8](datos))
            else { continue }
            return facts(from: sfo, container: .discImage, bytes: bytes,
                         launchTarget: url, fallbackMachine: máquina)
        }

        // PS1 y PS2 no llevan `PARAM.SFO`: llevan un archivo de configuración de arranque que dice
        // por qué ejecutable empieza el disco, y ese nombre **es** el número de serie del juego.
        if let entrada = imagen.entry(atPath: "SYSTEM.CNF"),
           let datos = imagen.contents(of: entrada, limit: 8 * 1024) {
            let texto = String(decoding: datos, as: UTF8.self)
            if let (máquina, serie) = bootSerial(inSystemCnf: texto) {
                return PlayStationFacts(
                    machineId: máquina, container: .discImage, evidence: .bootConfig,
                    titleId: serie, bytes: bytes, launchTarget: url
                )
            }
        }
        return PlayStationFacts(bytes: bytes)
    }

    /// La máquina y el número de serie que salen del `SYSTEM.CNF`.
    ///
    /// `BOOT2` es de PS2 y `BOOT` a secas es de PS1: es lo único que separa un disco de una de otra
    /// desde fuera. Y el valor viene como `cdrom0:\SLUS_202.30;1`, que hay que limpiar para llegar
    /// al `SLUS-20230` con el que ese juego se conoce en todas partes.
    public static func bootSerial(inSystemCnf text: String) -> (machine: String, serial: String)? {
        for línea in text.split(whereSeparator: \.isNewline) {
            let partes = línea.split(separator: "=", maxSplits: 1)
            guard partes.count == 2 else { continue }
            let clave = partes[0].trimmingCharacters(in: .whitespaces).uppercased()
            guard clave == "BOOT2" || clave == "BOOT" else { continue }
            guard let serie = serial(fromBootPath: String(partes[1])) else { continue }
            return (clave == "BOOT2" ? "ps2" : "ps1", serie)
        }
        return nil
    }

    /// `cdrom0:\SLUS_202.30;1` → `SLUS-20230`.
    public static func serial(fromBootPath path: String) -> String? {
        // Se queda con lo de detrás de la última barra o dos puntos, y se le quita el `;1` que el
        // estándar del disco le pega a todos los archivos.
        var nombre = path.trimmingCharacters(in: .whitespaces)
        for separador in [":", "\\", "/"] {
            if let última = nombre.range(of: separador, options: .backwards) {
                nombre = String(nombre[última.upperBound...])
            }
        }
        nombre = nombre.split(separator: ";").first.map(String.init) ?? nombre
        // El punto y el guion bajo son ornamento del nombre de archivo; el número de serie de
        // verdad va con un guion en medio y sin punto.
        let limpio = nombre.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .uppercased()
        guard limpio.count >= 8, limpio.contains("-") else { return nil }
        return limpio
    }

    // MARK: - Ayudas

    private static func paramSFO(at url: URL) -> ParamSFO? { ParamSFO.load(from: url) }

    /// Convierte lo leído de un `PARAM.SFO` en hechos, con la máquina que diga el identificador.
    private static func facts(
        from sfo: ParamSFO, container: PlayStationContainer, bytes: Int64,
        launchTarget: URL?, fallbackMachine: String
    ) -> PlayStationFacts {
        PlayStationFacts(
            // El identificador manda sobre la forma del árbol: una carpeta con la pinta de PS4 que
            // dentro dice `PCSE00123` es de Vita, y el archivo sabe más que la carpeta.
            machineId: sfo.machineId ?? fallbackMachine,
            container: container, evidence: .paramSfo,
            title: sfo.title, titleId: sfo.titleId, version: sfo.version,
            kind: sfo.kind, bytes: bytes, launchTarget: launchTarget
        )
    }
}
