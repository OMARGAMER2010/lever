import Foundation
import LeverCore

/// La lista que alimenta la pestaña Safe Runs: qué espacios hay, en qué orden y qué contienen.
///
/// Todo se prueba contra una base temporal, nunca contra los espacios de verdad de la persona:
/// las APIs de `SafeWorkspace` aceptan `base:` justo para esto.
enum SafeRunsTests {
    static func run() throws {
        try testRunsAreListedNewestFirst()
        try testRunIsNamedAfterWhatItCameFrom()
        try testRunListsTheProgramsFoundInside()
        try testASpaceWithoutItsFilesIsNotListed()
        try testChosenProgramLandsInsideItsSpace()
        try testRunKnowsItsSizeWithoutWalkingTheTree()
    }

    /// El tamaño ya viene contado en el informe. Volver a recorrer el árbol para saberlo
    /// congelaría la ventana: un espacio puede pesar decenas de gigas.
    private static func testRunKnowsItsSizeWithoutWalkingTheTree() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let conInforme = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/pesado.rar",
                                        createdAt: Date(timeIntervalSince1970: 200)), base: base)
        try conInforme.save(SafeReport(totalBytes: 60_096_123_795))
        _ = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/sin-informe.rar",
                                        createdAt: Date(timeIntervalSince1970: 100)), base: base)

        let runs = SafeRun.all(base: base)

        try expect(runs.first?.sizeBytes == 60_096_123_795,
                   "el tamaño sale del informe, salió \(String(describing: runs.first?.sizeBytes))")
        try expect(runs.last?.sizeBytes == nil,
                   "sin informe no hay tamaño que enseñar, salió \(String(describing: runs.last?.sizeBytes))")
    }

    /// La prueba que de verdad importa. `containing(_:)` es lo que pone `programOpenMode = .safe`,
    /// y solo reconoce rutas que caen dentro de `<espacio>/files`. Si la pestaña entregara una
    /// ruta de fuera, el programa se abriría **sin aislar**.
    private static func testChosenProgramLandsInsideItsSpace() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let workspace = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/Juego.zip"), base: base)
        let executable = SafeExecutable(relativePath: "Juego/Juego.exe", isInstaller: false,
                                        architecture: "x64", hasSignature: false, sha256: nil)
        try workspace.save(SafeReport(executables: [executable]))

        guard let run = SafeRun.all(base: base).first else {
            throw TestFailure(description: "no se listó el espacio recién creado")
        }
        let chosen = run.url(of: executable)

        try expect(SafeWorkspace.containing(chosen, base: base) == run.workspace,
                   "el espacio tiene que reconocer la ruta como suya: \(chosen.path)")
    }

    /// Un espacio al que le falta la carpeta de archivos no tiene nada que ejecutar. Enseñarlo
    /// sería ofrecer un botón que no lleva a ninguna parte.
    private static func testASpaceWithoutItsFilesIsNotListed() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        _ = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/bueno.rar",
                                        createdAt: Date(timeIntervalSince1970: 200)), base: base)
        let roto = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/roto.rar",
                                        createdAt: Date(timeIntervalSince1970: 100)), base: base)
        try FileManager.default.removeItem(at: roto.files)

        let runs = SafeRun.all(base: base)

        try expect(runs.map(\.displayName) == ["bueno.rar"],
                   "solo se lista el que conserva sus archivos, salió \(runs.map(\.displayName))")
    }

    /// Sin esto la fila se despliega y no hay nada que ejecutar.
    private static func testRunListsTheProgramsFoundInside() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        let workspace = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/Juego.zip"), base: base)
        try workspace.save(SafeReport(executables: [
            SafeExecutable(relativePath: "Juego/Juego.exe", isInstaller: false,
                           architecture: "x64", hasSignature: false, sha256: nil),
            SafeExecutable(relativePath: "Juego/setup.exe", isInstaller: true,
                           architecture: "x86", hasSignature: true, sha256: nil)
        ]))

        guard let run = SafeRun.all(base: base).first else {
            throw TestFailure(description: "no se listó el espacio recién creado")
        }
        try expect(run.executables.map(\.name) == ["Juego.exe", "setup.exe"],
                   "los programas salen del informe del escáner, salió \(run.executables.map(\.name))")
    }

    /// La fila tiene que decir «Bodycam.rar», no un UUID: el UUID no le dice nada a nadie.
    private static func testRunIsNamedAfterWhatItCameFrom() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)
        _ = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/Users/alguien/Escritorio/Bodycam.rar"),
            base: base)

        guard let run = SafeRun.all(base: base).first else {
            throw TestFailure(description: "no se listó el espacio recién creado")
        }
        try expect(run.displayName == "Bodycam.rar",
                   "el nombre sale del archivo del que vino, salió \(run.displayName)")
    }

    private static func testRunsAreListedNewestFirst() throws {
        let fixture = try TemporaryFixture()
        let base = fixture.directoryURL.appendingPathComponent("base", isDirectory: true)

        _ = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/viejo.rar",
                                        createdAt: Date(timeIntervalSince1970: 100)), base: base)
        _ = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/nuevo.rar",
                                        createdAt: Date(timeIntervalSince1970: 300)), base: base)
        _ = try SafeWorkspace.create(
            origin: SafeWorkspaceOrigin(kind: .archive, path: "/medio.rar",
                                        createdAt: Date(timeIntervalSince1970: 200)), base: base)

        let runs = SafeRun.all(base: base)

        try expect(runs.count == 3, "se listan los tres espacios, salieron \(runs.count)")
        try expect(runs.map(\.origin.path) == ["/nuevo.rar", "/medio.rar", "/viejo.rar"],
                   "del más reciente al más antiguo, salió \(runs.map(\.origin.path))")
    }
}
