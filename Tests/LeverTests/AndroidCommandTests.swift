import Foundation
import LeverCore

/// Comprueba las órdenes que se le mandan a `adb` y la lectura de lo que contesta.
///
/// Su salida es texto sin formato pensado para personas, y cambia poco pero cambia: leerla mal
/// no da un error, da un dato equivocado —el peor fallo posible aquí, porque decidiría por el
/// usuario si su app va a instalarse o no.
enum AndroidCommandTests {
    static func run() throws {
        try testReadsTheDeviceTable()
        try testReadsDeviceProperties()
        try testReadsAvdNames()
        try testRecognisesInstallFailures()
        try testBuildsAdbCommands()
        try testFindsTheSdkAroundItsTools()
    }

    private static func testReadsTheDeviceTable() throws {
        let listing = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a
        R5CT30ABCDE            unauthorized usb:1-2
        1A2B3C4D               offline
        adb server version (41) doesn't match this client (39); killing...
        """

        let devices = AndroidLauncher.devices(fromListing: listing)
        try expect(devices.count == 3,
                   "tres aparatos: ni el encabezado ni la cháchara de adb cuentan: \(devices.count)")

        try expect(devices[0].serial == "emulator-5554", "el serie es la primera columna")
        try expect(devices[0].availability == .ready, "«device» significa listo")
        try expect(devices[0].isEmulator, "el prefijo emulator- lo delata")
        try expect(devices[0].displayName == "sdk gphone64 arm64", "el modelo se lee de model:")

        try expect(devices[1].availability == .unauthorized,
                   "un móvil sin autorizar no es un fallo: le falta un paso al usuario")
        try expect(!devices[1].isEmulator, "un serie normal es un móvil")
        try expect(devices[1].displayName == "R5CT30ABCDE", "sin modelo se enseña el serie")
        try expect(devices[2].availability == .offline, "«offline» no admite instalaciones")
    }

    private static func testReadsDeviceProperties() throws {
        let output = """
        arm64-v8a,armeabi-v7a
        34
        Pixel 7
        14
        """

        let properties = AndroidLauncher.properties(fromOutput: output)
        try expect(properties.abis == ["arm64-v8a", "armeabi-v7a"], "la lista de ABIs va separada por comas")
        try expect(properties.sdk == 34, "el nivel de API es un número")
        try expect(properties.model == "Pixel 7", "el modelo se enseña tal cual")
        try expect(properties.release == "14", "y la versión de Android también")

        // Un aparato que no conteste a algo no debe inventar el resto.
        let partial = AndroidLauncher.properties(fromOutput: "arm64-v8a\n")
        try expect(partial.abis == ["arm64-v8a"], "lo que sí contestó se conserva")
        try expect(partial.sdk == nil, "lo que no contestó se queda vacío, no se rellena")
    }

    private static func testReadsAvdNames() throws {
        let listing = """
        INFO    | Storing crashdata in: /tmp/avd
        Pixel_7_API_34
        Tablet_API_33
        """
        try expect(AndroidLauncher.avdNames(fromListing: listing) == ["Pixel_7_API_34", "Tablet_API_33"],
                   "los avisos del emulador salen por la misma salida y hay que descartarlos")
    }

    /// `adb install` no siempre devuelve un código distinto de cero al fallar: hay versiones que
    /// terminan en 0 y escriben «Failure [...]». Manda el texto.
    private static func testRecognisesInstallFailures() throws {
        let cases: [(String, AndroidLauncher.InstallFailure)] = [
            ("Performing Streamed Install\nFailure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries]",
             .noMatchingAbis),
            ("Failure [INSTALL_FAILED_OLDER_SDK]", .olderSdk),
            ("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package signatures do not match]", .signatureMismatch),
            ("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]", .versionDowngrade),
            ("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]", .noSpace),
            ("Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES]", .notSigned),
            ("Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]", .blockedByDevice)
        ]

        for (output, expected) in cases {
            try expect(AndroidLauncher.installFailure(inOutput: output) == expected,
                       "«\(output.prefix(45))…» debe reconocerse")
        }

        try expect(AndroidLauncher.installFailure(inOutput: "Performing Streamed Install\nSuccess") == nil,
                   "una instalación correcta no debe verse como fallo")

        // Un código que no está en la lista se enseña tal cual en vez de callarlo.
        guard case .other = AndroidLauncher.installFailure(inOutput: "Failure [INSTALL_FAILED_INVALID_APK]") else {
            throw TestFailure(description: "un código desconocido debe llegar al usuario, no perderse")
        }

        try expect(AndroidLauncher.hasNoLauncherActivity(inOutput: "Error: No activities found to run"),
                   "una app sin pantalla propia se instala pero no abre nada, y hay que decirlo")
    }

    private static func testBuildsAdbCommands() throws {
        let adb = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        let apk = URL(fileURLWithPath: "/Users/yo/Descargas/app.apk")

        let install = AndroidLauncher.installCommand(adb: adb, serial: "emulator-5554", apk: apk)
        try expect(install.arguments == ["-s", "emulator-5554", "install", "-r", apk.path],
                   "-s elige el aparato y -r reinstala conservando los datos: \(install.arguments)")

        let launch = AndroidLauncher.launchCommand(adb: adb, serial: "R5", package: "com.ejemplo.app")
        try expect(launch.arguments.last?.contains("com.ejemplo.app") == true, "abrir usa el nombre de paquete")

        let uninstall = AndroidLauncher.uninstallCommand(adb: adb, serial: "R5", package: "com.ejemplo.app")
        try expect(uninstall.arguments == ["-s", "R5", "uninstall", "com.ejemplo.app"],
                   "desinstalar solo toca el paquete indicado")

        // Una app abierta desde el Finder recibe un PATH mínimo y adb no se encontraría a sí mismo.
        try expect(install.environment?["PATH"]?.contains("/opt/homebrew/bin") == true,
                   "el PATH se rehace a mano")
    }

    private static func testFindsTheSdkAroundItsTools() throws {
        let emulator = URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools/emulator/emulator")
        try expect(AndroidLauncher.sdkRoot(containing: emulator)?.path == "/opt/homebrew/share/android-commandlinetools",
                   "el SDK es la carpeta que contiene emulator/")

        let adb = URL(fileURLWithPath: "/Users/yo/Library/Android/sdk/platform-tools/adb")
        try expect(AndroidLauncher.sdkRoot(containing: adb)?.path == "/Users/yo/Library/Android/sdk",
                   "y también la que contiene platform-tools/")

        // El `adb` que enlaza Homebrew en su bin no está dentro de ningún SDK: no hay que inventarlo.
        try expect(AndroidLauncher.sdkRoot(containing: URL(fileURLWithPath: "/opt/homebrew/bin/adb")) == nil,
                   "un binario suelto no implica que haya un SDK alrededor")

        let started = AndroidLauncher.startEmulatorCommand(emulator: emulator, avd: "Pixel_7_API_34")
        try expect(started.environment?["ANDROID_SDK_ROOT"] == "/opt/homebrew/share/android-commandlinetools",
                   "el emulador necesita saber dónde está su SDK")
    }
}
