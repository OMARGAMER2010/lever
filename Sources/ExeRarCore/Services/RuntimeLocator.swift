import Foundation

/// Busca en el sistema las herramientas externas de las que depende la app.
public struct RuntimeLocator {
    private let fileManager: FileManager
    private let wineCandidates: [URL]
    private let sevenZipCandidates: [URL]
    private let unarCandidates: [URL]
    private let unrarCandidates: [URL]
    private let homebrewCandidates: [URL]
    private let rosettaMarker: URL?

    public init(
        fileManager: FileManager = .default,
        wineCandidates: [URL] = RuntimeLocator.defaultWineCandidates(),
        sevenZipCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "7zz"),
        unarCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "unar"),
        unrarCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "unrar"),
        homebrewCandidates: [URL] = RuntimeLocator.defaultExecutableCandidates(named: "brew"),
        rosettaMarker: URL? = RuntimeLocator.defaultRosettaMarker
    ) {
        self.fileManager = fileManager
        self.wineCandidates = wineCandidates
        self.sevenZipCandidates = sevenZipCandidates
        self.unarCandidates = unarCandidates
        self.unrarCandidates = unrarCandidates
        self.homebrewCandidates = homebrewCandidates
        self.rosettaMarker = rosettaMarker
    }

    public func locate(customWineURL: URL? = nil) -> RuntimeStatus {
        let wineURL = customWineURL
            .flatMap { Self.resolveWineURL($0, fileManager: fileManager) }
            ?? firstExecutable(in: wineCandidates)

        let archiveTools = [
            firstExecutable(in: sevenZipCandidates).map(ArchiveTool.sevenZip),
            firstExecutable(in: unarCandidates).map(ArchiveTool.unar),
            firstExecutable(in: unrarCandidates).map(ArchiveTool.unrar)
        ].compactMap { $0 }

        return RuntimeStatus(
            wineURL: wineURL,
            archiveTools: archiveTools,
            homebrewURL: firstExecutable(in: homebrewCandidates),
            hasRosetta: hasRosetta
        )
    }

    /// En Apple Silicon, Wine se ejecuta bajo Rosetta 2. En Intel no hace falta.
    public var hasRosetta: Bool {
        #if arch(arm64)
        guard let rosettaMarker else { return true }
        return fileManager.fileExists(atPath: rosettaMarker.path)
        #else
        return true
        #endif
    }

    /// Localiza `lsar`, el listador que acompaña a `unar`, junto al extractor elegido.
    public func listerURL(for tool: ArchiveTool) -> URL? {
        let sibling = tool.executableURL.deletingLastPathComponent().appendingPathComponent("lsar")
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling }
        return Self.defaultExecutableCandidates(named: "lsar")
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Acepta tanto el binario `wine` como una app `Wine*.app` y devuelve el ejecutable real.
    public static func resolveWineURL(_ url: URL, fileManager: FileManager = .default) -> URL? {
        let isAppBundle = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        guard isAppBundle else {
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }

        let inner = [
            "Contents/Resources/wine/bin/wine",
            "Contents/Resources/wine/bin/wine64",
            "Contents/SharedSupport/wine/bin/wine",
            "Contents/MacOS/wine"
        ]

        return inner
            .map { url.appendingPathComponent($0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public static func defaultWineCandidates() -> [URL] {
        let bundled = [
            // Compilaciones para Apple Silicon, las que mejor funcionan hoy.
            "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64",
            "/Applications/Whisky.app/Contents/Resources/Libraries/Wine/bin/wine64",
            "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            "/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine",
            "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine",
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine",
            "/Applications/Whisky.app/Contents/Resources/Libraries/Wine/bin/wine"
        ].map { URL(fileURLWithPath: $0) }

        return defaultExecutableCandidates(named: "wine")
            + defaultExecutableCandidates(named: "wine64")
            + bundled
    }

    public static func defaultExecutableCandidates(named name: String) -> [URL] {
        let directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
    }

    public static let defaultRosettaMarker = URL(fileURLWithPath: "/usr/libexec/rosetta/oahd")

    /// Directorios donde Homebrew y compañía instalan binarios, para reconstruir el `PATH`.
    /// Una app abierta desde el Finder no hereda el `PATH` de la Terminal.
    public static var searchPathDirectories: [String] {
        ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin",
         "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    private func firstExecutable(in candidates: [URL]) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
