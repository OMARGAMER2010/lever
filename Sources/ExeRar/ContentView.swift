import SwiftUI
import ExeRarCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var mode: WorkMode = .archive
    @State private var showsActivity = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    if model.isInstallingTools {
                        NoticeBanner(
                            kind: .info,
                            title: "Instalando lo que falta",
                            message: "Homebrew está trabajando. Puede tardar unos minutos; mira la actividad de abajo para seguirlo."
                        )
                    }

                    if let error = model.lastError {
                        NoticeBanner(
                            kind: .failure,
                            title: "Algo no ha salido bien",
                            message: error
                        )
                        .transition(.opacity)
                    }

                    switch mode {
                    case .program:
                        ProgramPane(model: model)
                    case .archive:
                        ArchivePane(model: model)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, Theme.Spacing.loose)
                .padding(.bottom, Theme.Spacing.page)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            ActionBar(model: model, mode: mode)
            ActivityPane(model: model, isExpanded: $showsActivity)
        }
        .animation(.easeOut(duration: 0.2), value: model.lastError)
        .animation(.easeOut(duration: 0.2), value: mode)
        // Se puede soltar un archivo en cualquier parte de la ventana, no solo en la zona marcada.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropZone.load(providers) { urls in
                model.accept(droppedURLs: urls)
                if let first = urls.first {
                    mode = SupportedFileKind.exe.accepts(first) ? .program : .archive
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModeSwitcher(mode: $mode)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ToolChip(
                    title: "Wine",
                    detail: model.runtimeStatus.wineURL?.lastPathComponent ?? "sin instalar",
                    isAvailable: model.runtimeStatus.wineURL != nil
                )
                ToolChip(
                    title: "Extractor",
                    detail: model.runtimeStatus.archiveToolName ?? "sin instalar",
                    isAvailable: model.runtimeStatus.archiveTool != nil
                )

                Menu {
                    Button("Volver a buscar herramientas", action: model.refreshTools)
                    Divider()
                    Button("Instalar lo que falta", action: model.installTools)
                        .disabled(!model.canInstallTools || model.runtimeStatus.isComplete)
                    Button("Buscar Wine a mano…", action: model.selectWine)
                    Button("Olvidar el Wine elegido", action: model.forgetCustomWine)
                    Button("Desbloquear Wine", action: model.unblockWine)
                        .disabled(!model.wineIsBlocked)
                    Divider()
                    Button("Restablecer Windows", action: model.resetWindowsEnvironment)
                    Button("Abrir la carpeta de Windows") {
                        FileActions.openInFinder(model.windowsFolderURL)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("Herramientas")
            }
        }
        .onAppear {
            if model.log.isEmpty { model.refreshTools() }
        }
        .onChange(of: model.selectedProgram) { program in
            if program != nil { mode = .program }
        }
        .onChange(of: model.selectedArchive) { archive in
            if archive != nil { mode = .archive }
        }
    }
}
