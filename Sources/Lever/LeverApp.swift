import AppKit
import SwiftUI
import LeverCore

@main
struct LeverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LeverApp.makeModel()

    /// La app se llamaba «EXE & RAR». Sus datos —el entorno de Windows sobre todo— viven bajo el
    /// nombre viejo, así que se recolocan antes de que el modelo lea nada.
    ///
    /// Va aquí y no en `AppModel.init` porque es un asunto del ciclo de vida de la app: metido en
    /// el modelo, cada prueba que construye un `AppModel` movería carpetas del usuario de verdad.
    private static func makeModel() -> AppModel {
        Migration.runIfNeeded()
        return AppModel()
    }

    var body: some Scene {
        // `Window` y no `WindowGroup`: esta es una utilidad de una sola ventana. Con `WindowGroup`,
        // abrir un archivo desde el Finder creaba una segunda ventana duplicada.
        Window("Lever", id: "principal") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 880, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.strings[.menuOpenProgram]) { model.selectProgram() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button(model.strings[.menuOpenArchive]) { model.selectArchive() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(model.strings[.menuOpenApk]) { model.selectApk() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }

            CommandMenu(model.strings[.menuTools]) {
                Button(model.strings[.menuRefresh]) { model.refreshTools() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button(model.strings[.menuInstallMissing]) { model.installTools() }
                    .disabled(!model.canInstallTools)
                Button(model.strings[.menuScanDevices]) { model.refreshDevices() }
                    .disabled(!model.runtimeStatus.canReachAndroid)
                Divider()
                Button(model.strings[.wineSettings]) { model.openWineSettings() }
                    .disabled(model.runtimeStatus.wineURL == nil)
                Button(model.strings[.closeAll]) { model.closeWindowsPrograms() }
                    .disabled(model.runtimeStatus.wineURL == nil)
                Divider()
                Button(model.strings[.menuCopyActivity]) { model.copyLog() }
                Button(model.strings[.menuClearActivity]) { model.clearLog() }
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
