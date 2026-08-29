import Foundation

public enum ArchiveCommandBuilder {
    public static func command(
        for tool: ArchiveTool,
        archive: URL,
        destination: URL
    ) -> ProcessCommand {
        switch tool {
        case .sevenZip(let executable):
            return ProcessCommand(
                executableURL: executable,
                arguments: ["x", "-aos", archive.path, "-o\(destination.path)"],
                currentDirectoryURL: destination
            )
        case .unar(let executable):
            return ProcessCommand(
                executableURL: executable,
                arguments: ["-r", "-o", destination.path, archive.path],
                currentDirectoryURL: destination
            )
        case .unrar(let executable):
            return ProcessCommand(
                executableURL: executable,
                arguments: ["x", "-o-", archive.path, destination.path + "/"],
                currentDirectoryURL: destination
            )
        }
    }
}
