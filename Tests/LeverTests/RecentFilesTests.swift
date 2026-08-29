import Foundation
import LeverCore

/// Renombrar y mover tocan archivos de verdad, así que estas pruebas también: se hacen sobre una
/// carpeta temporal que se borra sola.
@MainActor
enum RecentFilesTests {
    static func run() throws {
        try withCleanStore {
            try testRemembersWithoutDuplicating()
            try testKeepsAlimitPerKindSoOneTypeDoesNotEvictAnother()
            try testMarksWhatIsNoLongerThere()
            try testRenameKeepsTheExtension()
            try testRenameRefusesToOverwrite()
            try testMoveTakesTheFileToTheNewFolder()
            try testForgetAndClear()
        }
    }

    /// Las pruebas escriben en los mismos ajustes que la app. Se guarda lo que hubiera y se
    /// devuelve al terminar: perder la lista del usuario por ejecutar las pruebas sería absurdo.
    private static func withCleanStore(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "recentFiles")
        defaults.removeObject(forKey: "recentFiles")
        defer {
            if let saved { defaults.set(saved, forKey: "recentFiles") }
            else { defaults.removeObject(forKey: "recentFiles") }
        }
        try body()
    }

    private static func reset() {
        UserDefaults.standard.removeObject(forKey: "recentFiles")
    }

    // MARK: - Lista

    private static func testRemembersWithoutDuplicating() throws {
        reset()
        let fixture = try TemporaryFixture()
        let apk = try fixture.makeFile(named: "juego.apk")
        let exe = try fixture.makeFile(named: "instalador.exe")

        RecentFiles.remember(apk, kind: .apk, now: Date(timeIntervalSince1970: 1))
        RecentFiles.remember(exe, kind: .exe, now: Date(timeIntervalSince1970: 2))
        // El mismo otra vez: sube al principio, no se duplica.
        RecentFiles.remember(apk, kind: .apk, now: Date(timeIntervalSince1970: 3))

        let all = RecentFiles.load()
        try expect(all.count == 2, "abrir dos veces el mismo archivo no debe duplicar la fila: \(all.count)")
        try expect(all.first?.path == apk.path, "el último abierto va el primero")
        try expect(RecentFiles.files(of: .apk, in: all).count == 1, "solo hay un .apk")
        try expect(RecentFiles.files(of: .exe, in: all).first?.path == exe.path, "y un .exe, el suyo")
    }

    /// El límite es por tipo: si fuera global, abrir doce comprimidos seguidos borraría de la
    /// lista todos los programas.
    private static func testKeepsAlimitPerKindSoOneTypeDoesNotEvictAnother() throws {
        reset()
        let fixture = try TemporaryFixture()
        let programa = try fixture.makeFile(named: "importante.exe")
        RecentFiles.remember(programa, kind: .exe, now: Date(timeIntervalSince1970: 1))

        for index in 0..<20 {
            let archive = try fixture.makeFile(named: "paquete\(index).rar")
            RecentFiles.remember(archive, kind: .rar, now: Date(timeIntervalSince1970: TimeInterval(100 + index)))
        }

        let all = RecentFiles.load()
        try expect(RecentFiles.files(of: .rar, in: all).count == 12,
                   "se conservan doce comprimidos: \(RecentFiles.files(of: .rar, in: all).count)")
        try expect(RecentFiles.files(of: .exe, in: all).first?.path == programa.path,
                   "veinte comprimidos no pueden echar de la lista al programa")
        try expect(RecentFiles.files(of: .rar, in: all).first?.name == "paquete19.rar",
                   "y los que se conservan son los últimos, no los primeros")
    }

    private static func testMarksWhatIsNoLongerThere() throws {
        reset()
        let fixture = try TemporaryFixture()
        let apk = try fixture.makeFile(named: "borrado.apk")
        RecentFiles.remember(apk, kind: .apk)
        try FileManager.default.removeItem(at: apk)

        let file = RecentFiles.load().first
        try expect(file?.isMissing == true,
                   "un archivo borrado desde fuera debe salir marcado, no ofrecerse como si estuviera")
        try expect(file?.folder.hasPrefix("/") == true || file?.folder.hasPrefix("~") == true,
                   "la carpeta se sigue enseñando para saber dónde estaba")
    }

    // MARK: - Renombrar

    private static func testRenameKeepsTheExtension() throws {
        reset()
        let fixture = try TemporaryFixture()
        let apk = try fixture.makeFile(named: "com.ejemplo.v3-release-signed.apk")
        RecentFiles.remember(apk, kind: .apk)
        let file = RecentFiles.load()[0]

        let renamed = try RecentFiles.rename(file, to: "Mi juego")
        try expect(renamed.lastPathComponent == "Mi juego.apk",
                   "la extensión se conserva o la app dejaría de reconocerlo: \(renamed.lastPathComponent)")
        try expect(FileManager.default.fileExists(atPath: renamed.path), "el archivo debe estar en el sitio nuevo")
        try expect(!FileManager.default.fileExists(atPath: apk.path), "y no en el viejo")

        let stored = RecentFiles.load()
        try expect(stored.count == 1, "sigue habiendo una sola fila, no dos")
        try expect(stored[0].path == renamed.path, "la fila apunta al nombre nuevo")

        // Si escribe la extensión él mismo, no se pone dos veces.
        let again = try RecentFiles.rename(stored[0], to: "Mi juego 2.apk")
        try expect(again.lastPathComponent == "Mi juego 2.apk", "sin duplicar la extensión: \(again.lastPathComponent)")

        // Un nombre en blanco no borra nada ni deja el archivo sin nombre.
        do {
            _ = try RecentFiles.rename(RecentFiles.load()[0], to: "   ")
            throw TestFailure(description: "un nombre vacío debe rechazarse")
        } catch let error as RecentFileError {
            try expect(error == .emptyName, "y decir que falta el nombre")
        }
    }

    /// Nunca se pisa un archivo del usuario, ni siquiera otro suyo.
    private static func testRenameRefusesToOverwrite() throws {
        reset()
        let fixture = try TemporaryFixture()
        let uno = try fixture.makeFile(named: "uno.rar")
        _ = try fixture.makeFile(named: "dos.rar")
        RecentFiles.remember(uno, kind: .rar)

        do {
            _ = try RecentFiles.rename(RecentFiles.load()[0], to: "dos")
            throw TestFailure(description: "renombrar encima de otro archivo debe fallar")
        } catch let error as RecentFileError {
            try expect(error == .alreadyExists("dos.rar"), "y decir cuál estorba: \(error)")
        }
        try expect(FileManager.default.fileExists(atPath: uno.path), "el original sigue intacto")
    }

    // MARK: - Mover

    private static func testMoveTakesTheFileToTheNewFolder() throws {
        reset()
        let fixture = try TemporaryFixture()
        let exe = try fixture.makeFile(named: "programa.exe")
        let destino = fixture.directoryURL.appendingPathComponent("otra carpeta", isDirectory: true)
        try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        RecentFiles.remember(exe, kind: .exe)

        let moved = try RecentFiles.move(RecentFiles.load()[0], to: destino)
        try expect(moved.deletingLastPathComponent().standardizedFileURL == destino.standardizedFileURL,
                   "el archivo acaba en la carpeta elegida")
        try expect(moved.lastPathComponent == "programa.exe", "con el mismo nombre")
        try expect(FileManager.default.fileExists(atPath: moved.path), "y existe de verdad")
        try expect(RecentFiles.load()[0].path == moved.path, "la fila sigue al archivo")

        // Mover al sitio donde ya está no es un error: no hay nada que hacer.
        let again = try RecentFiles.move(RecentFiles.load()[0], to: destino)
        try expect(again == moved, "mover a la misma carpeta se queda como está")
    }

    // MARK: - Quitar

    private static func testForgetAndClear() throws {
        reset()
        let fixture = try TemporaryFixture()
        let apk = try fixture.makeFile(named: "app.apk")
        let rar = try fixture.makeFile(named: "cosas.rar")
        RecentFiles.remember(apk, kind: .apk)
        RecentFiles.remember(rar, kind: .rar)

        RecentFiles.forget(RecentFiles.files(of: .apk, in: RecentFiles.load())[0])
        try expect(RecentFiles.load().count == 1, "quitar una fila deja la otra")
        try expect(FileManager.default.fileExists(atPath: apk.path),
                   "quitar de la lista NO borra el archivo del disco")

        RecentFiles.clear(kind: .rar)
        try expect(RecentFiles.load().isEmpty, "vaciar el tipo deja la lista sin nada")
        try expect(FileManager.default.fileExists(atPath: rar.path), "y tampoco borra nada")
    }
}
