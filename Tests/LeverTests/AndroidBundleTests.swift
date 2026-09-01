import Foundation
import LeverCore

/// Prueba lo que hace falta para instalar una app que viene partida en trozos.
///
/// Los envoltorios se arman con `/usr/bin/zip` y no escribiendo el ZIP a mano: es otro programa
/// el que los escribe, así que si el lector se equivocara en algo del formato —el orden de las
/// entradas, la compresión, las carpetas— la prueba lo vería. Los `.apk` de dentro sí se fabrican
/// aquí, con el mismo constructor que usa `ApkInspectorTests`.
enum AndroidBundleTests {
    static func run() throws {
        try testRecognisesEachFormatByItsExtension()
        try testClassifiesSplitsByTheirName()
        try testPicksTheDensityThatFitsTheScreen()
        try testChoosesOneAbiOneDensityAndEveryLanguage()
        try testReadsARealXapk()
        try testReadsTheExpansionsAndWhereTheyGo()
        try testFallsBackToTheManifestWhenTheBaseCannotBeRead()
        try testReadsAnAppBundle()
        try testTellsSignedFromUnsigned()
        try testExtractsAPieceOutOfTheBundle()
        try testCommandsForSplitsAndExpansions()
        try testKnowsWhatItNeedsToDownload()
    }

    // MARK: - Formatos

    private static func testRecognisesEachFormatByItsExtension() throws {
        try expect(AndroidPackageKind.fromExtension("apk") == .apk, ".apk")
        try expect(AndroidPackageKind.fromExtension("XAPK") == .xapk, "la extensión no distingue mayúsculas")
        try expect(AndroidPackageKind.fromExtension("apkm") == .xapk,
                   "un .apkm de APKMirror es por dentro lo mismo que un .xapk")
        try expect(AndroidPackageKind.fromExtension("apks") == .apks, ".apks")
        try expect(AndroidPackageKind.fromExtension("aab") == .aab, ".aab")
        try expect(AndroidPackageKind.fromExtension("zip") == nil, "un .zip cualquiera no es una app")

        try expect(!AndroidPackageKind.apk.isBundle, "un .apk no envuelve nada")
        try expect(AndroidPackageKind.xapk.isBundle, "un .xapk sí")
        try expect(!AndroidPackageKind.xapk.needsBundletool,
                   "los trozos de un .xapk vienen planos: se eligen por el nombre")
        try expect(AndroidPackageKind.apks.needsBundletool,
                   "la tabla de un .apks está en protobuf y es de bundletool")
        try expect(AndroidPackageKind.aab.needsBundletool, "un .aab hay que convertirlo")
    }

    // MARK: - Qué es cada trozo

    private static func testClassifiesSplitsByTheirName() throws {
        try expect(AndroidSplitChooser.role(forSplitId: nil) == .base, "sin identificador es la base")
        try expect(AndroidSplitChooser.role(forSplitId: "base") == .base, "«base» es la base")

        // El guion bajo del nombre del trozo es el guion del ABI: `config.arm64_v8a` es arm64-v8a.
        try expect(AndroidSplitChooser.role(forSplitId: "config.arm64_v8a") == .abi("arm64-v8a"),
                   "el trozo de arm64 se reconoce y se le devuelve el guion")
        try expect(AndroidSplitChooser.role(forSplitId: "config.armeabi_v7a") == .abi("armeabi-v7a"), "arm de 32")
        try expect(AndroidSplitChooser.role(forSplitId: "config.xxhdpi") == .density("xxhdpi"), "densidad")
        try expect(AndroidSplitChooser.role(forSplitId: "config.es") == .language("es"), "idioma de dos letras")
        try expect(AndroidSplitChooser.role(forSplitId: "config.pt-rBR") == .language("pt-rBR"),
                   "un idioma con región sigue siendo un idioma")
        try expect(AndroidSplitChooser.role(forSplitId: "nivel2") == .feature("nivel2"),
                   "sin «config» es un módulo entero")
        try expect(AndroidSplitChooser.role(forSplitId: "nivel2.config.arm64_v8a") == .abi("arm64-v8a"),
                   "el trozo de arm64 de un módulo sigue siendo el trozo de arm64")
    }

    private static func testPicksTheDensityThatFitsTheScreen() throws {
        let parts = ["ldpi", "mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"].map {
            AndroidPart(entryName: "config.\($0).apk", splitId: "config.\($0)", role: .density($0), size: 1)
        }

        func elegida(_ dpi: Int) -> String? {
            let elegidos = AndroidSplitChooser.choose(parts: parts, deviceAbis: [], densityDpi: dpi)
            for parte in elegidos { if case .density(let cual) = parte.role { return cual } }
            return nil
        }

        // 420 es lo que dice un Pixel: no es ninguna de las densidades de la tabla, y le
        // corresponde la de encima. Con la de debajo los dibujos se ven estirados.
        try expect(elegida(420) == "xxhdpi", "una pantalla de 420 usa xxhdpi, no xhdpi: \(elegida(420) ?? "nada")")
        try expect(elegida(320) == "xhdpi", "320 es xhdpi exacto")
        try expect(elegida(160) == "mdpi", "160 es mdpi exacto")
        try expect(elegida(1000) == "xxxhdpi", "por encima de todas, la mayor que haya")
    }

    private static func testChoosesOneAbiOneDensityAndEveryLanguage() throws {
        let parts = [
            AndroidPart(entryName: "base.apk", splitId: nil, role: .base, size: 10),
            AndroidPart(entryName: "config.arm64_v8a.apk", splitId: "config.arm64_v8a",
                        role: .abi("arm64-v8a"), size: 5),
            AndroidPart(entryName: "config.armeabi_v7a.apk", splitId: "config.armeabi_v7a",
                        role: .abi("armeabi-v7a"), size: 5),
            AndroidPart(entryName: "config.xhdpi.apk", splitId: "config.xhdpi", role: .density("xhdpi"), size: 2),
            AndroidPart(entryName: "config.xxhdpi.apk", splitId: "config.xxhdpi", role: .density("xxhdpi"), size: 2),
            AndroidPart(entryName: "config.es.apk", splitId: "config.es", role: .language("es"), size: 1),
            AndroidPart(entryName: "config.fr.apk", splitId: "config.fr", role: .language("fr"), size: 1),
            AndroidPart(entryName: "nivel2.apk", splitId: "nivel2", role: .feature("nivel2"), size: 3)
        ]

        let elegidos = AndroidSplitChooser.choose(
            parts: parts, deviceAbis: ["arm64-v8a", "armeabi-v7a"], densityDpi: 420
        )
        let nombres = Set(elegidos.map(\.entryName))

        try expect(nombres.contains("base.apk"), "la base siempre va")
        try expect(nombres.contains("config.arm64_v8a.apk"), "el ABI que el aparato prefiere")
        try expect(!nombres.contains("config.armeabi_v7a.apk"),
                   "el otro ABI no: dos trozos del mismo procesador se pisan y Android rechaza el conjunto")
        try expect(nombres.contains("config.xxhdpi.apk"), "la densidad que le va a la pantalla")
        try expect(!nombres.contains("config.xhdpi.apk"), "solo una densidad")
        try expect(nombres.contains("config.es.apk") && nombres.contains("config.fr.apk"),
                   "los idiomas van todos: pesan poco y elegir uno deja el juego a medias al cambiar el móvil")
        try expect(nombres.contains("nivel2.apk"), "fuera de Play no hay quien descargue luego un módulo")

        // Un aparato que solo ejecuta arm de 32 se lleva el suyo, no el de 64.
        let viejo = AndroidSplitChooser.choose(parts: parts, deviceAbis: ["armeabi-v7a"], densityDpi: 240)
        try expect(viejo.contains { $0.entryName == "config.armeabi_v7a.apk" }, "el ABI del aparato manda")
        try expect(!viejo.contains { $0.entryName == "config.arm64_v8a.apk" }, "y solo el suyo")
    }

    // MARK: - Leer un envoltorio de verdad

    /// Un `.xapk` como el que reparte APKPure: `base.apk`, sus trozos y la ficha al lado.
    private static func testReadsARealXapk() throws {
        let fixture = try TemporaryFixture()
        let xapk = try makeXapk(in: fixture, named: "juego.xapk")

        let paquete = AndroidBundleInspector.inspect(xapk)
        try expect(!paquete.readFailed, "un .xapk bien formado debe leerse")
        try expect(paquete.kind == .xapk, "el formato sale de la extensión")

        // Lo importante: los datos salen del `.apk` de base, no de la ficha.
        try expect(paquete.facts.packageName == "com.ejemplo.app",
                   "el paquete sale del manifiesto del .apk de base: \(paquete.facts.packageName ?? "nada")")
        try expect(paquete.facts.versionName == "1.4.2", "y la versión también")
        try expect(paquete.facts.minSdk == 26, "y el Android mínimo")
        try expect(!paquete.facts.isSplit, "la base lleva classes.dex: es una app entera")

        try expect(paquete.parts.count == 4, "cuatro trozos: \(paquete.parts.map(\.entryName))")
        let base = paquete.parts.first { $0.isBase }
        try expect(base?.entryName == "base.apk", "la base es base.apk: \(base?.entryName ?? "ninguna")")
        try expect(paquete.parts.contains { $0.role == .abi("arm64-v8a") }, "el trozo de arm64")
        try expect(paquete.parts.contains { $0.role == .density("xxhdpi") }, "el de la densidad")
        try expect(paquete.parts.contains { $0.role == .language("es") }, "el del idioma")
        try expect(paquete.signature == .unknown,
                   "el envoltorio no se firma: la firma está en cada trozo")
    }

    private static func testReadsTheExpansionsAndWhereTheyGo() throws {
        let fixture = try TemporaryFixture()
        let xapk = try makeXapk(in: fixture, named: "conobb.xapk", withExpansion: true)

        let paquete = AndroidBundleInspector.inspect(xapk)
        try expect(paquete.expansions.count == 1, "un archivo de expansión: \(paquete.expansions.count)")
        guard let obb = paquete.expansions.first else { return }

        try expect(obb.packageName == "com.ejemplo.app", "el dueño sale de la ruta, no de suponerlo")
        try expect(obb.fileName == "main.42.com.ejemplo.app.obb", "el nombre importa: lo lleva el juego dentro")
        try expect(obb.devicePath == "/sdcard/Android/obb/com.ejemplo.app/main.42.com.ejemplo.app.obb",
                   "la ruta del aparato es fija; Android solo los busca ahí: \(obb.devicePath)")
    }

    /// Si el `.apk` de base no se deja leer, la ficha sirve de respaldo. No al revés: mientras la
    /// base se lea, manda ella.
    private static func testFallsBackToTheManifestWhenTheBaseCannotBeRead() throws {
        let fixture = try TemporaryFixture()
        let taller = fixture.directoryURL.appendingPathComponent("roto", isDirectory: true)
        try FileManager.default.createDirectory(at: taller, withIntermediateDirectories: true)

        try Data("esto no es un apk".utf8).write(to: taller.appendingPathComponent("base.apk"))
        try ficha(package: "com.respaldo.juego", version: "9.9").write(
            to: taller.appendingPathComponent("manifest.json")
        )

        let xapk = fixture.directoryURL.appendingPathComponent("roto.xapk")
        try zipUp(taller, into: xapk)

        let paquete = AndroidBundleInspector.inspect(xapk)
        try expect(paquete.facts.packageName == "com.respaldo.juego",
                   "sin poder abrir la base, vale lo que diga la ficha: \(paquete.facts.packageName ?? "nada")")
        try expect(paquete.facts.versionName == "9.9", "y su versión")
    }

    private static func testReadsAnAppBundle() throws {
        let fixture = try TemporaryFixture()
        let taller = fixture.directoryURL.appendingPathComponent("aab", isDirectory: true)
        for ruta in ["base/manifest", "base/dex", "base/lib/arm64-v8a", "base/lib/armeabi-v7a", "nivel2/dex"] {
            try FileManager.default.createDirectory(
                at: taller.appendingPathComponent(ruta), withIntermediateDirectories: true
            )
        }
        try Data("proto".utf8).write(to: taller.appendingPathComponent("base/manifest/AndroidManifest.xml"))
        try Data("dex".utf8).write(to: taller.appendingPathComponent("base/dex/classes.dex"))
        try Data("so".utf8).write(to: taller.appendingPathComponent("base/lib/arm64-v8a/libjuego.so"))
        try Data("so".utf8).write(to: taller.appendingPathComponent("base/lib/armeabi-v7a/libjuego.so"))
        try Data("dex".utf8).write(to: taller.appendingPathComponent("nivel2/dex/classes.dex"))
        try Data("pb".utf8).write(to: taller.appendingPathComponent("BundleConfig.pb"))

        let aab = fixture.directoryURL.appendingPathComponent("juego.aab")
        try zipUp(taller, into: aab)

        let paquete = AndroidBundleInspector.inspect(aab)
        try expect(!paquete.readFailed, "un .aab con su módulo base debe leerse")
        try expect(paquete.parts.isEmpty, "un .aab no trae ningún .apk: hay que generarlos")
        try expect(paquete.facts.abis == ["arm64-v8a", "armeabi-v7a"],
                   "los procesadores sí están a la vista, en base/lib/: \(paquete.facts.abis)")
        try expect(paquete.extraModules == ["nivel2"],
                   "los módulos que Play entrega aparte se nombran: \(paquete.extraModules)")
        try expect(paquete.facts.packageName == nil,
                   "el manifiesto de un .aab está en protobuf: adivinarlo sería inventar")
    }

    // MARK: - Firma

    private static func testTellsSignedFromUnsigned() throws {
        let fixture = try TemporaryFixture()

        let sinFirma = try ApkInspectorTests.makeApk(
            in: fixture, named: "sinfirma.apk",
            manifest: ApkInspectorTests.makeManifest(utf8: false),
            extraEntries: ["classes.dex": Data("dex".utf8)]
        )
        try expect(ApkInspector.signature(of: sinFirma) == .missing,
                   "sin META-INF y sin bloque de firma, no está firmado")

        let firmaVieja = try ApkInspectorTests.makeApk(
            in: fixture, named: "firmavieja.apk",
            manifest: ApkInspectorTests.makeManifest(utf8: false),
            extraEntries: [
                "classes.dex": Data("dex".utf8),
                "META-INF/MANIFEST.MF": Data("Manifest-Version: 1.0\n".utf8),
                "META-INF/CERT.SF": Data("Signature-Version: 1.0\n".utf8),
                "META-INF/CERT.RSA": Data([0x30, 0x82])
            ]
        )
        try expect(ApkInspector.signature(of: firmaVieja) == .signed,
                   "un certificado en META-INF es la firma de siempre, y Android la acepta")

        // Un `.apk` sin META-INF pero con el bloque moderno también está firmado, y es el caso
        // normal desde Android 7: ahí no queda ninguna entrada en el zip que lo delate.
        let conBloque = try makeApkWithSigningBlock(in: fixture, named: "firmanueva.apk")
        try expect(ApkInspector.signature(of: conBloque) == .signed,
                   "el bloque de firma va entre los datos y el directorio, y se reconoce por su marca")

        let paquete = AndroidBundleInspector.inspect(sinFirma)
        try expect(paquete.needsSigning, "un .apk suelto sin firma hay que firmarlo antes de instalarlo")
        try expect(!AndroidBundleInspector.inspect(firmaVieja).needsSigning, "uno firmado, no")
    }

    // MARK: - Sacar los trozos

    private static func testExtractsAPieceOutOfTheBundle() throws {
        let fixture = try TemporaryFixture()
        let xapk = try makeXapk(in: fixture, named: "sacar.xapk", withExpansion: true)
        let destino = fixture.directoryURL.appendingPathComponent("fuera", isDirectory: true)

        let sacados = try AndroidBundleInspector.extract(
            entryNames: ["base.apk", "Android/obb/com.ejemplo.app/main.42.com.ejemplo.app.obb"],
            of: xapk, into: destino
        )
        try expect(sacados.count == 2, "dos entradas pedidas, dos archivos")
        try expect(sacados[0].lastPathComponent == "base.apk", "en el orden en que se pidieron")
        // Las carpetas de dentro del envoltorio se aplanan: `adb install-multiple` recibe rutas
        // sueltas, y el `.obb` va a donde diga su expansión, no a donde estaba.
        try expect(sacados[1].lastPathComponent == "main.42.com.ejemplo.app.obb", "el .obb sale con su nombre")

        // Lo sacado tiene que servir: el `.apk` de base se lee igual que si estuviera suelto.
        let facts = ApkInspector.inspect(sacados[0])
        try expect(facts.packageName == "com.ejemplo.app",
                   "el .apk sacado del envoltorio se lee entero, no a medias")

        let obb = try Data(contentsOf: sacados[1])
        try expect(obb.count == 200_000, "el archivo de expansión sale con su tamaño: \(obb.count)")
        try expect(obb.first == 0x4C, "y con su contenido")
    }

    // MARK: - Órdenes

    private static func testCommandsForSplitsAndExpansions() throws {
        let adb = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        let trozos = ["base.apk", "config.arm64_v8a.apk"].map { URL(fileURLWithPath: "/tmp/lever/\($0)") }

        let instalar = AndroidLauncher.installMultipleCommand(adb: adb, serial: "emulator-5554", apks: trozos)
        try expect(instalar.arguments.contains("install-multiple"),
                   "los trozos van en una sola sesión: de uno en uno, el primero ya falla")
        try expect(instalar.arguments.contains("-r"), "reinstalar conservando los datos")
        try expect(instalar.arguments.suffix(2) == ["/tmp/lever/base.apk", "/tmp/lever/config.arm64_v8a.apk"],
                   "las rutas van al final, en su orden")

        let obb = AndroidExpansion(
            entryName: "Android/obb/com.j/main.1.com.j.obb", packageName: "com.j",
            fileName: "main.1.com.j.obb", size: 10
        )
        let empujar = AndroidLauncher.pushExpansionCommand(
            adb: adb, serial: "abc", file: URL(fileURLWithPath: "/tmp/main.1.com.j.obb"), expansion: obb
        )
        try expect(empujar.arguments.last == "/sdcard/Android/obb/com.j/main.1.com.j.obb",
                   "la ruta de destino es la que Android mira: \(empujar.arguments.last ?? "")")

        let carpeta = AndroidLauncher.makeExpansionFolderCommand(adb: adb, serial: "abc", package: "com.j")
        try expect(carpeta.arguments.last?.contains("mkdir -p /sdcard/Android/obb/com.j") == true,
                   "adb push no crea la carpeta")

        // `wm density` contesta la física y, si el usuario la cambió, la suya debajo. Manda la suya.
        try expect(AndroidLauncher.density(fromOutput: "Physical density: 420\n") == 420, "densidad física")
        try expect(
            AndroidLauncher.density(fromOutput: "Physical density: 420\nOverride density: 320\n") == 320,
            "si hay una cambiada a mano, es la que se está usando"
        )
        try expect(AndroidLauncher.density(fromOutput: "") == nil, "sin respuesta no se inventa")
    }

    // MARK: - Herramientas

    private static func testKnowsWhatItNeedsToDownload() throws {
        let vacío = AndroidToolkit()
        let completo = AndroidToolkit(
            java: URL(fileURLWithPath: "/bin/echo"),
            bundletool: URL(fileURLWithPath: "/bin/echo"),
            apksigner: URL(fileURLWithPath: "/bin/echo"),
            zipalign: URL(fileURLWithPath: "/bin/echo")
        )

        let xapk = AndroidPackage(kind: .xapk, parts: [
            AndroidPart(entryName: "base.apk", splitId: nil, role: .base, size: 1)
        ])
        try expect(AndroidTools.needs(for: xapk, having: vacío).isEmpty,
                   "un .xapk se instala con adb y nada más: no hay nada que descargar")

        let aab = AndroidPackage(kind: .aab)
        let faltan = AndroidTools.needs(for: aab, having: vacío).map(\.tool)
        try expect(faltan == [.java, .bundletool], "un .aab pide Java y bundletool: \(faltan)")
        try expect(AndroidTools.needs(for: aab, having: completo).isEmpty, "si ya están, no se baja nada")

        let sinFirma = AndroidPackage(kind: .apk, signature: .missing)
        try expect(
            AndroidTools.needs(for: sinFirma, having: vacío).map(\.tool) == [.java, .buildTools],
            "firmar pide Java y el firmador de Android"
        )
        try expect(AndroidTools.needs(for: AndroidPackage(kind: .apk, signature: .signed), having: vacío).isEmpty,
                   "un .apk firmado no necesita nada")

        // Las direcciones no se arman a ojo: la de las build-tools cambió de guion a subrayado en
        // la r35, y equivocarse da un 404 a mitad de la instalación.
        try expect(AndroidTools.buildToolsURL.absoluteString
            == "https://dl.google.com/android/repository/build-tools_r35_macosx.zip",
            "la dirección de las build-tools: \(AndroidTools.buildToolsURL)")
        try expect(AndroidTools.bundletoolURL.absoluteString.hasSuffix("bundletool-all-1.18.3.jar"),
                   "la de bundletool: \(AndroidTools.bundletoolURL)")

        let clave = AndroidTools.newKeyCommand(
            privateKey: URL(fileURLWithPath: "/tmp/c.pem"), certificate: URL(fileURLWithPath: "/tmp/c.crt")
        )
        try expect(clave.executableURL.path == "/usr/bin/openssl",
                   "la clave la hace el openssl del sistema: así firmar no depende de tener Java")
        try expect(clave.arguments.contains("10000"),
                   "el certificado tiene que seguir valiendo mientras la app esté instalada")
    }

    // MARK: - Fábrica de envoltorios

    /// Arma un `.xapk` con la forma que reparte APKPure y lo comprime con `/usr/bin/zip`.
    private static func makeXapk(
        in fixture: TemporaryFixture, named name: String, withExpansion: Bool = false
    ) throws -> URL {
        let taller = fixture.directoryURL
            .appendingPathComponent("taller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: taller, withIntermediateDirectories: true)
        let interior = try TemporaryFixture()

        // La base es un `.apk` entero, con su manifiesto y su código.
        let base = try ApkInspectorTests.makeApk(
            in: interior, named: "base.apk",
            manifest: ApkInspectorTests.makeManifest(utf8: false),
            extraEntries: ["classes.dex": Data("dex".utf8)],
            deflate: true
        )
        try FileManager.default.copyItem(at: base, to: taller.appendingPathComponent("base.apk"))

        // Y los trozos, que no llevan código: por eso sueltos no se pueden instalar.
        for (archivo, extra) in [
            ("config.arm64_v8a.apk", ["lib/arm64-v8a/libjuego.so": Data("so".utf8)]),
            ("config.xxhdpi.apk", ["res/drawable-xxhdpi/icono.png": Data("png".utf8)]),
            ("config.es.apk", ["resources.arsc": Data("arsc".utf8)])
        ] {
            let trozo = try ApkInspectorTests.makeApk(
                in: interior, named: archivo,
                manifest: ApkInspectorTests.makeManifest(utf8: false), extraEntries: extra
            )
            try FileManager.default.copyItem(at: trozo, to: taller.appendingPathComponent(archivo))
        }

        try ficha(package: "com.ejemplo.app", version: "1.4.2")
            .write(to: taller.appendingPathComponent("manifest.json"))

        if withExpansion {
            let carpeta = taller.appendingPathComponent("Android/obb/com.ejemplo.app", isDirectory: true)
            try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
            try Data(repeating: 0x4C, count: 200_000)
                .write(to: carpeta.appendingPathComponent("main.42.com.ejemplo.app.obb"))
        }

        let destino = fixture.directoryURL.appendingPathComponent(name)
        try zipUp(taller, into: destino)
        return destino
    }

    private static func ficha(package: String, version: String) throws -> Data {
        let json: [String: Any] = [
            "xapk_version": 2,
            "package_name": package,
            "version_name": version,
            "version_code": "42",
            "min_sdk_version": "26",
            "split_apks": [
                ["file": "base.apk", "id": "base"],
                ["file": "config.arm64_v8a.apk", "id": "config.arm64_v8a"],
                ["file": "config.xxhdpi.apk", "id": "config.xxhdpi"],
                ["file": "config.es.apk", "id": "config.es"]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// Comprime una carpeta con `/usr/bin/zip`, que es otro programa: si el lector se inventara
    /// algo del formato, aquí se vería.
    private static func zipUp(_ folder: URL, into destination: URL) throws {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proceso.arguments = ["-q", "-r", "-X", destination.path, "."]
        proceso.currentDirectoryURL = folder
        proceso.standardOutput = FileHandle.nullDevice
        proceso.standardError = FileHandle.nullDevice
        try proceso.run()
        proceso.waitUntilExit()
        try expect(proceso.terminationStatus == 0, "zip debe haber creado \(destination.lastPathComponent)")
    }

    /// Un `.apk` con el bloque de firma moderno: los datos, el bloque con su marca, y detrás el
    /// directorio central. Se arma pegando el bloque delante del directorio de un zip ya hecho.
    private static func makeApkWithSigningBlock(in fixture: TemporaryFixture, named name: String) throws -> URL {
        let original = try ApkInspectorTests.makeApk(
            in: fixture, named: "previo-\(name)",
            manifest: ApkInspectorTests.makeManifest(utf8: false),
            extraEntries: ["classes.dex": Data("dex".utf8)]
        )
        var bytes = [UInt8](try Data(contentsOf: original))

        // El final del zip dice dónde empieza el directorio central; ahí es donde se corta.
        guard let final = ultimaMarca(0x0605_4B50, en: bytes) else {
            throw TestFailure(description: "el zip de prueba no tiene final")
        }
        let inicioDirectorio = Int(leerUInt32(bytes, final + 16))

        // Un bloque de firma: ocho bytes de tamaño, el par etiqueta/valor, el tamaño otra vez y
        // la marca. Lo que lleva dentro da igual: lo que se comprueba es que se reconoce.
        let relleno = [UInt8](repeating: 0x11, count: 40)
        let tamaño = UInt64(relleno.count + 8 + 16)
        var bloque = enteroDe64(tamaño) + relleno + enteroDe64(tamaño) + Array("APK Sig Block 42".utf8)

        bytes.insert(contentsOf: bloque, at: inicioDirectorio)
        // El final tiene que seguir apuntando al directorio, que ahora está más lejos.
        let nuevoInicio = UInt32(inicioDirectorio + bloque.count)
        let nuevoFinal = final + bloque.count
        for desplazamiento in 0..<4 {
            bytes[nuevoFinal + 16 + desplazamiento] = UInt8((nuevoInicio >> (8 * desplazamiento)) & 0xFF)
        }
        bloque.removeAll()

        let destino = fixture.directoryURL.appendingPathComponent(name)
        try Data(bytes).write(to: destino)
        return destino
    }

    private static func enteroDe64(_ valor: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((valor >> (8 * $0)) & 0xFF) }
    }

    private static func leerUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var valor: UInt32 = 0
        for índice in (0..<4).reversed() { valor = (valor << 8) | UInt32(bytes[offset + índice]) }
        return valor
    }

    private static func ultimaMarca(_ firma: UInt32, en bytes: [UInt8]) -> Int? {
        var índice = bytes.count - 4
        while índice >= 0 {
            if leerUInt32(bytes, índice) == firma { return índice }
            índice -= 1
        }
        return nil
    }
}
