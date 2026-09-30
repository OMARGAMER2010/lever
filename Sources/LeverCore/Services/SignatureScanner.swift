import Foundation

/// Un escáner de firmas conocidas instalado en el Mac. Hoy, ClamAV si lo hay.
///
/// Es una capa **adicional**: reconoce lo que ya se conoce y nada más. No se descarga ni se instala
/// solo, y si no está, Safe Mode aísla igual. Corre dentro de su propio aislamiento, porque lo que
/// analiza es justo lo que no es de fiar: un fallo en su analizador no debe poder salir de ahí.
public struct SignatureScanner: Equatable, Sendable {
    public let executable: URL
    public let databases: URL
    /// Su configuración: ClamAV 1.5 comprueba la firma de sus bases con certificados de aquí, y sin
    /// poder leerlos da la base por rota.
    public let configuration: [URL]

    public static let name = "ClamAV"

    public static func locate(fileManager: FileManager = .default) -> SignatureScanner? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let binary = URL(fileURLWithPath: prefix + "/bin/clamscan")
            let databases = URL(fileURLWithPath: prefix + "/var/lib/clamav")
            guard fileManager.isExecutableFile(atPath: binary.path) else { continue }
            let names = (try? fileManager.contentsOfDirectory(atPath: databases.path)) ?? []
            // Sin la base principal no reconoce casi nada: mejor decir que no hay escáner.
            guard names.contains(where: { $0.hasPrefix("main.") }),
                  let real = try? SandboxPath.canonical(binary) else { continue }
            let configuration = ["/etc/clamav", "/etc/openssl@3"]
                .map { URL(fileURLWithPath: prefix + $0) }
                .filter { fileManager.fileExists(atPath: $0.path) }
            return SignatureScanner(executable: URL(fileURLWithPath: real), databases: databases,
                                    configuration: configuration)
        }
        return nil
    }

    /// Analiza los archivos indicados. Devuelve el resultado y un hallazgo por amenaza reconocida.
    public func scan(
        targets: [URL],
        relativeTo root: URL,
        workspace: SafeWorkspace,
        runner: ProcessRunner,
        session: ProcessSession,
        timeLimit: Duration = .seconds(300),
        fileManager: FileManager = .default
    ) async -> (SafeSignatureScan, [SafeFinding]) {
        guard !targets.isEmpty else { return (.nothingToScan, []) }
        let scratch = workspace.temporary.appendingPathComponent("clamav-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            let list = scratch.appendingPathComponent("targets.txt")
            try Data(targets.map(\.path).joined(separator: "\n").utf8).write(to: list)
            let profile = try SandboxProfile.signatureScan(
                scanner: executable, databases: databases, readable: [root, scratch] + configuration, temporary: scratch)
            let profileURL = workspace.control.appendingPathComponent("clamav.sb")
            try Sandbox.write(profile, to: profileURL, fileManager: fileManager)

            let version = try await runner.run(Sandbox.command(
                ProcessCommand(executableURL: executable, arguments: ["--version", "--database=\(databases.path)"],
                               currentDirectoryURL: nil),
                profileURL: profileURL, environment: Sandbox.minimalEnvironment(temporary: scratch)))
            let engine = Self.engineDescription(version.output)

            let watchdog = Task {
                try? await Task.sleep(for: timeLimit)
                if !Task.isCancelled { session.cancel() }
            }
            defer { watchdog.cancel() }
            let result = try await runner.run(Sandbox.command(
                ProcessCommand(
                    executableURL: executable,
                    arguments: ["--no-summary", "--infected", "--stdout", "--database=\(databases.path)",
                                "--tempdir=\(scratch.path)", "--max-filesize=512M", "--max-scansize=1024M",
                                "--file-list=\(list.path)"],
                    currentDirectoryURL: nil),
                profileURL: profileURL,
                environment: Sandbox.minimalEnvironment(temporary: scratch)
            ), session: session)

            // 0: nada; 1: algo reconocido; cualquier otra cosa, que no terminó bien.
            guard !result.wasCancelled, result.exitCode == 0 || result.exitCode == 1 else {
                return (.failed(engine: engine), [])
            }
            let findings = Self.detections(in: result.output, relativeTo: root)
            return findings.isEmpty ? (.clean(engine: engine), []) : (.detected(engine: engine, count: findings.count), findings)
        } catch {
            return (.failed(engine: Self.name), [])
        }
    }

    /// `ruta: Nombre.De.La.Firma FOUND`.
    public static func detections(in output: String, relativeTo root: URL) -> [SafeFinding] {
        let prefix = root.path + "/"
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasSuffix(" FOUND"), let colon = line.range(of: ": ", options: .backwards) else { return nil }
            var path = String(line[..<colon.lowerBound])
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
            let signature = line[colon.upperBound...].dropLast(" FOUND".count)
            return SafeFinding(.knownThreat, subject: path, detail: String(signature))
        }
    }

    /// `ClamAV 1.5.4/28122/Sun Sep 13 02:26:25 2026` → `ClamAV 1.5.4 · 13 Sep 2026`.
    public static func engineDescription(_ output: String) -> String {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard let product = parts.first, product.hasPrefix(name) else { return name }
        guard parts.count >= 3 else { return String(product) }
        let date = parts[2].split(separator: " ")
        guard date.count >= 5 else { return String(product) }
        return "\(product) · \(date[2]) \(date[1]) \(date[4])"
    }
}
