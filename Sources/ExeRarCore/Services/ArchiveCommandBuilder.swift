import Foundation

public enum ArchiveCommandBuilder {
    /// Orden de extracción para la herramienta disponible.
    public static func command(
        for tool: ArchiveTool,
        archive: URL,
        destination: URL,
        policy: OverwritePolicy = .skip,
        password: String? = nil
    ) -> ProcessCommand {
        let secret = password?.isEmpty == false ? password : nil

        switch tool {
        case .sevenZip(let executable):
            var arguments = ["x", sevenZipFlag(for: policy), "-bsp1"]
            if let secret { arguments.append("-p\(secret)") }
            arguments.append(archive.path)
            arguments.append("-o\(destination.path)")
            return ProcessCommand(
                executableURL: executable,
                arguments: arguments,
                currentDirectoryURL: destination
            )

        case .unar(let executable):
            var arguments = [unarFlag(for: policy), "-o", destination.path]
            if let secret { arguments.append(contentsOf: ["-p", secret]) }
            arguments.append(archive.path)
            return ProcessCommand(
                executableURL: executable,
                arguments: arguments,
                currentDirectoryURL: destination
            )

        case .unrar(let executable):
            var arguments = ["x", unrarFlag(for: policy)]
            if let secret { arguments.append("-p\(secret)") }
            arguments.append(archive.path)
            arguments.append(destination.path + "/")
            return ProcessCommand(
                executableURL: executable,
                arguments: arguments,
                currentDirectoryURL: destination
            )
        }
    }

    /// Orden para leer el contenido sin extraer nada. `lsar` da la lista más limpia.
    public static func listCommand(
        for tool: ArchiveTool,
        lister: URL?,
        archive: URL,
        password: String? = nil
    ) -> ProcessCommand? {
        let secret = password?.isEmpty == false ? password : nil

        if let lister {
            var arguments: [String] = []
            if let secret { arguments.append(contentsOf: ["-p", secret]) }
            arguments.append(archive.path)
            return ProcessCommand(executableURL: lister, arguments: arguments, currentDirectoryURL: nil)
        }

        if case .sevenZip(let executable) = tool {
            var arguments = ["l", "-ba"]
            if let secret { arguments.append("-p\(secret)") }
            arguments.append(archive.path)
            return ProcessCommand(executableURL: executable, arguments: arguments, currentDirectoryURL: nil)
        }

        return nil
    }

    /// Extrae el porcentaje de una línea de progreso de `7zz` (`" 45% 3 - archivo"`).
    public static func progressPercentage(from line: String) -> Int? {
        guard let match = line.range(of: #"^\s*(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let digits = line[match].filter(\.isNumber)
        guard let value = Int(digits), (0...100).contains(value) else { return nil }
        return value
    }

    /// Convierte la salida del listado en nombres de archivo.
    public static func names(fromListing output: String, usedLister: Bool) -> [String] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)

        if usedLister {
            // `lsar` imprime primero "archivo.rar: RAR" y luego un nombre por línea.
            return lines
                .dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("(") }
        }

        // `7zz l -ba`: la columna del nombre empieza en la posición 53.
        return lines.compactMap { line in
            guard line.count > 53 else { return nil }
            let name = String(line.dropFirst(53)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    private static func sevenZipFlag(for policy: OverwritePolicy) -> String {
        switch policy {
        case .skip: return "-aos"
        case .rename: return "-aou"
        case .overwrite: return "-aoa"
        }
    }

    private static func unarFlag(for policy: OverwritePolicy) -> String {
        switch policy {
        case .skip: return "-s"
        case .rename: return "-r"
        case .overwrite: return "-f"
        }
    }

    private static func unrarFlag(for policy: OverwritePolicy) -> String {
        switch policy {
        case .skip: return "-o-"
        case .rename: return "-or"
        case .overwrite: return "-o+"
        }
    }
}
