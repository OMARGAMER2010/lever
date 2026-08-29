import AppKit
import SwiftUI
import ExeRarCore

@main
struct ExeRarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // `Window` y no `WindowGroup`: esta es una utilidad de una sola ventana. Con `WindowGroup`,
        // abrir un archivo desde el Finder creaba una segunda ventana duplicada.
        Window("EXE & RAR", id: "principal") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 880, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir programa de Windows…") { model.selectProgram() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Abrir comprimido…") { model.selectArchive() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Herramientas") {
                Button("Volver a buscar herramientas") { model.refreshTools() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Instalar lo que falta") { model.installTools() }
                    .disabled(!model.canInstallTools)
                Divider()
                Button("Ajustes de Wine…") { model.openWineSettings() }
                    .disabled(model.runtimeStatus.wineURL == nil)
                Button("Cerrar los programas de Windows") { model.closeWindowsPrograms() }
                    .disabled(model.runtimeStatus.wineURL == nil)
                Divider()
                Button("Copiar la actividad") { model.copyLog() }
                Button("Limpiar la actividad") { model.clearLog() }
            }
        }
    }
}

/// Permite abrir archivos arrastrándolos sobre el icono de la app o con «Abrir con» del Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            model?.accept(droppedURLs: urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
