import Foundation

public enum ArchiveTool: Equatable {
    case sevenZip(URL)
    case unar(URL)
    case unrar(URL)
}

public struct RuntimeStatus: Equatable {
    public let wineURL: URL?
    public let archiveTool: ArchiveTool?
    public let homebrewURL: URL?

    public var archiveToolName: String? {
        switch archiveTool {
        case .sevenZip:
            return "7zz"
        case .unar:
            return "unar"
        case .unrar:
            return "unrar"
        case nil:
            return nil
        }
    }
}

public struct ProcessCommand: Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?

    public init(executableURL: URL, arguments: [String], currentDirectoryURL: URL?) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
    }
}

public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let output: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}
