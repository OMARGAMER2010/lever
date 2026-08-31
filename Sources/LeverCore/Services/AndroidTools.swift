import Foundation

/// Las herramientas de fuera que hacen falta para los formatos que `adb` no sabe instalar.
///
/// Cada una está o no está, y esto es lo que se ha encontrado.
public struct AndroidToolkit: Equatable, Sendable {
    /// El `java` que ejecuta los dos `.jar`. Sin él no hay ni `bundletool` ni firma.
    public var java: URL?
    /// `bundletool-all.jar`, el que entiende los `.aab` y los `.apks`.
    public var bundletool: URL?
    /// `apksigner.jar` de las build-tools del SDK. Se ejecuta con `java -jar`, no por su guion:
    /// el guion se busca un Java por su cuenta y aquí ya sabemos cuál queremos.
    public var apksigner: URL?
    /// `zipalign`, que es un binario nativo y no necesita Java.
    public var zipalign: URL?

    public init(java: URL? = nil, bundletool: URL? = nil, apksigner: URL? = nil, zipalign: URL? = nil) {
        self.java = java
        self.bundletool = bundletool
        self.apksigner = apksigner
        self.zipalign = zipalign
    }

    public var canRunBundletool: Bool { java != nil && bundletool != nil }
    public var canSign: Bool { java != nil && apksigner != nil }
}

/// Qué le falta a este Mac para poder tratar un paquete, y cuánto costaría conseguirlo.
public struct AndroidToolNeed: Equatable, Sendable {
    public enum Tool: String, Equatable, Sendable {
        case java
        case bundletool
        case buildTools

        public var textKey: TextKey {
            switch self {
            case .java: return .toolJava
            case .bundletool: return .toolBundletool
            case .buildTools: return .toolApkSigner
            }
        }
    }

    public let tool: Tool
    public let megabytes: Int
}

/// Consigue y maneja `bundletool`, `apksigner` y el Java que los mueve.
///
/// La regla es la misma que con los motores de escritorio: lo que ya está en el Mac se usa, lo
/// que se sabe de dónde bajar se baja, y lo que no, se dice. Aquí «lo que ya está» es el SDK de
/// Android que instala quien tiene el emulador —ahí viven `apksigner` y `zipalign`—, y el JDK que
/// trae cualquiera que haya tocado Java.
public enum AndroidTools {
    /// La versión de `bundletool` que se descarga.
    ///
    /// Va escrita a mano y no se pregunta cuál es la última a propósito: `bundletool` lee un
    /// formato que apenas cambia, preguntar mete una llamada a la API de GitHub —con su límite
    /// por hora— en mitad de una instalación, y una versión que funciona hoy funcionará mañana.
    /// Si algún día hiciera falta, se cambia esta línea.
    public static let bundletoolVersion = "1.18.3"

    /// Las build-tools que traen `apksigner` y `zipalign`.
    ///
    /// **Ojo con el nombre del archivo**: hasta la r34 Google lo separaba con guion
    /// (`build-tools_r34-macosx.zip`) y desde la r35 con subrayado (`build-tools_r35_macosx.zip`).
    /// Comprobado: la dirección con guion para la r35 da un 404.
    public static let buildToolsRelease = "r35"

    public static var bundletoolURL: URL {
        URL(string: "https://github.com/google/bundletool/releases/download/"
            + "\(bundletoolVersion)/bundletool-all-\(bundletoolVersion).jar")!
    }

    public static var buildToolsURL: URL {
        URL(string: "https://dl.google.com/android/repository/build-tools_\(buildToolsRelease)_macosx.zip")!
    }

    /// El Java que se baja si no hay ninguno. El 21 es de soporte largo y sobra para dos `.jar`
    /// que solo leen y escriben archivos.
    public static let javaFeature = JavaFeature(21)

    // MARK: - Buscar lo que ya hay

    public static func locate(
        library: PortLibrary = .shared, fileManager: FileManager = .default
    ) -> AndroidToolkit {
        var toolkit = AndroidToolkit()
        toolkit.java = findJava(library: library, fileManager: fileManager)

        let jar = library.bundletoolURL(version: bundletoolVersion)
        if fileManager.isReadableFile(atPath: jar.path) { toolkit.bundletool = jar }

        if let buildTools = findBuildTools(library: library, fileManager: fileManager) {
            let firmador = buildTools.appendingPathComponent("lib/apksigner.jar")
            let alineador = buildTools.appendingPathComponent("zipalign")
            if fileManager.isReadableFile(atPath: firmador.path) { toolkit.apksigner = firmador }
            if fileManager.isExecutableFile(atPath: alineador.path) { toolkit.zipalign = alineador }
        }
        return toolkit
    }

    /// `/usr/bin/java` no vale para saber si hay Java: en macOS ese archivo está siempre y lo
    /// único que hace, cuando no hay ninguna máquina virtual instalada, es abrir una ventana
    /// diciendo que no la hay. Hay que mirar dónde viven de verdad.
    static func findJava(library: PortLibrary, fileManager: FileManager) -> URL? {
        var candidatos: [URL] = []

        for raíz in ["/Library/Java/JavaVirtualMachines",
                     NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"] {
            let contenido = (try? fileManager.contentsOfDirectory(atPath: raíz)) ?? []
            candidatos += contenido.sorted().reversed().map {
                URL(fileURLWithPath: raíz).appendingPathComponent("\($0)/Contents/Home/bin/java")
            }
        }
        candidatos.append(URL(fileURLWithPath: "/opt/homebrew/opt/openjdk/bin/java"))
        candidatos.append(URL(fileURLWithPath: "/usr/local/opt/openjdk/bin/java"))

        // El JRE que Lever se baja para los juegos de Java sirve igual para esto.
        for feature in JavaFeature.longTermSupport.reversed() {
            for arquitectura in ["aarch64", "x64"] {
                candidatos.append(
                    library.javaRuntimeURL(feature: String(feature), architecture: arquitectura)
                        .appendingPathComponent("Contents/Home/bin/java")
                )
            }
        }
        return candidatos.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Las build-tools más nuevas que haya, vengan del SDK del usuario o de las que Lever bajó.
    static func findBuildTools(library: PortLibrary, fileManager: FileManager) -> URL? {
        var carpetas: [URL] = []
        for raíz in RuntimeLocator.androidSdkRoots {
            let build = raíz.appendingPathComponent("build-tools")
            let versiones = (try? fileManager.contentsOfDirectory(atPath: build.path)) ?? []
            carpetas += versiones.sorted(by: >).map { build.appendingPathComponent($0, isDirectory: true) }
        }
        carpetas.append(library.buildToolsURL(release: buildToolsRelease))
        return carpetas.first {
            fileManager.isReadableFile(atPath: $0.appendingPathComponent("lib/apksigner.jar").path)
        }
    }

    /// Lo que habría que descargar para tratar este paquete, con lo que ocupa cada cosa. Se
    /// calcula antes de empezar para poder decirlo, no para decidir por el usuario.
    public static func needs(for package: AndroidPackage, having toolkit: AndroidToolkit) -> [AndroidToolNeed] {
        var faltan: [AndroidToolNeed] = []
        let necesitaJava = package.kind.needsBundletool || package.needsSigning
        if necesitaJava, toolkit.java == nil { faltan.append(AndroidToolNeed(tool: .java, megabytes: 45)) }
        if package.kind.needsBundletool, toolkit.bundletool == nil {
            faltan.append(AndroidToolNeed(tool: .bundletool, megabytes: 32))
        }
        if package.needsSigning, toolkit.apksigner == nil {
            faltan.append(AndroidToolNeed(tool: .buildTools, megabytes: 76))
        }
        return faltan
    }

    // MARK: - Conseguir lo que falta

    /// Descarga lo que haga falta y devuelve el juego de herramientas ya completo.
    ///
    /// Lo que ya estaba no se vuelve a bajar: es la misma regla de la biblioteca de motores.
    public static func prepare(
        needs: [AndroidToolNeed],
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        appleSilicon: Bool = AndroidTools.thisMacIsAppleSilicon,
        onNeed: @Sendable (AndroidToolNeed) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> AndroidToolkit {
        for need in needs {
            onNeed(need)
            switch need.tool {
            case .java:
                try await downloadJava(
                    runner: runner, session: session, library: library,
                    fileManager: fileManager, appleSilicon: appleSilicon, onLine: onLine
                )
            case .bundletool:
                try await downloadBundletool(
                    runner: runner, session: session, library: library,
                    fileManager: fileManager, onLine: onLine
                )
            case .buildTools:
                try await downloadBuildTools(
                    runner: runner, session: session, library: library,
                    fileManager: fileManager, onLine: onLine
                )
            }
        }
        return locate(library: library, fileManager: fileManager)
    }

    private static func downloadJava(
        runner: ProcessRunner, session: ProcessSession, library: PortLibrary,
        fileManager: FileManager, appleSilicon: Bool, onLine: @Sendable @escaping (String) -> Void
    ) async throws {
        let arquitectura = javaFeature.architecture(appleSilicon: appleSilicon)
        let destino = library.javaRuntimeURL(feature: javaFeature.description, architecture: arquitectura)
        try fileManager.createDirectory(at: destino, withIntermediateDirectories: true)

        let archivo = destino.appendingPathComponent("jre.tar.gz")
        let descarga = try await runner.run(
            PortCommands.download(javaFeature.macDownloadURL(appleSilicon: appleSilicon), into: archivo),
            session: session, onLine: onLine
        )
        defer { try? fileManager.removeItem(at: archivo) }
        guard descarga.succeeded else { throw PortFailure.downloadFailed(descarga.exitCode) }
        _ = try? await runner.run(PortCommands.untar(archivo, into: destino), session: session, onLine: onLine)
    }

    private static func downloadBundletool(
        runner: ProcessRunner, session: ProcessSession, library: PortLibrary,
        fileManager: FileManager, onLine: @Sendable @escaping (String) -> Void
    ) async throws {
        let destino = library.bundletoolURL(version: bundletoolVersion)
        try fileManager.createDirectory(
            at: destino.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descarga = try await runner.run(
            PortCommands.download(bundletoolURL, into: destino), session: session, onLine: onLine
        )
        guard descarga.succeeded else {
            try? fileManager.removeItem(at: destino)
            throw PortFailure.downloadFailed(descarga.exitCode)
        }
    }

    private static func downloadBuildTools(
        runner: ProcessRunner, session: ProcessSession, library: PortLibrary,
        fileManager: FileManager, onLine: @Sendable @escaping (String) -> Void
    ) async throws {
        let destino = library.buildToolsURL(release: buildToolsRelease)
        let taller = destino.deletingLastPathComponent()
        try fileManager.createDirectory(at: taller, withIntermediateDirectories: true)

        let archivo = taller.appendingPathComponent("build-tools.zip")
        let descarga = try await runner.run(
            PortCommands.download(buildToolsURL, into: archivo), session: session, onLine: onLine
        )
        defer { try? fileManager.removeItem(at: archivo) }
        guard descarga.succeeded else { throw PortFailure.downloadFailed(descarga.exitCode) }

        let desempaquetado = taller.appendingPathComponent("desempaquetado", isDirectory: true)
        try? fileManager.removeItem(at: desempaquetado)
        try fileManager.createDirectory(at: desempaquetado, withIntermediateDirectories: true)
        _ = try? await runner.run(
            PortCommands.unzip(archivo, into: desempaquetado), session: session, onLine: onLine
        )

        // El ZIP no lleva dentro una carpeta con el número de versión, sino con el nombre en
        // clave de esa versión de Android (`android-15` para las r35). Se coge la que haya en vez
        // de escribirla, que envejecería a la siguiente.
        let dentro = ((try? fileManager.contentsOfDirectory(atPath: desempaquetado.path)) ?? [])
            .map { desempaquetado.appendingPathComponent($0, isDirectory: true) }
            .first { fileManager.isReadableFile(atPath: $0.appendingPathComponent("lib/apksigner.jar").path) }
        guard let dentro else {
            try? fileManager.removeItem(at: desempaquetado)
            throw PortFailure.downloadFailed(0)
        }
        try? fileManager.removeItem(at: destino)
        try fileManager.moveItem(at: dentro, to: destino)
        try? fileManager.removeItem(at: desempaquetado)
    }

    public static var thisMacIsAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    // MARK: - La clave con la que se firma

    /// Clave y certificado propios de Lever, creados una vez y guardados.
    ///
    /// Son de firma de depuración, como los que genera Android Studio para probar: valen para
    /// que el aparato acepte la app, no para publicarla en ninguna tienda. La consecuencia
    /// práctica que sí importa: una app firmada con esta clave no puede actualizar a otra firmada
    /// con la del autor, y al revés. Android lo rechaza con `UPDATE_INCOMPATIBLE`, que ya se
    /// explica al usuario.
    public struct SigningKey: Equatable, Sendable {
        /// Clave privada en DER, que es lo que pide `apksigner --key`.
        public let key: URL
        public let certificate: URL
        /// El mismo par metido en un almacén PKCS#12, que es lo que pide `bundletool --ks`.
        public let keystore: URL
        public let keystorePassword: String
        public let alias: String
    }

    static let keyAlias = "lever"
    static let keyPassword = "lever"

    /// Crea el par si no existía. Usa el `openssl` que trae macOS: no hace falta Java —el
    /// `keytool` del JDK haría lo mismo, pero entonces firmar un `.apk` dependería de tener Java
    /// aunque no se vaya a usar `bundletool`.
    public static func signingKey(
        runner: ProcessRunner, session: ProcessSession,
        library: PortLibrary = .shared, fileManager: FileManager = .default
    ) async throws -> SigningKey {
        let carpeta = library.androidKeysURL
        try fileManager.createDirectory(at: carpeta, withIntermediateDirectories: true)

        let clavePEM = carpeta.appendingPathComponent("clave.pem")
        let clave = carpeta.appendingPathComponent("clave.pk8")
        let certificado = carpeta.appendingPathComponent("certificado.pem")
        let almacén = carpeta.appendingPathComponent("almacen.p12")

        let material = SigningKey(
            key: clave, certificate: certificado, keystore: almacén,
            keystorePassword: keyPassword, alias: keyAlias
        )
        let hechas = [clave, certificado, almacén].allSatisfy { fileManager.isReadableFile(atPath: $0.path) }
        if hechas { return material }

        for orden in [
            newKeyCommand(privateKey: clavePEM, certificate: certificado),
            derKeyCommand(from: clavePEM, to: clave),
            keystoreCommand(privateKey: clavePEM, certificate: certificado, into: almacén)
        ] {
            let resultado = try await runner.run(orden, session: session)
            guard resultado.succeeded else { throw PortFailure.downloadFailed(resultado.exitCode) }
        }
        return material
    }

    public static func newKeyCommand(privateKey: URL, certificate: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/openssl"),
            // Diez mil días: Android exige que el certificado siga válido cuando la app se
            // instala, y una app instalada puede quedarse años en un móvil.
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "10000",
                "-subj", "/CN=Lever/O=Lever/C=ES",
                "-keyout", privateKey.path, "-out", certificate.path
            ],
            currentDirectoryURL: nil
        )
    }

    public static func derKeyCommand(from pem: URL, to der: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "pkcs8", "-topk8", "-inform", "PEM", "-outform", "DER",
                "-in", pem.path, "-out", der.path, "-nocrypt"
            ],
            currentDirectoryURL: nil
        )
    }

    public static func keystoreCommand(privateKey: URL, certificate: URL, into keystore: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "pkcs12", "-export", "-inkey", privateKey.path, "-in", certificate.path,
                "-name", keyAlias, "-out", keystore.path, "-passout", "pass:\(keyPassword)"
            ],
            currentDirectoryURL: nil
        )
    }

    // MARK: - Órdenes

    /// Deja el `.apk` con sus entradas alineadas. Va antes de firmar: `zipalign` mueve bytes, y
    /// moverlos después rompería la firma.
    public static func alignCommand(zipalign: URL, from source: URL, to destination: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: zipalign,
            arguments: ["-f", "-p", "4", source.path, destination.path],
            currentDirectoryURL: nil
        )
    }

    public static func signCommand(
        java: URL, apksigner: URL, key: SigningKey, apk: URL
    ) -> ProcessCommand {
        ProcessCommand(
            executableURL: java,
            arguments: [
                "-jar", apksigner.path, "sign",
                "--key", key.key.path, "--cert", key.certificate.path,
                apk.path
            ],
            currentDirectoryURL: apk.deletingLastPathComponent()
        )
    }

    /// Genera los `.apk` que le tocan a un aparato concreto a partir de un `.aab`.
    ///
    /// `--connected-device` es lo que evita tener que entender el `toc.pb`: `bundletool` le
    /// pregunta al aparato cómo es y genera solo sus trozos.
    ///
    /// **`--local-testing` se queda fuera a propósito.** Sirve para las apps que reparten datos
    /// por Play Asset Delivery, y para colocárselos hace falta `run-as`, que solo funciona si la
    /// app es depurable. Con una app normal la instalación sale bien pero `bundletool` escupe un
    /// error rojo —«package not debuggable»— que parece que ha fallado todo y no ha fallado nada.
    public static func buildApksCommand(
        java: URL, bundletool: URL, adb: URL, serial: String,
        bundle: URL, output: URL, key: SigningKey
    ) -> ProcessCommand {
        ProcessCommand(
            executableURL: java,
            arguments: [
                "-jar", bundletool.path, "build-apks",
                "--bundle=\(bundle.path)", "--output=\(output.path)", "--overwrite",
                "--connected-device", "--adb=\(adb.path)", "--device-id=\(serial)",
                "--ks=\(key.keystore.path)", "--ks-pass=pass:\(key.keystorePassword)",
                "--ks-key-alias=\(key.alias)", "--key-pass=pass:\(key.keystorePassword)"
            ],
            currentDirectoryURL: output.deletingLastPathComponent(),
            environment: AndroidLauncher.environment()
        )
    }

    /// Instala un `.apks`. Es `bundletool` quien elige la variante: la tabla que dice cuál le
    /// toca a este aparato está en su `toc.pb`, en protobuf, y es suya.
    public static func installApksCommand(
        java: URL, bundletool: URL, adb: URL, serial: String, apks: URL
    ) -> ProcessCommand {
        ProcessCommand(
            executableURL: java,
            arguments: [
                "-jar", bundletool.path, "install-apks",
                "--apks=\(apks.path)", "--adb=\(adb.path)", "--device-id=\(serial)"
            ],
            currentDirectoryURL: apks.deletingLastPathComponent(),
            environment: AndroidLauncher.environment()
        )
    }
}
