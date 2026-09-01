import AppKit
import UniformTypeIdentifiers

public enum FileActions {
    @MainActor
    public static func chooseFile(kind: SupportedFileKind, title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let types = kind.extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        // Muchos comprimidos comparten tipo con otros formatos; se deja elegir cualquiera.
        panel.allowsOtherFileTypes = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseDirectory(startingAt directory: URL? = nil, title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseWine(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Elige un archivo sin filtrar por tipo.
    ///
    /// Hace falta para el `prod.keys`, que no tiene ningún tipo registrado en macOS: filtrando por
    /// extensión el panel lo enseñaría en gris y el usuario no podría elegirlo.
    @MainActor
    public static func chooseAnyFile(title: String, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Elige una aplicación. Un `.app` es una carpeta, y sin `treatsFilePackagesAsDirectories` a
    /// `false` el panel deja entrar dentro en vez de dejar elegirla.
    @MainActor
    public static func chooseApplication(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Muestra el archivo o la carpeta en el Finder.
    @MainActor
    public static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    public static func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    public static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
