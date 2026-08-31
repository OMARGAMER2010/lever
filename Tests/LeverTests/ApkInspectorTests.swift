import Compression
import Foundation
import LeverCore

/// Prueba el lector de `.apk` con archivos construidos a mano, byte a byte.
///
/// Igual que `ProgramInspectorTests` fabrica una cabecera PE mínima: no hace falta un `.apk` de
/// verdad para comprobar que el formato se lee bien, y así la prueba no depende de descargar
/// nada ni de tener el SDK de Android instalado.
enum ApkInspectorTests {
    static func run() throws {
        try testReadsPackageVersionAndAbisFromAnApk()
        try testReadsADeflatedManifest()
        try testReadsUtf8StringPools()
        try testDetectsSplitApk()
        try testRejectsWhatIsNotAnApk()
        try testReadsAZipWrittenBySomeoneElse()
        try testCompatibilityAgainstADevice()
        try testReadsTheScreenOrientationOfTheLauncherActivity()
        try testOrientationMappingAndManualChoice()
        try testReadsARealApkIfThereIsOneAround()
    }

    // MARK: - Pruebas

    private static func testReadsPackageVersionAndAbisFromAnApk() throws {
        let fixture = try TemporaryFixture()
        let apk = try makeApk(
            in: fixture,
            named: "completa.apk",
            manifest: makeManifest(utf8: false),
            extraEntries: [
                "classes.dex": Data("dex".utf8),
                "lib/arm64-v8a/libmain.so": Data("so".utf8),
                "lib/armeabi-v7a/libmain.so": Data("so".utf8),
                "res/layout/main.xml": Data("x".utf8)
            ]
        )

        let facts = ApkInspector.inspect(apk)
        try expect(!facts.readFailed, "un .apk bien formado debe leerse")
        try expect(facts.packageName == "com.ejemplo.app", "el paquete sale del manifiesto: \(facts.packageName ?? "nada")")
        try expect(facts.versionName == "1.4.2", "la versión sale del manifiesto: \(facts.versionName ?? "nada")")
        try expect(facts.versionCode == 42, "el número de versión es un entero, no una cadena")
        try expect(facts.minSdk == 26, "el Android mínimo sale de uses-sdk")
        try expect(facts.abis == ["arm64-v8a", "armeabi-v7a"],
                   "los ABIs salen de las carpetas lib/, ordenados: \(facts.abis)")
        try expect(!facts.isSplit, "con classes.dex es una app entera")
        try expect(!facts.isPortable, "trae código nativo")
        try expect(facts.canBeLaunched, "con nombre de paquete se puede abrir")
    }

    /// El caso normal en un `.apk` de verdad: el manifiesto va comprimido con DEFLATE dentro
    /// del zip, no almacenado en crudo. Si esta ruta se rompiera, la app no sacaría el nombre de
    /// paquete de ninguna app real y «Abrir» no se activaría nunca — sin dar ningún error.
    private static func testReadsADeflatedManifest() throws {
        let fixture = try TemporaryFixture()
        let apk = try makeApk(
            in: fixture,
            named: "comprimida.apk",
            manifest: makeManifest(utf8: false),
            extraEntries: ["classes.dex": Data("dex".utf8)],
            deflate: true
        )

        let facts = ApkInspector.inspect(apk)
        try expect(facts.packageName == "com.ejemplo.app",
                   "el manifiesto comprimido debe descomprimirse: \(facts.packageName ?? "nada")")
        try expect(facts.versionCode == 42, "y leerse igual que el almacenado")
    }

    /// Algunas herramientas escriben el depósito de cadenas en UTF-8 en vez de UTF-16.
    private static func testReadsUtf8StringPools() throws {
        let fixture = try TemporaryFixture()
        let apk = try makeApk(
            in: fixture,
            named: "utf8.apk",
            manifest: makeManifest(utf8: true),
            extraEntries: ["classes.dex": Data("dex".utf8)]
        )

        let facts = ApkInspector.inspect(apk)
        try expect(facts.packageName == "com.ejemplo.app", "también debe leer un depósito en UTF-8")
        try expect(facts.minSdk == 26, "y sus enteros")
    }

    private static func testDetectsSplitApk() throws {
        let fixture = try TemporaryFixture()
        let apk = try makeApk(
            in: fixture,
            named: "split_config.arm64_v8a.apk",
            manifest: makeManifest(utf8: false),
            extraEntries: ["lib/arm64-v8a/libmain.so": Data("so".utf8)]
        )

        let facts = ApkInspector.inspect(apk)
        try expect(facts.isSplit, "sin classes.dex es un trozo de un App Bundle")
        try expect(ApkCompatibility.check(apk: facts, device: nil).blocks,
                   "un trozo suelto no se instala en ningún aparato")
    }

    private static func testRejectsWhatIsNotAnApk() throws {
        let fixture = try TemporaryFixture()

        let text = try fixture.makeFile(named: "notas.apk")
        try expect(ApkInspector.inspect(text).readFailed, "un archivo de texto no es un .apk")

        // Un zip válido, pero sin manifiesto: no es una app de Android.
        let zip = try makeApk(in: fixture, named: "vacio.apk", manifest: nil,
                              extraEntries: ["leeme.txt": Data("hola".utf8)])
        try expect(ApkInspector.inspect(zip).readFailed, "un zip sin AndroidManifest.xml no es un .apk")

        let missing = fixture.directoryURL.appendingPathComponent("no-existe.apk")
        try expect(ApkInspector.inspect(missing).readFailed, "un archivo que no existe no debe reventar")
    }

    /// Las pruebas de arriba leen zips que escribe esta misma prueba: si el lector y el escritor
    /// compartieran un malentendido sobre el formato, las dos partes se equivocarían igual y
    /// nadie lo notaría. Este comprueba contra `/usr/bin/zip`, que es otra implementación.
    ///
    /// El manifiesto va con bytes cualquiera a propósito: además de la interoperabilidad, prueba
    /// que un manifiesto ilegible degrada bien —sin nombre de paquete, pero con los ABIs y el
    /// resto de hechos que sí se pudieron leer— en vez de dar el archivo entero por perdido.
    private static func testReadsAZipWrittenBySomeoneElse() throws {
        let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zipTool.path) else {
            print("SKIP prueba de interoperabilidad de zip (no hay /usr/bin/zip)")
            return
        }

        let fixture = try TemporaryFixture()
        let staging = fixture.directoryURL.appendingPathComponent("contenido", isDirectory: true)
        for relative in ["AndroidManifest.xml", "classes.dex", "lib/x86_64/libmain.so", "res/x.png"] {
            let file = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: 400).write(to: file)
        }

        let apk = fixture.directoryURL.appendingPathComponent("ajena.apk")
        let process = Process()
        process.executableURL = zipTool
        // `-r` recursivo, `-q` callado, y un comentario al final para que el bloque de cierre
        // no sea lo último del archivo: hay que buscarlo hacia atrás, no asumir la posición.
        process.arguments = ["-r", "-q", apk.path, ".", "-z"]
        process.currentDirectoryURL = staging
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("comentario al final del zip\n".utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()

        try expect(process.terminationStatus == 0, "zip debe haber creado el archivo")

        let facts = ApkInspector.inspect(apk)
        try expect(!facts.readFailed, "un zip de otra herramienta debe leerse igual")
        try expect(facts.abis == ["x86_64"], "los ABIs salen de lib/: \(facts.abis)")
        try expect(!facts.isSplit, "tiene classes.dex")
        try expect(facts.packageName == nil,
                   "un manifiesto ilegible no debe inventar un nombre de paquete")
        try expect(!facts.canBeLaunched, "y sin nombre de paquete no se ofrece abrir la app")
    }

    /// La comparación que evita esperar a que `adb` falle con un código ilegible.
    private static func testCompatibilityAgainstADevice() throws {
        let arm = ApkFacts(minSdk: 26, abis: ["arm64-v8a"])
        let intel = AndroidDevice(serial: "emulator-5554", availability: .ready,
                                  abis: ["x86_64", "x86"], sdk: 34)
        let phone = AndroidDevice(serial: "R5CT", availability: .ready,
                                  abis: ["arm64-v8a", "armeabi-v7a"], sdk: 34)
        let old = AndroidDevice(serial: "viejo", availability: .ready,
                                abis: ["arm64-v8a"], sdk: 23)

        try expect(ApkCompatibility.check(apk: arm, device: intel) == .abiMismatch(apk: ["arm64-v8a"], device: ["x86_64", "x86"]),
                   "arm64 en un emulador Intel no se instala")
        try expect(ApkCompatibility.check(apk: arm, device: phone) == .fits, "arm64 en un móvil arm64 sí")
        try expect(ApkCompatibility.check(apk: arm, device: old) == .sdkTooOld(needs: 26, has: 23),
                   "un Android más viejo que el mínimo se avisa antes")

        // Sin código nativo el ABI da igual; y sin datos del aparato no se bloquea por si acaso.
        let portable = ApkFacts(minSdk: 21, abis: [])
        try expect(ApkCompatibility.check(apk: portable, device: intel) == .fits,
                   "sin código nativo corre en cualquier procesador")
        try expect(!ApkCompatibility.check(apk: arm, device: nil).blocks,
                   "sin aparato elegido no se puede afirmar nada")
        try expect(AndroidRelease.name(forApi: 26) == "8.0", "API 26 es Android 8.0")
        try expect(AndroidRelease.name(forApi: 99) == nil,
                   "un nivel desconocido no se aproxima: se enseña el número tal cual")
    }

    /// La postura en que arranca la app se lee de la actividad marcada como de inicio, no de la
    /// primera que aparezca: un `.apk` declara varias y solo una tiene el filtro `LAUNCHER`.
    private static func testReadsTheScreenOrientationOfTheLauncherActivity() throws {
        let expected: [(UInt32?, ScreenOrientation, String)] = [
            (1, .portrait, "portrait"),
            (7, .portrait, "sensorPortrait"),
            (0, .landscape, "landscape"),
            (6, .landscape, "sensorLandscape"),
            (11, .landscape, "userLandscape"),
            (4, .free, "sensor: no fija eje"),
            (nil, .free, "sin el atributo")
        ]

        for (raw, orientation, description) in expected {
            let fixture = try TemporaryFixture()
            let apk = try makeApk(
                in: fixture,
                named: "juego.apk",
                manifest: makeManifest(utf8: false, orientation: raw),
                extraEntries: ["classes.dex": Data("dex".utf8)]
            )

            let facts = ApkInspector.inspect(apk)
            try expect(facts.orientation == orientation,
                       "\(description) debe leerse como \(orientation), no \(facts.orientation)")
            // Leer la orientación no puede haber estropeado lo demás.
            try expect(facts.packageName == "com.ejemplo.app", "\(description): el paquete sigue ahí")
        }
    }

    private static func testOrientationMappingAndManualChoice() throws {
        try expect(ScreenOrientation.portrait.deviceRotation == 0, "vertical es la postura natural")
        try expect(ScreenOrientation.landscape.deviceRotation == 1, "horizontal es un cuarto de vuelta")
        try expect(ScreenOrientation.free.deviceRotation == nil,
                   "sin postura fija no se bloquea el giro: decide el aparato")

        // El conmutador manda sobre lo que diga el .apk; en automático manda el .apk.
        try expect(RotationChoice.automatic.resolved(declaring: .landscape) == .landscape,
                   "en automático se respeta lo que pide el .apk")
        try expect(RotationChoice.portrait.resolved(declaring: .landscape) == .portrait,
                   "elegir a mano gana sobre el manifiesto")
        try expect(RotationChoice.automatic.resolved(declaring: .free) == .free,
                   "si el .apk no fija nada, en automático se deja girar")
    }

    /// Todo lo de arriba usa `.apk` fabricados aquí. Esto lo prueba contra uno de verdad, hecho
    /// por `aapt2`, que es quien escribe los manifiestos del mundo real: mis fixtures podrían
    /// compartir un malentendido con mi lector y ninguno de los dos se enteraría.
    ///
    /// Busca en Descargas y se salta sola si no hay ninguno: la máquina de otro no tiene por qué
    /// tener un `.apk` a mano.
    private static func testReadsARealApkIfThereIsOneAround() throws {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let apks = ((try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "apk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let apk = apks.first else {
            print("SKIP prueba con un .apk real (no hay ninguno en Descargas)")
            return
        }

        let facts = ApkInspector.inspect(apk)
        print("""
              INFO \(apk.lastPathComponent): \
              paquete=\(facts.packageName ?? "—") \
              versión=\(facts.versionName ?? "—") \
              minSdk=\(facts.minSdk.map(String.init) ?? "—") \
              abis=\(facts.abis.isEmpty ? "ninguno" : facts.abis.joined(separator: "/")) \
              postura=\(facts.orientation)
              """)

        try expect(!facts.readFailed, "un .apk real debe leerse")
        try expect(facts.packageName?.contains(".") == true,
                   "el nombre de paquete de una app real lleva puntos: \(facts.packageName ?? "nada")")
        try expect(facts.versionName != nil, "una app real declara versión")
        try expect(facts.minSdk != nil, "y un Android mínimo")
    }

    // MARK: - Construcción de un .apk a mano

    static func makeApk(
        in fixture: TemporaryFixture,
        named name: String,
        manifest: Data?,
        extraEntries: [String: Data],
        deflate deflated: Bool = false
    ) throws -> URL {
        var entries: [(String, Data)] = []
        if let manifest { entries.append(("AndroidManifest.xml", manifest)) }
        entries.append(contentsOf: extraEntries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })

        let url = fixture.directoryURL.appendingPathComponent(name)
        try zip(entries, deflated: deflated).write(to: url)
        return url
    }

    /// Zip mínimo: cabecera local por entrada, directorio central detrás y el bloque final.
    /// Con `deflated`, las entradas van comprimidas (método 8), que es como vienen de verdad.
    private static func zip(_ entries: [(name: String, data: Data)], deflated: Bool = false) -> Data {
        var output = Data()
        var directory = Data()
        let method: UInt16 = deflated ? 8 : 0

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let payload = deflated ? deflate(entry.data) : entry.data
            let offset = UInt32(output.count)

            output += le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
            output += le32(crc32(entry.data)) + le32(UInt32(payload.count)) + le32(UInt32(entry.data.count))
            output += le16(UInt16(nameBytes.count)) + le16(0) + nameBytes + payload

            directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0)
            directory += le32(crc32(entry.data)) + le32(UInt32(payload.count)) + le32(UInt32(entry.data.count))
            directory += le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            directory += le32(0) + le32(offset) + nameBytes
        }

        let directoryOffset = UInt32(output.count)
        output += directory
        output += le32(0x0605_4B50) + le16(0) + le16(0)
        output += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        output += le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0)
        return output
    }

    /// DEFLATE en crudo, que es lo que guarda un zip. `COMPRESSION_ZLIB` de Apple es justo eso.
    private static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 128
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(written)
    }

    // MARK: - Construcción de un AndroidManifest.xml binario

    /// Las cadenas van en el orden que exige el formato: primero los nombres de atributo, porque
    /// el mapa de recursos se indexa por su posición en el depósito.
    private static let poolStrings = [
        // 0-5: nombres de atributo. El mapa de recursos se indexa por su posición aquí, así que
        // tienen que ir los primeros.
        "versionCode", "versionName", "minSdkVersion", "name", "screenOrientation", "package",
        // 6 en adelante: nombres de elemento y valores.
        "manifest", "uses-sdk", "com.ejemplo.app", "1.4.2", "android",
        "application", "activity", "intent-filter", "category",
        "android.intent.category.LAUNCHER", "com.ejemplo.MainActivity"
    ]
    private static let resourceIDs: [UInt32] = [
        0x0101_021B, 0x0101_021C, 0x0101_020C, 0x0101_0003, 0x0101_001E, 0
    ]

    /// `orientation` es el valor crudo de `android:screenOrientation`; `nil` lo omite, como hace
    /// un `.apk` que no fija ninguna postura.
    static func makeManifest(utf8: Bool, orientation: UInt32? = nil) -> Data {
        var body = stringPool(utf8: utf8) + resourceMap()

        // <manifest package="com.ejemplo.app" android:versionCode="42" android:versionName="1.4.2">
        body += element(name: 6, attributes: [
            (ns: -1, name: 5, raw: 8, type: 0x03, data: 8),
            (ns: 10, name: 0, raw: -1, type: 0x10, data: 42),
            (ns: 10, name: 1, raw: 9, type: 0x03, data: 9)
        ])
        // <uses-sdk android:minSdkVersion="26"/>
        body += element(name: 7, attributes: [
            (ns: 10, name: 2, raw: -1, type: 0x10, data: 26)
        ])
        body += endElement(name: 7)

        //   <application>
        //     <activity android:name="com.ejemplo.MainActivity" android:screenOrientation="…">
        //       <intent-filter>
        //         <category android:name="android.intent.category.LAUNCHER"/>
        body += element(name: 11, attributes: [])

        var activityAttributes: [(ns: Int32, name: Int32, raw: Int32, type: UInt8, data: UInt32)] = [
            (ns: 10, name: 3, raw: 16, type: 0x03, data: 16)
        ]
        if let orientation {
            activityAttributes.append((ns: 10, name: 4, raw: -1, type: 0x10, data: orientation))
        }
        body += element(name: 12, attributes: activityAttributes)
        body += element(name: 13, attributes: [])
        body += element(name: 14, attributes: [
            (ns: 10, name: 3, raw: 15, type: 0x03, data: 15)
        ])
        body += endElement(name: 14)
        body += endElement(name: 13)
        body += endElement(name: 12)
        body += endElement(name: 11)
        body += endElement(name: 6)

        return le16(0x0003) + le16(8) + le32(UInt32(body.count + 8)) + body
    }

    private static func stringPool(utf8: Bool) -> Data {
        var offsets = Data()
        var strings = Data()

        for text in poolStrings {
            offsets += le32(UInt32(strings.count))
            if utf8 {
                let bytes = Data(text.utf8)
                // Dos longitudes de un byte —cuenta de caracteres y de bytes— y un cero al final.
                strings += Data([UInt8(text.unicodeScalars.count), UInt8(bytes.count)]) + bytes + Data([0])
            } else {
                let units = Array(text.utf16)
                strings += le16(UInt16(units.count))
                for unit in units { strings += le16(unit) }
                strings += le16(0)
            }
        }
        while strings.count % 4 != 0 { strings += Data([0]) }

        let stringsStart = UInt32(28 + offsets.count)
        let size = stringsStart + UInt32(strings.count)

        return le16(0x0001) + le16(28) + le32(size)
            + le32(UInt32(poolStrings.count)) + le32(0)
            + le32(utf8 ? 0x100 : 0)
            + le32(stringsStart) + le32(0)
            + offsets + strings
    }

    private static func resourceMap() -> Data {
        le16(0x0180) + le16(8) + le32(UInt32(8 + resourceIDs.count * 4))
            + resourceIDs.reduce(into: Data()) { $0 += le32($1) }
    }

    private static func element(
        name: Int32,
        attributes: [(ns: Int32, name: Int32, raw: Int32, type: UInt8, data: UInt32)]
    ) -> Data {
        var body = Data()
        for attribute in attributes {
            body += le32(UInt32(bitPattern: attribute.ns))
            body += le32(UInt32(bitPattern: attribute.name))
            body += le32(UInt32(bitPattern: attribute.raw))
            body += le16(8) + Data([0, attribute.type]) + le32(attribute.data)
        }

        return le16(0x0102) + le16(16) + le32(UInt32(36 + body.count))
            + le32(1) + le32(0xFFFF_FFFF)
            + le32(UInt32(bitPattern: -1)) + le32(UInt32(bitPattern: name))
            + le16(20) + le16(20) + le16(UInt16(attributes.count))
            + le16(0) + le16(0) + le16(0)
            + body
    }

    /// Etiqueta de cierre: la misma cabecera de nodo que la de apertura, con espacio de nombres
    /// y nombre detrás, y nada más.
    private static func endElement(name: Int32) -> Data {
        le16(0x0103) + le16(16) + le32(24)
            + le32(1) + le32(0xFFFF_FFFF)
            + le32(UInt32(bitPattern: -1)) + le32(UInt32(bitPattern: name))
    }

    // MARK: - Utilidades

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
