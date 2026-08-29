import Foundation

public enum SupportedFileKind {
    case exe
    case rar

    public func accepts(_ url: URL) -> Bool {
        let expectedExtension: String
        switch self {
        case .exe:
            expectedExtension = "exe"
        case .rar:
            expectedExtension = "rar"
        }

        return url.pathExtension.caseInsensitiveCompare(expectedExtension) == .orderedSame
    }
}
