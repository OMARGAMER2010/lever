import Foundation
import ExeRarCore

enum CommandBuilderTests {
    static func run() throws {
        try testFileKindsAreCaseInsensitive()
        try testSevenZipCommandKeepsPathsAsSeparateArguments()
        try testUnarCommandRenamesCollisions()
        try testUnrarCommandSkipsExistingFiles()
    }

    private static func testFileKindsAreCaseInsensitive() throws {
        try expect(
            SupportedFileKind.exe.accepts(URL(fileURLWithPath: "/tmp/Installer.EXE")),
            "EXE extension should be case-insensitive"
        )
        try expect(
            SupportedFileKind.rar.accepts(URL(fileURLWithPath: "/tmp/Archive.RaR")),
            "RAR extension should be case-insensitive"
        )
        try expect(
            !SupportedFileKind.exe.accepts(URL(fileURLWithPath: "/tmp/Archive.rar")),
            "EXE validation should reject RAR files"
        )
    }

    private static func testSevenZipCommandKeepsPathsAsSeparateArguments() throws {
        let archive = URL(fileURLWithPath: "/tmp/My Files/sample.rar")
        let destination = URL(fileURLWithPath: "/tmp/Extracted Files")
        let tool = ArchiveTool.sevenZip(URL(fileURLWithPath: "/opt/homebrew/bin/7zz"))

        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)

        try expect(
            command.arguments == ["x", "-aos", archive.path, "-o\(destination.path)"],
            "7zz should receive no-overwrite arguments and preserve path boundaries"
        )
    }

    private static func testUnarCommandRenamesCollisions() throws {
        let archive = URL(fileURLWithPath: "/tmp/archive.rar")
        let destination = URL(fileURLWithPath: "/tmp/output")
        let tool = ArchiveTool.unar(URL(fileURLWithPath: "/usr/local/bin/unar"))

        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)

        try expect(
            command.arguments == ["-r", "-o", destination.path, archive.path],
            "unar should rename colliding files instead of overwriting them"
        )
    }

    private static func testUnrarCommandSkipsExistingFiles() throws {
        let archive = URL(fileURLWithPath: "/tmp/archive.rar")
        let destination = URL(fileURLWithPath: "/tmp/output")
        let tool = ArchiveTool.unrar(URL(fileURLWithPath: "/usr/local/bin/unrar"))

        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)

        try expect(
            command.arguments == ["x", "-o-", archive.path, destination.path + "/"],
            "unrar should skip existing files"
        )
    }
}
