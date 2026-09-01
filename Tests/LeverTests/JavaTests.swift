import Foundation
import LeverCore

/// Pruebas del reconocimiento de juegos de Java y de lo que hace falta para montarlos.
///
/// Lo delicado aquí no es el bytecode —ese ya es portable— sino todo lo que lo rodea: leer un
/// manifiesto que parte sus líneas a 72 bytes, saber qué Java pide el juego sin preguntárselo a
/// nadie, y nombrar bien las descargas de Maven, donde el archivo de Intel se llama distinto de
/// como uno esperaría.
enum JavaTests {
    static func run() throws {
        try parsesAFoldedManifest()
        try readsTheJavaVersionItNeeds()
        try choosesARuntimeThatCanReadIt()
        try namesEveryLwjglDownloadCorrectly()
        try recognisesALaunch4jExe()
        try recognisesAJarBesideTheExe()
        try needsSomethingToLaunch()
        try findsTheNativesBuiltForWindows()
        try locatesJarsThroughASymlinkedFolder()
        try theLauncherStartsTheGameProperly()
        try infoPlistNamesTheApp()
    }

    // MARK: - Manifiesto

    /// Un manifiesto parte las líneas a 72 bytes y sigue en la siguiente con un espacio delante.
    /// Leerlo línea a línea sin volver a juntarlas parte los classpath por la mitad, y la mitad de
    /// un nombre de archivo no abre nada.
    static func parsesAFoldedManifest() throws {
        let texto = """
        Manifest-Version: 1.0
        Main-Class: prueba.Juego
        Class-Path: lib/lwjgl-3.3.6.jar lib/lwjgl-glfw-3.3.6.jar lib/lwjgl-openg
         l-3.3.6.jar
        Created-By: 25.0.3 (Eclipse Adoptium)

        """
        let pares = JavaInspector.parseManifest(texto)
        try expect(pares["Main-Class"] == "prueba.Juego", "la clase que arranca")
        try expect(pares["Class-Path"]?.hasSuffix("lib/lwjgl-opengl-3.3.6.jar") == true,
                   "la línea partida hay que volver a juntarla: \(pares["Class-Path"] ?? "")")
        try expect(pares["Created-By"] == "25.0.3 (Eclipse Adoptium)", "los dos puntos del valor no cortan")
    }

    // MARK: - Qué Java pide

    static func readsTheJavaVersionItNeeds() throws {
        // La tabla es del propio JVM: Java 8 escribe 52 y Java 17 escribe 61.
        try expect(JavaFeature.readingClassFile(major: 52) == JavaFeature(8), "52 es Java 8")
        try expect(JavaFeature.readingClassFile(major: 61) == JavaFeature(17), "61 es Java 17")
        try expect(JavaFeature.readingClassFile(major: 65) == JavaFeature(21), "65 es Java 21")
        try expect(JavaFeature.readingClassFile(major: 12) == nil, "por debajo de 45 no hay clase que valga")

        // Java 8 se numeraba `1.8.0_292`: ahí el número que importa es el segundo.
        try expect(JavaInspector.featureVersion(inRelease: "JAVA_VERSION=\"1.8.0_292\"") == JavaFeature(8),
                   "la numeración vieja de Java 8")
        try expect(JavaInspector.featureVersion(inRelease: "OS_NAME=\"Windows\"\nJAVA_VERSION=\"17.0.2\"")
                    == JavaFeature(17), "la moderna")
        try expect(JavaInspector.featureVersion(inRelease: "OS_NAME=\"Windows\"") == nil,
                   "un release sin la clave no dice nada")
    }

    /// Temurin solo mantiene publicadas las de soporte largo. Pedirle una que no esté da un 404 a
    /// mitad del traslado, así que se sube a la siguiente que sepa leer ese bytecode.
    static func choosesARuntimeThatCanReadIt() throws {
        try expect(JavaFeature(17).runtimeToDownload == JavaFeature(17), "la 17 existe tal cual")
        try expect(JavaFeature(9).runtimeToDownload == JavaFeature(11), "la 9 no: se sube a la 11")
        try expect(JavaFeature(18).runtimeToDownload == JavaFeature(21), "y la 18 a la 21")
        try expect(JavaFeature(99).runtimeToDownload == nil, "de un bytecode del futuro no se puede decir nada")

        // Java 8 es de 2014 y el primer Mac de ARM de 2020: Temurin no publica esa combinación.
        try expect(JavaFeature(8).architecture(appleSilicon: true) == "x64",
                   "un juego de Java 8 baja el de Intel aunque el Mac sea de ARM")
        try expect(JavaFeature(8).needsRosetta(appleSilicon: true), "y por tanto va traducido")
        try expect(JavaFeature(11).architecture(appleSilicon: true) == "aarch64", "de la 11 en adelante, nativo")
        try expect(!JavaFeature(17).needsRosetta(appleSilicon: true), "y sin Rosetta")
        try expect(JavaFeature(17).architecture(appleSilicon: false) == "x64", "en un Mac de Intel, Intel")
        try expect(JavaFeature(17).macDownloadURL(appleSilicon: true).absoluteString
                    == "https://api.adoptium.net/v3/binary/latest/17/ga/mac/aarch64/jre/hotspot/normal/eclipse",
                   "la dirección de Temurin: \(JavaFeature(17).macDownloadURL(appleSilicon: true))")
    }

    // MARK: - Librerías nativas

    static func namesEveryLwjglDownloadCorrectly() throws {
        let nucleo = LwjglNatives(module: "lwjgl", version: "3.3.6",
                                  relativePath: "lib/lwjgl-3.3.6-natives-windows.jar")
        try expect(nucleo.macAssetName(appleSilicon: true) == "lwjgl-3.3.6-natives-macos-arm64.jar",
                   "el de ARM lleva sufijo: \(nucleo.macAssetName(appleSilicon: true))")
        // El de Intel se llama `natives-macos` a secas. Ponerle `-x64` da un 404.
        try expect(nucleo.macAssetName(appleSilicon: false) == "lwjgl-3.3.6-natives-macos.jar",
                   "el de Intel no lleva ninguno: \(nucleo.macAssetName(appleSilicon: false))")
        try expect(nucleo.macDownloadURL(appleSilicon: true).absoluteString
                    == "https://repo1.maven.org/maven2/org/lwjgl/lwjgl/3.3.6/lwjgl-3.3.6-natives-macos-arm64.jar",
                   "la dirección de Maven: \(nucleo.macDownloadURL(appleSilicon: true))")

        let glfw = LwjglNatives(module: "lwjgl-glfw", version: "3.3.6", relativePath: "lib/x.jar")
        try expect(glfw.macDownloadURL(appleSilicon: true).absoluteString
                    == "https://repo1.maven.org/maven2/org/lwjgl/lwjgl-glfw/3.3.6/lwjgl-glfw-3.3.6-natives-macos-arm64.jar",
                   "cada módulo es un artefacto suyo: \(glfw.macDownloadURL(appleSilicon: true))")
    }

    // MARK: - Reconocimiento

    /// Launch4j deja su lanzador nativo delante y el jar detrás, sin ningún pie que lo diga.
    static func recognisesALaunch4jExe() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, fused: true)
        guard case .java(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció el .exe de Launch4j")
        }
        try expect(game.mainClass == "prueba.Juego", "la clase que arranca sale del manifiesto")
        try expect(game.required == JavaFeature(17), "y la versión, del bytecode: \(game.required)")
        try expect(game.requiredFrom == .classFile, "aquí no hay jre/ que mirar")
        if case .fused = game.launchJar {} else {
            throw TestFailure(description: "el jar iba pegado al .exe, no suelto")
        }
        try expect(!game.gameEntries.contains("Game.exe"), "el lanzador de Windows no viaja")
    }

    static func recognisesAJarBesideTheExe() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, fused: false, bundledRuntime: "1.8.0_292")
        guard case .java(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció el jar de al lado")
        }
        if case .sibling(let jar) = game.launchJar {
            try expect(jar.lastPathComponent == "Game.jar", "se elige el que se llama como el .exe")
        } else {
            throw TestFailure(description: "el jar estaba suelto, no pegado")
        }
        // El `jre/` que trae el juego manda sobre el bytecode: dice con qué lo probó su autor.
        try expect(game.required == JavaFeature(8), "gana el jre/ del reparto: \(game.required)")
        try expect(game.requiredFrom == .bundledRuntime, "y se sabe de dónde salió")
        try expect(!game.gameEntries.contains("jre"), "el jre/ de Windows se sustituye, no viaja")
        try expect(game.gameEntries.contains("Game.jar"), "el jar sí")
    }

    static func needsSomethingToLaunch() throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("suelto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Un jar sin `Main-Class` es una librería, no un juego: no hay nada que arrancar.
        try makeJar(at: root.appendingPathComponent("libreria.jar"),
                    manifest: ["Manifest-Version": "1.0"], files: [:])
        let exe = root.appendingPathComponent("Game.exe")
        try WindowsBinary(productVersion: (1, 0, 0, 0)).data.write(to: exe)
        try expect(PortableEngineDetector.detect(program: exe) == nil,
                   "sin Main-Class no se afirma que sea un juego de Java")
    }

    /// Se reconocen por `LWJGL-Platform` del manifiesto, no por el nombre del archivo: el nombre lo
    /// pone Maven y un reparto puede cambiarlo, pero el manifiesto lo escribe LWJGL.
    static func findsTheNativesBuiltForWindows() throws {
        let fixture = try TemporaryFixture()
        let exe = try makeGame(in: fixture, fused: true)
        guard case .java(let game)? = PortableEngineDetector.detect(program: exe) else {
            throw TestFailure(description: "no se reconoció")
        }
        try expect(game.lwjgl.map(\.module) == ["lwjgl", "lwjgl-glfw"],
                   "los dos módulos, en orden: \(game.lwjgl.map(\.module))")
        // `Implementation-Version` aquí pone «build 1»: la buena es `Specification-Version`.
        try expect(game.lwjgl.allSatisfy { $0.version == "3.3.6" }, "la versión sale de Specification-Version")
        try expect(game.needsMainThreadFlag, "trae GLFW, así que hará falta -XstartOnFirstThread")
        try expect(game.windowsLibraries == ["nativo.dll"],
                   "las .dll sueltas no tienen sustituto y se nombran: \(game.windowsLibraries)")
        // La ruta tiene que quedar relativa al reparto. Si sale absoluta, el porteador monta media
        // jerarquía del disco dentro del bundle y el juego arranca con el jar de Windows puesto.
        try expect(game.lwjgl.map(\.relativePath)
                    == ["lib/lwjgl-3.3.6-natives-windows.jar", "lib/lwjgl-glfw-3.3.6-natives-windows.jar"],
                   "rutas relativas al reparto: \(game.lwjgl.map(\.relativePath))")
    }

    /// En macOS `/var` es un enlace a `/private/var` y `/tmp` a `/private/tmp`. El enumerador de
    /// archivos devuelve la ruta ya resuelta y la carpeta de partida casi nunca lo está, así que
    /// restar cadenas para sacar la ruta relativa falla justo donde se prueba todo: en el temporal.
    static func locatesJarsThroughASymlinkedFolder() throws {
        let manager = FileManager.default
        // Se trabaja en `/tmp` a propósito, no en el temporal de las pruebas: `/tmp` es un enlace
        // a `/private/tmp`, y ese enlace es justo lo que hay que reproducir.
        let base = URL(fileURLWithPath: "/tmp").appendingPathComponent("lever-\(UUID().uuidString)")
        try manager.createDirectory(at: base.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appendingPathComponent("lib/a.jar"))

        guard let visto = manager.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "jar" }) else {
            throw TestFailure(description: "no se encontró el jar de prueba")
        }
        try expect(PortPaths.relativePath(of: visto, from: base) == "lib/a.jar",
                   "el enlace no debería estorbar: \(PortPaths.relativePath(of: visto, from: base) ?? "nil")")
        try expect(PortPaths.relativePath(of: base.deletingLastPathComponent()
                                            .appendingPathComponent("otro.jar"), from: base) == nil,
                   "lo que no cuelga de la carpeta no tiene ruta relativa dentro de ella")
    }

    // MARK: - Montaje

    static func theLauncherStartsTheGameProperly() throws {
        let conGlfw = juego(required: JavaFeature(17), appleSilicon: true, modules: ["lwjgl", "lwjgl-glfw"])
        let guion = JavaPorter.launcherScript(for: conGlfw, classPath: ["Juego.jar", "lib/lwjgl.jar"])
        try expect(guion.contains("exec "), "sin exec la JVM cuelga del shell y deja de ser el primer hilo")
        try expect(guion.contains("-XstartOnFirstThread"), "con GLFW hace falta")
        try expect(guion.contains("cd \"$aqui\""), "el juego busca sus datos por rutas relativas")
        try expect(guion.contains("-cp \"$aqui/Juego.jar:$aqui/lib/lwjgl.jar\""),
                   "el classpath se nombra entero, sin fiarse del manifiesto")
        try expect(guion.contains("prueba.Juego \"$@\""), "y se le pasan los argumentos")

        // Con AWT o Swing esa bandera estorba: su bucle de eventos quiere para sí el mismo hilo.
        let sinGlfw = juego(required: JavaFeature(17), appleSilicon: true, modules: [])
        try expect(!JavaPorter.launcherScript(for: sinGlfw, classPath: ["a.jar"]).contains("-XstartOnFirstThread"),
                   "sin GLFW no se pone")
    }

    static func infoPlistNamesTheApp() throws {
        let game = juego(required: JavaFeature(17), appleSilicon: true, modules: ["lwjgl-glfw"])
        guard let datos = JavaPorter.infoPlist(for: game, displayName: "El Faro Rojo", hasCustomIcon: false),
              let plist = (try? PropertyListSerialization.propertyList(from: datos, format: nil))
                as? [String: Any] else {
            throw TestFailure(description: "no se pudo escribir el Info.plist")
        }
        try expect(plist["CFBundleExecutable"] as? String == "El Faro Rojo", "el guion se llama como el juego")
        try expect(plist["CFBundleIdentifier"] as? String == "com.lever.java.Game",
                   "identificador propio: \(plist["CFBundleIdentifier"] ?? "")")
        try expect(plist["NSHighResolutionCapable"] as? Bool == true, "si no, la ventana sale borrosa")
        try expect(plist["CFBundleIconFile"] == nil, "sin icono no se declara ninguno")
    }

    // MARK: - Utilidades

    private static func juego(required: JavaFeature, appleSilicon: Bool, modules: [String]) -> JavaGame {
        JavaGame(
            executable: URL(fileURLWithPath: "/tmp/Game.exe"),
            root: URL(fileURLWithPath: "/tmp"),
            launchJar: .sibling(URL(fileURLWithPath: "/tmp/Game.jar")),
            mainClass: "prueba.Juego",
            gameEntries: ["Game.jar"],
            gameBytes: 1,
            required: required,
            requiredFrom: .classFile,
            lwjgl: modules.map { LwjglNatives(module: $0, version: "3.3.6", relativePath: "lib/\($0).jar") },
            windowsLibraries: [],
            appleSilicon: appleSilicon
        )
    }

    /// Arma una carpeta como la que exporta un juego de Java para Windows.
    @discardableResult
    private static func makeGame(
        in fixture: TemporaryFixture,
        fused: Bool,
        bundledRuntime: String? = nil
    ) throws -> URL {
        let manager = FileManager.default
        let root = fixture.directoryURL.appendingPathComponent("juego-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)

        let clase = "prueba/Juego.class"
        let jar = root.appendingPathComponent(fused ? "interior.jar" : "Game.jar")
        try makeJar(
            at: jar,
            manifest: ["Manifest-Version": "1.0", "Main-Class": "prueba.Juego",
                       "Class-Path": "lib/lwjgl-3.3.6.jar lib/lwjgl-3.3.6-natives-windows.jar"],
            files: [clase: classFile(major: 61)]
        )

        for (modulo, nombre) in [("lwjgl", "lwjgl-3.3.6-natives-windows.jar"),
                                 ("lwjgl-glfw", "lwjgl-glfw-3.3.6-natives-windows.jar")] {
            try makeJar(
                at: root.appendingPathComponent("lib/\(nombre)"),
                manifest: ["Manifest-Version": "1.0", "Implementation-Title": modulo,
                           "Implementation-Version": "build 1", "Specification-Version": "3.3.6",
                           "LWJGL-Platform": "windows/x64"],
                files: ["windows/x64/org/lwjgl/\(modulo).dll": Data("binario".utf8)]
            )
        }
        try Data("binario de windows".utf8).write(to: root.appendingPathComponent("nativo.dll"))

        if let bundledRuntime {
            let jre = root.appendingPathComponent("jre", isDirectory: true)
            try manager.createDirectory(at: jre.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data("JAVA_VERSION=\"\(bundledRuntime)\"\nOS_NAME=\"Windows\"\n".utf8)
                .write(to: jre.appendingPathComponent("release"))
            // El `jre/` de Windows trae sus propias DLL: no son del juego y no hay que nombrarlas.
            try Data("motor".utf8).write(to: jre.appendingPathComponent("bin/jvm.dll"))
        }

        let exe = root.appendingPathComponent("Game.exe")
        var datos = WindowsBinary(productVersion: (1, 0, 0, 0)).data
        if fused {
            datos += try Data(contentsOf: jar)
            try manager.removeItem(at: jar)
        }
        try datos.write(to: exe)
        return exe
    }

    /// Un `.class` con lo justo para que se le pueda leer la versión: la firma y los dos números.
    private static func classFile(major: Int) -> Data {
        Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, UInt8(major >> 8), UInt8(major & 0xff)])
    }

    /// Se comprime con `zip` de verdad: lo que hay que probar es que el lector aguanta lo que
    /// produce una herramienta real, no un ZIP escrito a mano para que le encaje.
    private static func makeJar(at destination: URL, manifest: [String: String], files: [String: Data]) throws {
        let manager = FileManager.default
        let taller = destination.deletingLastPathComponent()
            .appendingPathComponent("taller-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: taller.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let texto = manifest.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        try Data((texto + "\n\n").utf8).write(to: taller.appendingPathComponent("META-INF/MANIFEST.MF"))
        for (nombre, datos) in files {
            let archivo = taller.appendingPathComponent(nombre)
            try manager.createDirectory(at: archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try datos.write(to: archivo)
        }
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proceso.arguments = ["-q", "-r", destination.path, "."]
        proceso.currentDirectoryURL = taller
        proceso.standardOutput = FileHandle.nullDevice
        proceso.standardError = FileHandle.nullDevice
        try proceso.run()
        proceso.waitUntilExit()
        try manager.removeItem(at: taller)
        guard manager.fileExists(atPath: destination.path) else {
            throw TestFailure(description: "no se pudo crear el jar de prueba")
        }
    }
}
