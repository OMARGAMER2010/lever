import Foundation

/// Construye las órdenes de `adb` y del emulador, y entiende lo que contestan.
///
/// La diferencia de fondo con Wine: un `.exe` se ejecuta *aquí*, dentro del Mac. Un `.apk` no se
/// ejecuta en ninguna parte por sí solo — hay que **instalarlo en un aparato**, sea un emulador
/// arrancado o un móvil enchufado por USB. Por eso esta pestaña tiene algo que las otras dos no
/// necesitan: elegir destino.
public enum AndroidLauncher {
    /// Carpeta donde el SDK guarda los emuladores creados.
    public static var avdHomeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd", isDirectory: true)
    }

    /// Una app abierta desde el Finder recibe un `PATH` mínimo; `adb` y el emulador lanzan
    /// procesos hijos y necesitan encontrarse a sí mismos.
    public static func environment(sdkRoot: URL? = nil) -> [String: String] {
        var environment = [
            "PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":"),
            "HOME": NSHomeDirectory()
        ]
        if let sdkRoot {
            environment["ANDROID_SDK_ROOT"] = sdkRoot.path
            // `ANDROID_HOME` está oficialmente obsoleto, pero varias versiones del emulador
            // siguen leyendo solo esa.
            environment["ANDROID_HOME"] = sdkRoot.path
        }
        return environment
    }

    /// El SDK es la carpeta que contiene al binario: `<sdk>/platform-tools/adb`, `<sdk>/emulator/emulator`.
    public static func sdkRoot(containing tool: URL) -> URL? {
        let parent = tool.deletingLastPathComponent()
        let name = parent.lastPathComponent
        guard name == "platform-tools" || name == "emulator" else { return nil }
        return parent.deletingLastPathComponent()
    }

    // MARK: - Órdenes

    public static func listDevicesCommand(adb: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: ["devices", "-l"],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    /// Pregunta al aparato por sus datos en una sola ida y vuelta: `adb shell` es lento y hacer
    /// cuatro llamadas sueltas se nota al refrescar la lista.
    ///
    /// El orden de las líneas de salida es el orden de los `getprop`, y se lee por posición.
    public static func propertiesCommand(adb: URL, serial: String) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: [
                "-s", serial, "shell",
                "getprop ro.product.cpu.abilist;"
                    + "getprop ro.build.version.sdk;"
                    + "getprop ro.product.model;"
                    + "getprop ro.build.version.release"
            ],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    /// `-r` reinstala conservando los datos si la app ya estaba. Sin `-r`, reinstalar falla.
    public static func installCommand(adb: URL, serial: String, apk: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: ["-s", serial, "install", "-r", apk.path],
            currentDirectoryURL: apk.deletingLastPathComponent(),
            environment: environment()
        )
    }

    /// Abre la app recién instalada. `monkey` lanza la actividad marcada como LAUNCHER sin que
    /// haya que averiguar su nombre, que cambia en cada app.
    public static func launchCommand(adb: URL, serial: String, package: String) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: [
                "-s", serial, "shell",
                "monkey -p \(package) -c android.intent.category.LAUNCHER 1"
            ],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    public static func uninstallCommand(adb: URL, serial: String, package: String) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: ["-s", serial, "uninstall", package],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    /// Fija la postura de la pantalla del aparato.
    ///
    /// `accelerometer_rotation 0` apaga el giro automático y `user_rotation` fija la postura en
    /// cuartos de vuelta desde la natural (0 = vertical, 1 = apaisado). Es lo que hace el propio
    /// Android cuando bloqueas la rotación desde los ajustes rápidos, así que funciona igual en
    /// un emulador que en un móvil.
    ///
    /// Ojo: si la app declara una postura fija en su manifiesto, Android la respeta por encima de
    /// esto. Girar el aparato igual sirve, porque evita que la ventana quede apaisada con el
    /// juego vertical dentro y franjas negras a los lados.
    public static func lockRotationCommand(adb: URL, serial: String, quarterTurns: Int) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: [
                "-s", serial, "shell",
                "settings put system accelerometer_rotation 0;"
                    + "settings put system user_rotation \(quarterTurns)"
            ],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    /// Devuelve el giro automático al aparato: la app decide, como en un móvil normal.
    public static func freeRotationCommand(adb: URL, serial: String) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: ["-s", serial, "shell", "settings put system accelerometer_rotation 1"],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    /// Espera a que el aparato termine de arrancar. Un emulador aparece en `adb devices` mucho
    /// antes de poder instalar nada: `sys.boot_completed` es la señal de que ya está listo.
    public static func waitForBootCommand(adb: URL, serial: String) -> ProcessCommand {
        ProcessCommand(
            executableURL: adb,
            arguments: ["-s", serial, "shell", "getprop sys.boot_completed"],
            currentDirectoryURL: nil,
            environment: environment()
        )
    }

    public static func hasFinishedBooting(_ output: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    public static func listAvdsCommand(emulator: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: emulator,
            arguments: ["-list-avds"],
            currentDirectoryURL: nil,
            environment: environment(sdkRoot: sdkRoot(containing: emulator))
        )
    }

    /// Arranca un emulador. Tarda entre uno y tres minutos en estar listo y no termina: se queda
    /// abierto como una ventana más, así que la app no espera a que salga.
    ///
    /// `-no-snapshot-save` evita que al cerrarlo se guarde un estado de varios gigas, que en un
    /// disco justo es la diferencia entre que quepa y que no.
    ///
    /// La postura no se pide aquí: el emulador no tiene ninguna bandera para eso. Se fija con
    /// `lockRotationCommand` cuando el aparato ha terminado de arrancar, que además funciona
    /// igual en un móvil enchufado.
    public static func startEmulatorCommand(emulator: URL, avd: String) -> ProcessCommand {
        ProcessCommand(
            executableURL: emulator,
            arguments: ["-avd", avd, "-no-snapshot-save"],
            currentDirectoryURL: nil,
            environment: environment(sdkRoot: sdkRoot(containing: emulator))
        )
    }

    /// Instala el SDK de Android y crea el emulador. Es un guion aparte y no una orden suelta
    /// porque `sdkmanager` pide aceptar licencias por la entrada estándar, y aquí los procesos se
    /// lanzan con la entrada cerrada para que nada se cuelgue esperando. El guion se encarga.
    public static func setUpEmulatorCommand(script: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path],
            currentDirectoryURL: script.deletingLastPathComponent().deletingLastPathComponent(),
            environment: environment()
        )
    }

    // MARK: - Lectura de respuestas

    /// Estados que `adb` puede escribir en la segunda columna. Es una lista cerrada en su
    /// código, y comprobarla es lo que separa un aparato de la cháchara del propio `adb`
    /// («* daemon started successfully», «adb server version … killing»), que por lo demás
    /// tiene la misma forma: dos palabras separadas por espacios.
    private static let deviceStates: Set<String> = [
        "device", "unauthorized", "offline", "bootloader", "recovery", "rescue",
        "sideload", "host", "connecting", "authorizing", "unknown", "no"
    ]

    /// Lee la tabla de `adb devices -l`.
    ///
    /// Formato: serie, espacios, estado, y detrás pares `clave:valor`.
    public static func devices(fromListing output: String) -> [AndroidDevice] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap { line -> AndroidDevice? in
                guard !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 2, deviceStates.contains(fields[1]) else { return nil }

                let availability: AndroidDevice.Availability
                switch fields[1] {
                case "device": availability = .ready
                case "unauthorized": availability = .unauthorized
                // `offline`, `no permissions`, `bootloader`, `recovery`, `sideload`: visible pero
                // sin poder instalar. No hace falta distinguirlos para decidir qué se puede hacer.
                default: availability = .offline
                }

                let model = fields
                    .first { $0.hasPrefix("model:") }
                    .map { String($0.dropFirst("model:".count)) }

                return AndroidDevice(serial: fields[0], availability: availability, model: model)
            }
    }

    /// Lee las cuatro líneas de `propertiesCommand`, en su orden.
    public static func properties(fromOutput output: String) -> (abis: [String], sdk: Int?, model: String?, release: String?) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        func line(_ index: Int) -> String? {
            guard index < lines.count, !lines[index].isEmpty else { return nil }
            return lines[index]
        }

        let abis = (line(0) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return (abis, line(1).flatMap(Int.init), line(2), line(3))
    }

    public static func avdNames(fromListing output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // El emulador escribe avisos por la misma salida («INFO | Storing crashdata…»).
            .filter { !$0.isEmpty && !$0.contains("|") && !$0.hasPrefix("WARNING") }
    }

    /// Motivo por el que Android rechazó la instalación, tal como lo devuelve `adb`.
    public enum InstallFailure: Equatable, Sendable {
        case noMatchingAbis
        case olderSdk
        case signatureMismatch
        case versionDowngrade
        case noSpace
        case notSigned
        case blockedByDevice
        case other(String)
    }

    /// `adb install` no siempre devuelve un código distinto de cero cuando falla: algunas
    /// versiones terminan en 0 y escriben «Failure [...]» por la salida. Hay que leer el texto.
    public static func installFailure(inOutput output: String) -> InstallFailure? {
        guard let range = output.range(of: #"(Failure|Error)\s*\[?[A-Z_]*"#, options: .regularExpression) else {
            return nil
        }

        let codes: [(String, InstallFailure)] = [
            ("INSTALL_FAILED_NO_MATCHING_ABIS", .noMatchingAbis),
            ("INSTALL_FAILED_OLDER_SDK", .olderSdk),
            ("INSTALL_FAILED_UPDATE_INCOMPATIBLE", .signatureMismatch),
            ("INSTALL_FAILED_VERSION_DOWNGRADE", .versionDowngrade),
            ("INSTALL_FAILED_INSUFFICIENT_STORAGE", .noSpace),
            ("INSTALL_PARSE_FAILED_NO_CERTIFICATES", .notSigned),
            ("INSTALL_FAILED_USER_RESTRICTED", .blockedByDevice),
            ("INSTALL_FAILED_VERIFICATION_FAILURE", .blockedByDevice)
        ]

        for (code, failure) in codes where output.contains(code) {
            return failure
        }

        return .other(String(output[range]).trimmingCharacters(in: .whitespaces))
    }

    /// `monkey` avisa cuando la app no tiene ninguna pantalla que abrir: no es un fallo de la
    /// instalación, pero el usuario no vería nada y merece saberlo.
    public static func hasNoLauncherActivity(inOutput output: String) -> Bool {
        output.contains("No activities found") || output.contains("monkey aborted")
    }
}
