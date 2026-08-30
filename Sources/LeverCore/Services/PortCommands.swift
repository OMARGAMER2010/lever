import Foundation

/// Órdenes del sistema que usan todos los traslados, sea cual sea el motor.
///
/// Están juntas y sueltas a propósito: es el punto por donde entran las pruebas sin tener que
/// descargar un motor de verdad.
public enum PortCommands {
    public static func download(_ url: URL, into file: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            // `--fail` convierte un 404 en error, en vez de en un archivo con una página HTML
            // dentro que reventaría luego al descomprimir.
            arguments: ["-L", "--fail", "--progress-bar", "-o", file.path, url.absoluteString],
            currentDirectoryURL: nil
        )
    }

    public static func unzip(_ archive: URL, into folder: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", "-o", archive.path, "-d", folder.path],
            currentDirectoryURL: nil
        )
    }

    public static func sign(_ target: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", target.path],
            currentDirectoryURL: nil
        )
    }

    /// Firma un bundle con todo lo que lleve dentro, de dentro hacia fuera.
    ///
    /// Hace falta cuando el motor trae bundles anidados —NW.js esconde cuatro `.app` de ayudantes
    /// dentro de su framework—. A esos hay que firmarlos como bundles, no archivo a archivo: si
    /// se sellan sueltos, el `.app` de fuera queda «not signed at all» y macOS no arranca los
    /// procesos hijos, que en Chromium son los que dibujan.
    public static func signNested(_ target: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--deep", "--sign", "-", target.path],
            currentDirectoryURL: nil
        )
    }

    /// Sin esto macOS trata el `.app` como descargado y pide permiso al abrirlo.
    public static func clearQuarantine(_ target: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-cr", target.path],
            currentDirectoryURL: nil
        )
    }

    /// Copia con `-c`: en APFS es un clon, así que los datos del juego no ocupan el doble. Importa
    /// en discos llenos, que es justo cuando la gente instala juegos.
    public static func clone(from source: URL, to destination: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", source.path, destination.path],
            currentDirectoryURL: nil
        )
    }

    /// Ejecuta un guion de los que viajan dentro del `.app`.
    public static func script(_ script: URL, arguments: [String]) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path] + arguments,
            currentDirectoryURL: nil,
            // Una app lanzada desde el Finder recibe un PATH mínimo, y los guiones necesitan
            // Homebrew para sus herramientas.
            environment: ["PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":")]
        )
    }
}

/// Utilidades de montaje compartidas por los traslados.
public enum PortPaths {
    /// Elige un nombre libre en la carpeta destino. Nunca pisa lo que ya hay: si el usuario
    /// traslada dos veces, se queda con las dos y decide él cuál borra.
    public static func freeAppURL(named base: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        var candidate = folder.appendingPathComponent("\(base).app")
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path), attempt < 100 {
            candidate = folder.appendingPathComponent("\(base) \(attempt).app")
            attempt += 1
        }
        return candidate
    }

    /// Convierte una imagen suelta en el `.icns` del bundle.
    ///
    /// Es un detalle: si algo falla, la app se abre igual con el icono genérico. Por eso nada de
    /// aquí lanza.
    public static func makeIcon(from image: URL, at destination: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: image.path) else { return }

        let workshop = fileManager.temporaryDirectory
            .appendingPathComponent("Lever-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = workshop.appendingPathComponent("icon.iconset", isDirectory: true)
        try? fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workshop) }

        // `iconutil` solo acepta esta lista exacta de nombres: uno de más y falla el conjunto
        // entero. Los `@2x` son los mismos píxeles del tamaño doble, con otro nombre.
        let variants: [(pixels: Int, names: [String])] = [
            (16, ["icon_16x16"]),
            (32, ["icon_16x16@2x", "icon_32x32"]),
            (64, ["icon_32x32@2x"]),
            (128, ["icon_128x128"]),
            (256, ["icon_128x128@2x", "icon_256x256"]),
            (512, ["icon_256x256@2x", "icon_512x512"]),
            (1024, ["icon_512x512@2x"])
        ]
        for variant in variants {
            guard let first = variant.names.first else { continue }
            let single = iconset.appendingPathComponent("\(first).png")
            run("/usr/bin/sips", ["-z", "\(variant.pixels)", "\(variant.pixels)", image.path, "--out", single.path])
            for extra in variant.names.dropFirst() {
                try? fileManager.copyItem(at: single, to: iconset.appendingPathComponent("\(extra).png"))
            }
        }
        run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", destination.path])
    }

    /// Para las órdenes cortas del montaje, donde esperar es más simple que encadenar `await`.
    static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Firma los `.app` recién montados.
public enum PortSigning {
    /// Firma el bundle entero, en el orden que `codesign` exige.
    ///
    /// El orden no es un detalle: `codesign` se niega a sellar una app cuyas piezas internas no
    /// estén firmadas —«code object is not signed at all, in subcomponent…»— y las piezas que
    /// vienen sueltas del SDK de un motor no siempre traen firma propia. Así que primero los
    /// binarios auxiliares, y el ejecutable principal al final, dentro del sello del bundle.
    /// Para los motores que traen bundles anidados. `codesign --deep` los recorre él solo.
    public static func signNested(
        app: URL,
        runner: ProcessRunner,
        session: ProcessSession
    ) async {
        _ = try? await runner.run(PortCommands.clearQuarantine(app), session: session)
        _ = try? await runner.run(PortCommands.signNested(app), session: session)
    }

    public static func sign(
        app: URL,
        mainExecutable: String,
        runner: ProcessRunner,
        session: ProcessSession,
        fileManager: FileManager = .default
    ) async {
        _ = try? await runner.run(PortCommands.clearQuarantine(app), session: session)

        // La lista se recoge entera antes de empezar a firmar: el recorrido de `FileManager` no
        // se puede iterar entre `await` y `await`.
        for url in innerBinaries(of: app, skipping: mainExecutable, fileManager: fileManager) {
            _ = try? await runner.run(PortCommands.sign(url), session: session)
        }
        _ = try? await runner.run(PortCommands.sign(app), session: session)
    }

    static func innerBinaries(of app: URL, skipping mainExecutable: String, fileManager: FileManager) -> [URL] {
        let contents = app.appendingPathComponent("Contents")
        var found: [URL] = []
        for folder in ["MacOS", "Frameworks"] {
            let directory = contents.appendingPathComponent(folder)
            guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      url.lastPathComponent != mainExecutable else { continue }
                found.append(url)
            }
        }
        return found
    }
}

/// Reparte el traslado según el motor que se haya reconocido.
public enum NativePorter {
    public static func makeApp(
        for engine: PortableEngine,
        into folder: URL,
        buildMissingParts: Bool,
        runner: ProcessRunner,
        session: ProcessSession,
        library: PortLibrary = .shared,
        fileManager: FileManager = .default,
        scriptProvider: @Sendable @escaping (String) -> URL? = { _ in nil },
        onStage: @Sendable @escaping (PortStage) -> Void,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws -> PortOutcome {
        switch engine {
        case .godot(let game):
            return try await GodotPorter.makeApp(
                for: game, into: folder, buildMissingExtensions: buildMissingParts,
                runner: runner, session: session, library: library, fileManager: fileManager,
                scriptProvider: scriptProvider, onStage: onStage, onLine: onLine
            )
        case .renpy(let game):
            return try await RenpyPorter.makeApp(
                for: game, into: folder,
                runner: runner, session: session, library: library, fileManager: fileManager,
                onStage: onStage, onLine: onLine
            )
        case .love(let game):
            return try await LovePorter.makeApp(
                for: game, into: folder,
                runner: runner, session: session, library: library, fileManager: fileManager,
                onStage: onStage, onLine: onLine
            )
        case .nwjs(let game):
            return try await NwjsPorter.makeApp(
                for: game, into: folder,
                runner: runner, session: session, library: library, fileManager: fileManager,
                onStage: onStage, onLine: onLine
            )
        }
    }
}
