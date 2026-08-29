import Foundation
import PalancaCore

enum ProgramInspectorTests {
    static func run() throws {
        try testReadsArchitectureFromPEHeader()
        try testRejectsFilesThatAreNotExecutables()
        try testDetectsArchiveParts()
    }

    /// Construye una cabecera PE mínima con la máquina indicada.
    private static func makePE(machine: UInt16, in fixture: TemporaryFixture, named name: String) throws -> URL {
        var data = Data(count: 0x100)
        data[0] = 0x4D  // 'M'
        data[1] = 0x5A  // 'Z'

        let peOffset: UInt32 = 0x80
        withUnsafeBytes(of: peOffset.littleEndian) { bytes in
            for (index, byte) in bytes.enumerated() { data[0x3C + index] = byte }
        }

        data[0x80] = 0x50  // 'P'
        data[0x81] = 0x45  // 'E'
        data[0x82] = 0
        data[0x83] = 0
        withUnsafeBytes(of: machine.littleEndian) { bytes in
            for (index, byte) in bytes.enumerated() { data[0x84 + index] = byte }
        }

        let url = fixture.directoryURL.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func testReadsArchitectureFromPEHeader() throws {
        let fixture = try TemporaryFixture()

        let expected: [(UInt16, ProgramArchitecture, String)] = [
            (0x014C, .bits32, "viejo.exe"),
            (0x8664, .bits64, "moderno.exe"),
            (0xAA64, .arm64, "arm.exe")
        ]

        for (machine, architecture, name) in expected {
            let url = try makePE(machine: machine, in: fixture, named: name)
            try expect(
                ProgramInspector.architecture(of: url) == architecture,
                "\(name) debe leerse como \(architecture)"
            )
        }

        // Solo los de 32 bits avisan: los Wine de Apple Silicon son de 64.
        try expect(ProgramArchitecture.bits32.warnsAboutWine, "32 bits debe avisar")
        try expect(!ProgramArchitecture.bits64.warnsAboutWine, "64 bits no debe avisar")
    }

    private static func testRejectsFilesThatAreNotExecutables() throws {
        let fixture = try TemporaryFixture()
        let text = try fixture.makeFile(named: "notas.txt")
        try expect(
            ProgramInspector.architecture(of: text) == .unknown,
            "un archivo de texto no tiene arquitectura"
        )
        try expect(
            ProgramInspector.architecture(of: fixture.directoryURL.appendingPathComponent("nada.exe")) == .unknown,
            "un archivo que no existe no debe reventar"
        )
    }

    private static func testDetectsArchiveParts() throws {
        for name in ["juego.part1.rar", "juego.r01", "datos.z01", "grande.001"] {
            try expect(
                URL(fileURLWithPath: "/tmp/\(name)").looksLikeArchivePart,
                "\(name) es parte de un comprimido partido"
            )
        }
        for name in ["normal.rar", "normal.zip"] {
            try expect(
                !URL(fileURLWithPath: "/tmp/\(name)").looksLikeArchivePart,
                "\(name) no está partido"
            )
        }
        try expect(URL(fileURLWithPath: "/tmp/a.rar").archiveFormatName == "RAR", "el formato se enseña en mayúsculas")
    }
}
