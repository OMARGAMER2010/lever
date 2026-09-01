import SwiftUI
import LeverCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var mode: WorkMode = .archive
    @State private var showsActivity = false

    private var s: Strings { model.strings }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    if model.isInstallingTools {
                        NoticeBanner(
                            kind: .warning,
                            title: s[.installingTitle],
                            message: s[.installingBody]
                        )
                    }

                    if let error = model.lastError {
                        NoticeBanner(kind: .failure, title: s[.errorTitle], message: error)
                    }

                    switch mode {
                    case .program: ProgramPane(model: model)
                    case .archive: ArchivePane(model: model)
                    case .android: AndroidPane(model: model)
                    case .rom: EmulationPane(model: model)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.loose)
                .frame(maxWidth: Theme.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.pageBackground)

            ActionBar(model: model, mode: mode)
            ActivityPane(model: model, isExpanded: $showsActivity)
        }
        // Se puede soltar un archivo en cualquier parte de la ventana, no solo en la zona marcada.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropZone.load(providers) { urls in
                model.accept(droppedURLs: urls)
                if let first = urls.first { mode = WorkMode.forDroppedFile(first) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    ForEach(WorkMode.allCases) { candidate in
                        Text(s[candidate.textKey]).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // La barra superior se queda solo con navegación y acciones. Los indicadores de
            // herramienta bajaron a la barra de actividad: con tres pestañas y tres indicadores
            // ya no cabían a la anchura mínima de la ventana, y macOS escondía las pestañas
            // detrás del botón de desbordamiento — justo lo que no puede esconderse.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button(s[.menuRefresh], action: model.refreshTools)
                    Divider()
                    Button(s[.menuInstallMissing], action: model.installTools)
                        .disabled(!model.canInstallTools)
                    Button(s[.menuScanDevices], action: model.refreshDevices)
                        .disabled(!model.runtimeStatus.canReachAndroid)
                    Divider()
                    Button(s[.menuFindWine], action: model.selectWine)
                    Button(s[.menuForgetWine], action: model.forgetCustomWine)
                    Button(s[.menuUnblockWine], action: model.unblockWine)
                        .disabled(!model.wineIsBlocked)
                    Divider()
                    Button(s[.menuResetWindows], action: model.resetWindowsEnvironment)
                    Button(s[.menuOpenWindowsFolder]) {
                        FileActions.openInFinder(model.windowsFolderURL)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help(s[.menuTools])
                .accessibilityLabel(s[.menuTools])

                LanguagePicker(language: $model.language, label: s[.languageMenu])
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
        .onChange(of: model.selectedApk) { apk in
            if apk != nil { mode = .android }
        }
    }

}
