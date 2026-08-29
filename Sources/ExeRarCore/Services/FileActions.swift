import AppKit
import UniformTypeIdentifiers

public enum FileActions {
    @MainActor
    public static func chooseFile(extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Seleccionar archivo"
        panel.prompt = "Elegir"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }

        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Seleccionar carpeta de destino"
        panel.prompt = "Elegir carpeta"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseWine() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Seleccionar Wine"
        panel.prompt = "Usar Wine"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true

        return panel.runModal() == .OK ? panel.url : nil
    }
}
