import Darwin
import Foundation

/// An item Lever can open from a directory supplied by the user.
public enum FolderEntryKind: Equatable, Sendable {
    case windowsProgram
    case androidApp
    case consoleGame
    case archive
    case macApplication
}

public struct FolderEntry: Identifiable, Equatable, Sendable {
    public let url: URL
    public let kind: FolderEntryKind
    public let architecture: ProgramArchitecture?
    public let isUnityGame: Bool
    public let isInstaller: Bool
    public let score: Int

    public var id: URL { url }
}

public struct FolderInspection: Equatable, Sendable {
    public let folder: URL
    public let entries: [FolderEntry]
    public let inspectedCount: Int
    public let wasLimited: Bool
    public let redistributablesURL: URL?

    public var recommended: FolderEntry? { entries.first }
}

/// Looks for launchable files without opening game assets or following links out of the folder.
/// The limits keep a very large or malformed directory from holding up the UI indefinitely.
public enum FolderInspector {
    public static func inspect(
        _ folder: URL,
        fileManager: FileManager = .default,
        maximumEntries: Int = 20_000,
        maximumDepth: Int = 8
    ) -> FolderInspection {
        let selected = folder.standardizedFileURL
        let empty = FolderInspection(folder: selected, entries: [], inspectedCount: 0,
                                     wasLimited: false, redistributablesURL: nil)
        guard let rootValues = try? selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let canonical = realpath(selected.path, nil) else { return empty }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)

        if root.pathExtension.lowercased() == "app" {
            return FolderInspection(folder: root, entries: [FolderEntry(
                url: root, kind: .macApplication, architecture: nil,
                isUnityGame: false, isInstaller: false, score: 120
            )], inspectedCount: 1, wasLimited: false, redistributablesURL: nil)
        }

        let wantedExtensions = Set(SupportedFileKind.allCases.flatMap(\.extensions))
        let rootPrefix = root.path + "/"
        let rootName = comparableName(root.lastPathComponent)
        var candidates: [FolderEntry] = []
        var count = 0
        var limited = false
        var redistributables: URL?

        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            count += 1
            if count > maximumEntries {
                limited = true
                break
            }
            guard url.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(url.path.dropFirst(rootPrefix.count))
            let depth = relative.split(separator: "/").count
            if depth > maximumDepth {
                limited = true
                enumerator?.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                enumerator?.skipDescendants()
                continue
            }

            if values.isDirectory == true {
                let lower = url.lastPathComponent.lowercased()
                if lower == "_redist" || lower == "_commonredist" || lower == "redist" {
                    redistributables = redistributables ?? url
                    enumerator?.skipDescendants()
                    continue
                }
                if lower == ".git" || lower == "node_modules" || lower == "__macosx"
                    || lower.hasSuffix("_data") {
                    enumerator?.skipDescendants()
                    continue
                }
                if url.pathExtension.lowercased() == "app" {
                    candidates.append(FolderEntry(url: url, kind: .macApplication,
                                                  architecture: nil, isUnityGame: false,
                                                  isInstaller: false, score: 120 - depth))
                    enumerator?.skipDescendants()
                    continue
                }
                if depth <= 3, PlayStationInspector.inspect(url).isRecognised {
                    candidates.append(FolderEntry(url: url, kind: .consoleGame,
                                                  architecture: nil, isUnityGame: false,
                                                  isInstaller: false, score: 105 - depth))
                    enumerator?.skipDescendants()
                }
                continue
            }

            let ext = url.pathExtension.lowercased()
            guard wantedExtensions.contains(ext) else { continue }
            let route = FileRouter.route(for: url)
            let kind: FolderEntryKind
            switch route {
            case .program: kind = .windowsProgram
            case .android: kind = .androidApp
            case .rom: kind = .consoleGame
            case .archive: kind = .archive
            case .folder, nil: continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            let lower = stem.lowercased()
            if kind == .windowsProgram,
               ["crashhandler", "crashreport", "crashpad"].contains(where: lower.contains) {
                continue
            }
            let installer = kind == .windowsProgram && isSupportProgram(lower)
            let unity = kind == .windowsProgram && ext == "exe"
                && fileManager.fileExists(atPath: url.deletingLastPathComponent()
                    .appendingPathComponent(stem + "_Data", isDirectory: true).path)
                && fileManager.fileExists(atPath: url.deletingLastPathComponent()
                    .appendingPathComponent("UnityPlayer.dll").path)
            let architecture = kind == .windowsProgram && ext == "exe"
                ? ProgramInspector.architecture(of: url) : nil
            var score: Int
            switch kind {
            case .windowsProgram: score = installer ? 15 : 75
            case .macApplication: score = 120
            case .androidApp, .consoleGame: score = 90
            case .archive: score = 35
            }
            if unity { score += 45 }
            if comparableName(stem) == comparableName(url.deletingLastPathComponent().lastPathComponent) {
                score += 22
            }
            if comparableName(stem) == rootName { score += 18 }
            score -= depth
            candidates.append(FolderEntry(url: url, kind: kind, architecture: architecture,
                                          isUnityGame: unity, isInstaller: installer, score: score))
        }

        let sorted = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        if sorted.count > 100 { limited = true }
        return FolderInspection(folder: root, entries: Array(sorted.prefix(100)),
                                inspectedCount: min(count, maximumEntries), wasLimited: limited,
                                redistributablesURL: redistributables)
    }

    private static func comparableName(_ name: String) -> String {
        let base = name.lowercased().replacingOccurrences(
            of: #"[._ -]v?\d+(?:\.\d+)+(?:.*)$"#, with: "", options: .regularExpression
        )
        return base.filter(\.isLetter)
    }

    private static func isSupportProgram(_ name: String) -> Bool {
        ["vcredist", "vcredis", "dxsetup", "dxwebsetup", "directx", "dotnet", "oalinst",
         "unins", "setup", "install", "redist", "crashhandler", "crashreport", "crashpad"]
            .contains { name.contains($0) }
    }
}
