import Foundation
import LeverCore

enum WineLauncherTests {
    static func run() throws {
        try testModernEngineHasItsGraphicsAndNativeLibraries()
        try testPlainWineKeepsItsOwnEnvironment()
    }

    private static func testModernEngineHasItsGraphicsAndNativeLibraries() throws {
        let fixture = try TemporaryFixture()
        let steam = WindowsSteam(root: fixture.directoryURL)
        let engine = steam.engineURL.deletingLastPathComponent().deletingLastPathComponent()
        let external = engine.appendingPathComponent("lib/external")
        for library in [external.appendingPathComponent("D3DMetal.framework/D3DMetal"),
                        steam.frameworksURL.appendingPathComponent("libinotify.0.dylib")] {
            try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("library".utf8).write(to: library)
        }
        let program = fixture.directoryURL.appendingPathComponent("Juego/Dimraeth.exe")
        let prefix = fixture.directoryURL.appendingPathComponent("own-windows")
        let command = WineLauncher.runCommand(wine: steam.engineURL, program: program, prefix: prefix)
        let environment = command.environment ?? [:]
        try expect(environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(steam.frameworksURL.path) == true,
                   "el motor moderno necesita libinotify y sus bibliotecas al iniciar wineserver")
        try expect(environment["DYLD_FRAMEWORK_PATH"] == external.path,
                   "los juegos importados deben poder encontrar D3DMetal")
        try expect(environment["WINEDLLOVERRIDES"]?.contains("d3d11,d3d12,dxgi=b") == true,
                   "deben usarse las DLL gráficas incorporadas en el motor")
        try expect(environment["WINEPREFIX"] == prefix.path,
                   "reutilizar el motor no debe abrir el prefijo de Steam")
        try expect(command.currentDirectoryURL == program.deletingLastPathComponent(),
                   "Unity debe encontrar sus datos junto al ejecutable")
    }

    private static func testPlainWineKeepsItsOwnEnvironment() throws {
        let environment = WineLauncher.environment(wine: URL(fileURLWithPath: "/opt/other-wine/bin/wine"))
        try expect(environment["DYLD_FRAMEWORK_PATH"] == nil,
                   "un Wine externo no debe recibir las bibliotecas de otro motor")
        try expect(environment["WINEDLLOVERRIDES"] == "mscoree,mshtml=",
                   "los motores sin D3DMetal conservan sus DLL normales")
    }
}
