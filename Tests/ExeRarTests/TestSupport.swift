import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

final class TemporaryFixture {
    private let directory: URL

    var directoryURL: URL { directory }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExeRarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeFile(named name: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data("test".utf8).write(to: file)
        return file
    }

    func makeExecutable(named name: String) throws -> URL {
        let file = try makeFile(named: name)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    func makeWineAppBundle() throws -> URL {
        let app = directory.appendingPathComponent("Wine Test.app", isDirectory: true)
        let binary = app.appendingPathComponent("Contents/Resources/wine/bin/wine")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("wine".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return app
    }
}
