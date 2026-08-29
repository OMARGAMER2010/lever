import SwiftUI
import ExeRarCore

@main
struct ExeRarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}
