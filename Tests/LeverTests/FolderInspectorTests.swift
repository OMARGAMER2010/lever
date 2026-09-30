import Foundation
import LeverCore

enum FolderInspectorTests {
    static func run() throws {
        try testUnpackedUnityGame()
        try testOtherSupportedContent()
        try testLinksStayOutsideTheScan()
        try testScanLimitAndNativeApp()
        try testFolderFromEnvironment()
    }

    /// The real-world layout has a versioned outer folder, a Unity game one level down, and
    /// installers in _Redist. The crash reporter and the redistributables must not win.
    private static func testUnpackedUnityGame() throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("Dimraeth.v0.107.7745", isDirectory: true)
        let game = root.appendingPathComponent("Dimraeth", isDirectory: true)
        let redist = root.appendingPathComponent("_Redist", isDirectory: true)
        let data = game.appendingPathComponent("Dimraeth_Data", isDirectory: true)
        for directory in [game, redist, data] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let main = game.appendingPathComponent("Dimraeth.exe")
        try makePE64(at: main)
        try makePE64(at: game.appendingPathComponent("UnityCrashHandler64.exe"))
        try makePE64(at: redist.appendingPathComponent("vcredist_x64.exe"))
        try Data("dll".utf8).write(to: game.appendingPathComponent("UnityPlayer.dll"))
        try makePE64(at: data.appendingPathComponent("hidden.exe"))

        let result = FolderInspector.inspect(root)
        try expect(result.entries.count == 1,
                   "solo el ejecutable del juego debe ser candidato: \(result.entries.map(\.url.lastPathComponent)); vistos \(result.inspectedCount), limitado \(result.wasLimited)")
        try expect(result.recommended?.url.lastPathComponent == main.lastPathComponent,
                   "Dimraeth.exe debe ser el punto de entrada")
        try expect(result.recommended?.isUnityGame == true, "la carpeta de datos identifica Unity")
        try expect(result.recommended?.architecture == .bits64, "debe leer la arquitectura")
        try expect(result.redistributablesURL?.lastPathComponent == redist.lastPathComponent,
                   "_Redist se identifica sin ejecutarse")
    }

    private static func testOtherSupportedContent() throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("Coleccion", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let apk = root.appendingPathComponent("app.apk")
        let zip = root.appendingPathComponent("datos.zip")
        try Data("apk".utf8).write(to: apk)
        try Data("zip".utf8).write(to: zip)

        let result = FolderInspector.inspect(root)
        try expect(result.entries.contains { $0.url.lastPathComponent == apk.lastPathComponent && $0.kind == .androidApp },
                   "las apps Android deben encontrarse dentro de una carpeta")
        try expect(result.entries.contains { $0.url.lastPathComponent == zip.lastPathComponent && $0.kind == .archive },
                   "los comprimidos deben encontrarse dentro de una carpeta")
        try expect(result.recommended?.url.lastPathComponent == apk.lastPathComponent,
                   "una app va antes que un comprimido")
    }

    private static func testLinksStayOutsideTheScan() throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("Dentro", isDirectory: true)
        let outside = fixture.directoryURL.appendingPathComponent("Fuera", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try makePE64(at: outside.appendingPathComponent("fuera.exe"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("enlace", isDirectory: true), withDestinationURL: outside)
        let result = FolderInspector.inspect(root)
        try expect(result.entries.isEmpty, "un enlace no debe sacar el análisis de la carpeta")
    }

    private static func testScanLimitAndNativeApp() throws {
        let fixture = try TemporaryFixture()
        let root = fixture.directoryURL.appendingPathComponent("Apps", isDirectory: true)
        let app = root.appendingPathComponent("Juego.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        let result = FolderInspector.inspect(root)
        try expect(result.recommended?.url.lastPathComponent == app.lastPathComponent
                   && result.recommended?.kind == .macApplication,
                   "una app de Mac debe ofrecerse sin entrar en su contenido")
        try expect(FolderInspector.inspect(root, maximumEntries: 0).wasLimited,
                   "un análisis limitado debe decirlo")
    }

    /// Optional probe for a real folder; kept generic so the suite does not depend on one Mac.
    private static func testFolderFromEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LEVER_FOLDER_TEST_PATH"] else { return }
        let result = FolderInspector.inspect(URL(fileURLWithPath: path, isDirectory: true))
        let names = result.entries.map(\.url.lastPathComponent)
        print("INFO FolderInspector: \(result.inspectedCount) entradas, candidatos: \(names)")
        if let expected = environment["LEVER_FOLDER_EXPECTED_ENTRY"] {
            try expect(result.recommended?.url.lastPathComponent == expected,
                       "la carpeta real debe sugerir \(expected): \(names)")
        }
    }

    private static func makePE64(at url: URL) throws {
        var data = Data(count: 0x100)
        data[0] = 0x4D
        data[1] = 0x5A
        data[0x3C] = 0x80
        data[0x80] = 0x50
        data[0x81] = 0x45
        data[0x84] = 0x64
        data[0x85] = 0x86
        try data.write(to: url)
    }
}
