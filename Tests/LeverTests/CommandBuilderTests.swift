import Foundation
import LeverCore

enum CommandBuilderTests {
    static func run() throws {
        try testFileKindsAreCaseInsensitive()
        try testExeKindAlsoAcceptsInstallers()
        try testArchiveKindCoversCommonFormats()
        try testSevenZipCommandKeepsPathsAsSeparateArguments()
        try testUnarCommandRenamesCollisions()
        try testUnrarCommandSkipsExistingFiles()
        try testOverwritePolicyChangesTheFlag()
        try testPasswordIsPassedToEachTool()
        try testEmptyPasswordIsNotPassed()
        try testProgressIsReadFromSevenZipOutput()
        try testSuggestedFolderNameStripsExtensions()
        try testListingIsParsedIntoNames()
        try testUnarIsPreferredForRarFiles()
        try testSevenZipIsPreferredForEverythingElse()
        try testFallbackPicksTheOtherTool()
    }

    private static func status(_ tools: [ArchiveTool]) -> RuntimeStatus {
        RuntimeStatus(wineURL: nil, archiveTools: tools, homebrewURL: nil)
    }

    /// 7zz no sabe descomprimir varios métodos de RAR y deja archivos de 0 bytes sin avisar del todo.
    /// Para .rar manda unar, aunque 7zz esté disponible y aparezca antes.
    private static func testUnarIsPreferredForRarFiles() throws {
        let sevenZip = ArchiveTool.sevenZip(URL(fileURLWithPath: "/bin/7zz"))
        let unar = ArchiveTool.unar(URL(fileURLWithPath: "/bin/unar"))
        let both = status([sevenZip, unar])

        try expect(both.tool(for: URL(fileURLWithPath: "/tmp/a.rar")) == unar,
                   "para .rar debe elegirse unar aunque 7zz esté antes en la lista")
        try expect(both.tool(for: URL(fileURLWithPath: "/tmp/juego.part1.rar")) == unar,
                   "los multiparte .rar también van por unar")
        try expect(both.tool(for: URL(fileURLWithPath: "/tmp/juego.r01")) == unar,
                   "las partes .r01 también son RAR")
        try expect(status([sevenZip]).tool(for: URL(fileURLWithPath: "/tmp/a.rar")) == sevenZip,
                   "si solo hay 7zz, se usa 7zz: mejor intentarlo que no hacer nada")
    }

    private static func testSevenZipIsPreferredForEverythingElse() throws {
        let sevenZip = ArchiveTool.sevenZip(URL(fileURLWithPath: "/bin/7zz"))
        let unar = ArchiveTool.unar(URL(fileURLWithPath: "/bin/unar"))
        let both = status([sevenZip, unar])

        for name in ["a.zip", "a.7z", "a.tar", "a.iso"] {
            try expect(both.tool(for: URL(fileURLWithPath: "/tmp/\(name)")) == sevenZip,
                       "\(name) debe ir por 7zz")
        }
    }

    private static func testFallbackPicksTheOtherTool() throws {
        let sevenZip = ArchiveTool.sevenZip(URL(fileURLWithPath: "/bin/7zz"))
        let unar = ArchiveTool.unar(URL(fileURLWithPath: "/bin/unar"))
        let both = status([sevenZip, unar])
        let archive = URL(fileURLWithPath: "/tmp/a.rar")

        try expect(both.fallbackTool(for: archive, after: unar) == sevenZip,
                   "si unar falla, se prueba con 7zz")
        try expect(status([unar]).fallbackTool(for: archive, after: unar) == nil,
                   "sin otra herramienta, no hay reintento")
    }

    private static func testFileKindsAreCaseInsensitive() throws {
        try expect(
            SupportedFileKind.exe.accepts(URL(fileURLWithPath: "/tmp/Installer.EXE")),
            "la extensión .exe debe aceptarse en mayúsculas"
        )
        try expect(
            SupportedFileKind.rar.accepts(URL(fileURLWithPath: "/tmp/Archive.RaR")),
            "la extensión .rar debe aceptarse en cualquier caja"
        )
        try expect(
            !SupportedFileKind.exe.accepts(URL(fileURLWithPath: "/tmp/Archive.rar")),
            "un .rar no debe pasar por programa de Windows"
        )
    }

    private static func testExeKindAlsoAcceptsInstallers() throws {
        try expect(
            SupportedFileKind.exe.accepts(URL(fileURLWithPath: "/tmp/Setup.msi")),
            "los instaladores .msi también son programas de Windows"
        )
    }

    private static func testArchiveKindCoversCommonFormats() throws {
        for name in ["a.zip", "a.7z", "a.tar", "a.gz", "a.iso", "a.cab"] {
            try expect(
                SupportedFileKind.rar.accepts(URL(fileURLWithPath: "/tmp/\(name)")),
                "\(name) debe reconocerse como comprimido"
            )
        }
        try expect(
            !SupportedFileKind.rar.accepts(URL(fileURLWithPath: "/tmp/a.txt")),
            "un .txt no es un comprimido"
        )
    }

    private static func testSevenZipCommandKeepsPathsAsSeparateArguments() throws {
        let archive = URL(fileURLWithPath: "/tmp/My Files/sample.rar")
        let destination = URL(fileURLWithPath: "/tmp/Extracted Files")
        let tool = ArchiveTool.sevenZip(URL(fileURLWithPath: "/opt/homebrew/bin/7zz"))

        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)

        try expect(
            command.arguments == ["x", "-aos", "-bsp1", archive.path, "-o\(destination.path)"],
            "7zz debe recibir la política de no sobrescribir, el progreso y las rutas sin partir"
        )
    }

    private static func testUnarCommandRenamesCollisions() throws {
        let archive = URL(fileURLWithPath: "/tmp/archive.rar")
        let destination = URL(fileURLWithPath: "/tmp/output")
        let tool = ArchiveTool.unar(URL(fileURLWithPath: "/usr/local/bin/unar"))

        let command = ArchiveCommandBuilder.command(
            for: tool, archive: archive, destination: destination, policy: .rename
        )

        try expect(
            command.arguments == ["-r", "-o", destination.path, archive.path],
            "unar debe renombrar en vez de sobrescribir cuando se pide"
        )
    }

    private static func testUnrarCommandSkipsExistingFiles() throws {
        let archive = URL(fileURLWithPath: "/tmp/archive.rar")
        let destination = URL(fileURLWithPath: "/tmp/output")
        let tool = ArchiveTool.unrar(URL(fileURLWithPath: "/usr/local/bin/unrar"))

        let command = ArchiveCommandBuilder.command(for: tool, archive: archive, destination: destination)

        try expect(
            command.arguments == ["x", "-o-", archive.path, destination.path + "/"],
            "unrar debe saltarse los archivos existentes por defecto"
        )
    }

    private static func testOverwritePolicyChangesTheFlag() throws {
        let archive = URL(fileURLWithPath: "/tmp/a.rar")
        let destination = URL(fileURLWithPath: "/tmp/out")
        let sevenZip = ArchiveTool.sevenZip(URL(fileURLWithPath: "/opt/homebrew/bin/7zz"))

        let expected: [OverwritePolicy: String] = [.skip: "-aos", .rename: "-aou", .overwrite: "-aoa"]
        for (policy, flag) in expected {
            let command = ArchiveCommandBuilder.command(
                for: sevenZip, archive: archive, destination: destination, policy: policy
            )
            try expect(command.arguments.contains(flag), "\(policy.rawValue) debe usar \(flag) en 7zz")
        }
    }

    private static func testPasswordIsPassedToEachTool() throws {
        let archive = URL(fileURLWithPath: "/tmp/a.rar")
        let destination = URL(fileURLWithPath: "/tmp/out")

        let sevenZip = ArchiveCommandBuilder.command(
            for: .sevenZip(URL(fileURLWithPath: "/bin/7zz")),
            archive: archive, destination: destination, password: "secreta"
        )
        try expect(sevenZip.arguments.contains("-psecreta"), "7zz recibe la contraseña pegada a -p")

        let unar = ArchiveCommandBuilder.command(
            for: .unar(URL(fileURLWithPath: "/bin/unar")),
            archive: archive, destination: destination, password: "secreta"
        )
        try expect(
            unar.arguments.contains("-p") && unar.arguments.contains("secreta"),
            "unar recibe la contraseña como argumento aparte"
        )

        let unrar = ArchiveCommandBuilder.command(
            for: .unrar(URL(fileURLWithPath: "/bin/unrar")),
            archive: archive, destination: destination, password: "secreta"
        )
        try expect(unrar.arguments.contains("-psecreta"), "unrar recibe la contraseña pegada a -p")
    }

    private static func testEmptyPasswordIsNotPassed() throws {
        let command = ArchiveCommandBuilder.command(
            for: .sevenZip(URL(fileURLWithPath: "/bin/7zz")),
            archive: URL(fileURLWithPath: "/tmp/a.rar"),
            destination: URL(fileURLWithPath: "/tmp/out"),
            password: ""
        )
        try expect(
            !command.arguments.contains(where: { $0.hasPrefix("-p") }),
            "una contraseña vacía no debe convertirse en argumento"
        )
    }

    private static func testProgressIsReadFromSevenZipOutput() throws {
        try expect(ArchiveCommandBuilder.progressPercentage(from: " 45% 12 - carpeta/archivo.txt") == 45,
                   "debe leer el porcentaje de una línea de progreso")
        try expect(ArchiveCommandBuilder.progressPercentage(from: "100%") == 100,
                   "debe leer el 100%")
        try expect(ArchiveCommandBuilder.progressPercentage(from: "Everything is Ok") == nil,
                   "una línea normal no tiene porcentaje")
        try expect(ArchiveCommandBuilder.progressPercentage(from: "descuento del 20% aplicado") == nil,
                   "solo cuenta el porcentaje al principio de la línea")
    }

    private static func testSuggestedFolderNameStripsExtensions() throws {
        try expect(URL(fileURLWithPath: "/tmp/Mis Fotos.rar").suggestedFolderName == "Mis Fotos",
                   "quita la extensión simple")
        try expect(URL(fileURLWithPath: "/tmp/copia.tar.gz").suggestedFolderName == "copia",
                   "quita la extensión doble .tar.gz")
        try expect(URL(fileURLWithPath: "/tmp/juego.part1.rar").suggestedFolderName == "juego",
                   "quita el sufijo de multiparte")
    }

    private static func testListingIsParsedIntoNames() throws {
        let lsarOutput = "paquete.rar: RAR\ncarpeta/uno.txt\ncarpeta/dos.txt\n"
        try expect(
            ArchiveCommandBuilder.names(fromListing: lsarOutput, usedLister: true)
                == ["carpeta/uno.txt", "carpeta/dos.txt"],
            "lsar: se descarta la cabecera y se quedan los nombres"
        )

        let sevenZipLine = "2024-01-01 12:00:00 ....A         1234          567  carpeta/uno.txt"
        try expect(
            ArchiveCommandBuilder.names(fromListing: sevenZipLine, usedLister: false) == ["carpeta/uno.txt"],
            "7zz: el nombre se toma de la columna fija"
        )
    }
}
