import SwiftUI
import ExeRarCore

/// Pestaña «Programas»: elegir un .exe o .msi y lanzarlo con Wine.
struct ProgramPane: View {
    @ObservedObject var model: AppModel
    @State private var showsWineHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.selectedProgram == nil {
                DropZone(
                    title: "Arrastra aquí un programa de Windows",
                    subtitle: "Archivos .exe y .msi · o pulsa para buscarlo",
                    systemImage: "arrow.down.doc.fill",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectProgram
                )
            } else {
                Card { programCardContent }
            }

            if model.wineIsBlocked {
                NoticeBanner(
                    kind: .failure,
                    title: "macOS tiene Wine bloqueado",
                    message: "Wine se descargó de internet y macOS lo cierra nada más abrirlo. Desbloquéalo para poder usarlo: es la misma autorización que darías al abrir la app por primera vez.",
                    actionTitle: model.isUnblockingWine ? "Desbloqueando…" : "Desbloquear Wine",
                    action: { model.unblockWine() }
                )
            } else if model.runtimeStatus.wineURL == nil {
                NoticeBanner(
                    kind: .warning,
                    title: "Falta Wine",
                    message: "macOS no abre archivos .exe por su cuenta. Wine es la capa que los traduce. Se instala una vez y la app lo encuentra sola.",
                    actionTitle: "Cómo instalarlo",
                    action: { showsWineHelp = true }
                )
            } else if !model.runtimeStatus.hasRosetta {
                NoticeBanner(
                    kind: .failure,
                    title: "Falta Rosetta 2",
                    message: "Wine es un programa Intel y tu Mac necesita Rosetta 2 para ejecutarlo. Instálalo desde la Terminal con: softwareupdate --install-rosetta"
                )
            } else {
                windowsCard
            }

            Text("Wine no es Windows: los programas que necesitan controladores, sistemas anti-trampas o gráficos avanzados suelen fallar. Los instaladores y las utilidades sencillas son los que mejor funcionan.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showsWineHelp) {
            WineHelpSheet(model: model)
        }
    }

    @ViewBuilder
    private var programCardContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            if let program = model.selectedProgram {
                SelectedFileChip(
                    url: program,
                    tint: Theme.indigo,
                    onReveal: { FileActions.reveal(program) },
                    onClear: model.clearProgram
                )
            }

            Text("Al ejecutarlo se abrirá en su propia ventana, como cualquier programa de Windows.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Herramientas del entorno de Windows que la app mantiene aparte.
    private var windowsCard: some View {
        Card(padding: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.indigo)
                    Text("Tu Windows dentro del Mac")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let wine = model.runtimeStatus.wineURL {
                        Text(wine.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Text("La app guarda su propio disco C: en una carpeta aparte, así no toca ninguna otra instalación de Wine que tengas.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.tight) {
                    QuietButton(title: "Ajustes de Wine", systemImage: "slider.horizontal.3", action: model.openWineSettings)
                    QuietButton(title: "Cerrar todo", systemImage: "power", action: model.closeWindowsPrograms)
                    QuietButton(title: "Restablecer", systemImage: "arrow.counterclockwise", action: model.resetWindowsEnvironment)
                    Spacer()
                    QuietButton(title: "Otro Wine", systemImage: "magnifyingglass", action: model.selectWine)
                }
            }
        }
    }

}
