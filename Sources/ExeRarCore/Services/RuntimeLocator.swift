import Foundation

public struct RuntimeLocator {
    private let fileManager: FileManager
    private let wineCandidates: [URL]
    private let sevenZipCandidates: [URL]
    private let unarCandidates: [URL]
    private let unrarCandidates: [URL]
    private let homebrewCandidates: [URL]

    public init(
        fileManager: FileManager = .default,
        wineCandidates: [URL] = RuntimeLocator.defaultWineCandidates(),
        sevenZipCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "7zz"),
        unarCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "unar"),
        unrarCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "unrar"),
        homebrewCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "brew")
    ) {
        self.fileManager = fileManager
        self.wineCandidates = wineCandidates
        self.sevenZipCandidates = sevenZipCandidates
        self.unarCandidates = unarCandidates
        self.unrarCandidates = unrarCandidates
        self.homebrewCandidates = homebrewCandidates
    }

    public func locate(customWineURL: URL? = nil) -> RuntimeStatus {
        let wineURL = customWineURL
            .flatMap { Self.resolveWineURL($0, fileManager: fileManager) }
            ?? firstExecutable(in: wineCandidates)

        let archiveTool = firstExecutable(in: sevenZipCandidates).map(ArchiveTool.sevenZip)
            ?? firstExecutable(in: unarCandidates).map(ArchiveTool.unar)
            ?? firstExecutable(in: unrarCandidates).map(ArchiveTool.unrar)

        return RuntimeStatus(
            wineURL: wineURL,
            archiveTool: archiveTool,
            homebrewURL: firstExecutable(in: homebrewCandidates)
        )
    }

    public static func resolveWineURL(_ url: URL, fileManager: FileManager = .default) -> URL? {
        let isAppBundle = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        let candidate = isAppBundle
            ? url.appendingPathComponent("Contents/Resources/wine/bin/wine")
            : url

        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    public static func defaultWineCandidates() -> [URL] {
        defaultExecutableCandidates(named: "wine") + [
            URL(fileURLWithPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine")
        ]
    }

    public static func defaultExecutableCandidates(named name: String) -> [URL] {
        let directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    }

    private func firstExecutable(in candidates: [URL]) -> URL? {
        candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}
