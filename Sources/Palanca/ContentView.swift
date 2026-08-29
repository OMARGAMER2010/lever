import SwiftUI
import PalancaCore

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
                if let first = urls.first {
                    mode = SupportedFileKind.exe.accepts(first) ? .program : .archive
                }
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

            ToolbarItemGroup(placement: .primaryAction) {
                ToolStatus(
                    title: s[.toolWine],
                    detail: model.runtimeStatus.wineURL?.lastPathComponent ?? s[.toolNotInstalled],
                    isAvailable: model.runtimeStatus.wineURL != nil && !model.wineIsBlocked
                )
                ToolStatus(
                    title: s[.toolExtractor],
                    detail: model.runtimeStatus.archiveToolName ?? s[.toolNotInstalled],
                    isAvailable: model.runtimeStatus.archiveTool != nil
                )

                Menu {
                    Button(s[.menuRefresh], action: model.refreshTools)
                    Divider()
                    Button(s[.menuInstallExtractors], action: model.installTools)
                        .disabled(!model.canInstallTools)
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
    }
}
