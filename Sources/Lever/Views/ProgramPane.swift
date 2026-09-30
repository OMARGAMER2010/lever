import SwiftUI
import LeverCore

/// Pestaña «Programas»: elegir un .exe o .msi y lanzarlo con Wine.
struct ProgramPane: View {
    @ObservedObject var model: AppModel
    @State private var showsWineHelp = false

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.windowsSteamIsReady { steamPanel }
            if model.selectedProgram == nil && model.selectedFolder == nil {
                DropZone(
                    title: s[.dropProgramTitle],
                    subtitle: s[.dropProgramSubtitle],
                    systemImage: "arrow.down.doc",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectProgram
                )
                RecentsList(model: model, kind: .folder, heading: .folderRecentsTitle)
                RecentsList(model: model, kind: .exe)
            }
            if model.selectedFolder != nil { folderPanel }
            if model.selectedProgram != nil {
                Panel { programContent }
            }

            if model.programOpenMode == .safe { SafeModeSummary(model: model) }

            // Va antes que la tarjeta de Wine a propósito: si el juego puede correr nativo, esa
            // es la opción buena y Wine pasa a ser el plan B, no al revés. En Safe Mode no: la app
            // nativa correría sin aislamiento.
            if model.portableGame != nil {
                if model.programOpenMode == .safe {
                    Text(s[.safeNoNativePort])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    portablePanel
                }
            }

            wineState
            disclaimer
        }
        .sheet(isPresented: $showsWineHelp) { RuntimeHelpSheet.wine(model: model) }
    }

    /// A folder is a collection of possible starting points. Show the choice before Wine's
    /// controls so a redistributable or crash reporter cannot silently become the game.
    @ViewBuilder
    private var folderPanel: some View {
        if let folder = model.selectedFolder {
            Panel(padding: Theme.Spacing.normal) {
                VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                    SelectedFileChip(
                        url: folder,
                        facts: [folder.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~")],
                        revealLabel: s[.revealInFinder],
                        removeLabel: s[.folderRemove],
                        onReveal: { FileActions.reveal(folder) },
                        onClear: model.clearFolder
                    )
                    if model.isInspectingFolder {
                        HStack(spacing: Theme.Spacing.tight) {
                            ProgressView().controlSize(.small)
                            Text(s[.folderScanning]).font(.system(size: 11))
                        }
                    } else if let inspection = model.folderInspection {
                        if inspection.entries.isEmpty {
                            Text(s[.folderEmpty])
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(s(.folderFound, String(inspection.entries.count)))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            ForEach(inspection.entries) { entry in
                                folderEntryRow(entry, in: inspection)
                            }
                        }
                        if inspection.wasLimited {
                            Text(s[.folderLimited])
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.attention)
                        }
                        if let redistributables = inspection.redistributablesURL {
                            HStack(alignment: .top, spacing: Theme.Spacing.tight) {
                                Text(s(.folderRedistributables, redistributables.lastPathComponent))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Button(s[.revealInFinder]) { FileActions.reveal(redistributables) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private func folderEntryRow(_ entry: FolderEntry, in inspection: FolderInspection) -> some View {
        let isSelected = model.selectedProgram == entry.url
        let relative = String(entry.url.path.dropFirst(inspection.folder.path.count + 1))
        return HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: folderEntryIcon(entry.kind))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                    if inspection.recommended == entry {
                        Text(s[.folderRecommended])
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ready)
                    }
                }
                Text("\(folderEntryDescription(entry)) · \(relative)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if isSelected {
                Label(s[.folderSelected], systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ready)
            } else {
                Button(s[entry.kind == .macApplication ? .folderOpenEntry : .folderChooseEntry]) {
                    model.openFolderEntry(entry)
                }
                .controlSize(.small)
            }
        }
        .padding(7)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.Radius.inline))
    }

    private func folderEntryDescription(_ entry: FolderEntry) -> String {
        let key: TextKey
        switch entry.kind {
        case .windowsProgram:
            key = entry.isUnityGame ? .folderUnityWindows
                : entry.isInstaller ? .folderWindowsInstaller : .folderWindowsProgram
        case .androidApp: key = .folderAndroidApp
        case .consoleGame: key = .folderConsoleGame
        case .archive: key = .folderArchive
        case .macApplication: key = .folderMacApplication
        }
        let architecture = entry.architecture.flatMap { $0 == .unknown ? nil : s[$0.textKey] }
        return [s[key], architecture].compactMap { $0 }.joined(separator: " · ")
    }

    private func folderEntryIcon(_ kind: FolderEntryKind) -> String {
        switch kind {
        case .windowsProgram: return "gamecontroller"
        case .androidApp: return "apps.iphone"
        case .consoleGame: return "gamecontroller.fill"
        case .archive: return "archivebox"
        case .macApplication: return "macwindow"
        }
    }

    // MARK: - Juego que puede correr nativo

    /// La biblioteca de Steam para Windows: abrirla, y abrir cualquier juego instalado en ella.
    private var steamPanel: some View {
        Panel(padding: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(s[.windowsSteamTitle])
                    .font(.system(size: 12, weight: .semibold))
                Text(s[.windowsSteamBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(s[model.isOpeningWindowsSteam ? .windowsSteamOpening : .windowsSteamOpen],
                       action: model.openWindowsSteam)
                    .controlSize(.small)
                    .disabled(model.isOpeningWindowsSteam)
                if model.steamGames.isEmpty {
                    Text(s[.steamGamesNone])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.steamGames) { steamGameRow($0) }
                }
                if let options = model.steamExecutableOptions { executablePicker(options) }
            }
        }
        .onAppear(perform: model.refreshSteamGames)
    }

    private func steamGameRow(_ game: SteamGame) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name).font(.system(size: 11, weight: .medium))
                if model.steamExecutable(for: game) != nil {
                    Text(s[.steamGameViaExecutable])
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.tight)
            Button(s[model.openingSteamAppID == game.appID ? .steamGameOpening : .steamGamePlay]) {
                model.runSteamGame(game)
            }
            .controlSize(.small)
            .disabled(model.openingSteamAppID != nil)
            Menu {
                Button(s[.steamGamePickExecutable]) { model.askForSteamExecutable(game) }
                if model.steamExecutable(for: game) != nil {
                    Button(s[.steamGameUseSteam]) { model.useSteamForGame(game) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(s[.steamGameOptions])
        }
    }

    /// Los ejecutables entre los que elegir. Se muestran aquí mismo, debajo del juego, en vez
    /// de en una hoja aparte: es una decisión de un clic y no merece tapar la ventana.
    private func executablePicker(_ options: AppModel.SteamExecutableOptions) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s(.steamGamePickHint, options.game.name))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if options.executables.isEmpty {
                Text(s[.steamGameNoExecutables]).font(.system(size: 11))
            }
            ForEach(options.executables, id: \.self) { executable in
                Button(executable.lastPathComponent) {
                    model.useSteamExecutable(executable, for: options.game)
                }
                .controlSize(.small)
            }
            Button(s[.close], action: model.cancelSteamExecutableChoice)
                .controlSize(.small)
        }
    }

    /// Aparece solo cuando el `.exe` resulta ser el envoltorio de un motor que sí existe para Mac.
    @ViewBuilder
    private var portablePanel: some View {
        if let game = model.portableGame {
            Panel(padding: Theme.Spacing.normal) {
                VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                    Text(s(.portableTitle, game.displayName))
                        .font(.system(size: 12, weight: .semibold))

                    if !game.isSupported {
                        Text(s(game.unsupportedKey, game.runtimeVersionText))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(s[game.bodyKey])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(model.portableRuntimeIsCached
                             ? s[.portableRuntimeCached]
                             : s(.portableRuntimeDownload, game.runtimeVersionText, game.runtimeDownloadSize))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let note = game.extraNoteKey {
                            Text(s[note])
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        portableParts
                        portableActions
                    }
                }
            }
        }
    }

    /// Lo que el desarrollador no compiló para Mac. Se enseña siempre que exista: decide si el
    /// juego funcionará entero o solo a medias, y es mejor saberlo antes que descubrirlo jugando.
    @ViewBuilder
    private var portableParts: some View {
        let pending = model.portableUnresolvedParts
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(s(.portablePartsNeeded, pending.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if pending.contains(where: { $0.recipe != nil }) {
                    Toggle(s[.portableBuildParts], isOn: $model.buildsMissingExtensions)
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                        .disabled(model.isPorting)
                    ForEach(pending.compactMap(\.recipe), id: \.addonName) { recipe in
                        Text("\(recipe.displayName): \(s[recipe.purposeKey]) · ~\(recipe.approximateMinutes) min")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                if pending.contains(where: { $0.recipe == nil }) {
                    Text(s[.portablePartUnknown])
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var portableActions: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if model.isPorting {
                ProgressView().controlSize(.small)
                Text(model.portStageMessage.isEmpty ? s[.portablePorting] : model.portStageMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(s[.stop], action: model.stopPorting)
            } else {
                Button(s[.portableMakeApp], action: model.makeNativeApp)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canMakeNativeApp)
                Text(s[.portableWhereItGoes])
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var programContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            if let program = model.selectedProgram {
                SelectedFileChip(
                    url: program,
                    facts: programFacts(for: program),
                    revealLabel: s[.revealInFinder],
                    removeLabel: s[.removeFile],
                    onReveal: { FileActions.reveal(program) },
                    onClear: model.clearProgram
                )
            }

            if model.programWontRunOnThisWine {
                NoticeBanner(kind: .warning, title: s[.arch32Title], message: s[.arch32Warning])
            } else {
                Text(s[.programWillOpen])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
            OpenModePicker(
                model: model,
                mode: $model.programOpenMode,
                recommendation: model.programRecommendation,
                normalExplanation: .normalProgramExplain,
                safeExplanation: .safeProgramExplain
            )
            if model.programOpenMode == .safe {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(s[.safeAllowNetwork], isOn: $model.allowsNetworkInSafeRun)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(model.isRunningProgram || model.isPreparingWindows)
                    Text(s[.safeAllowNetworkHint])
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Datos leídos del propio archivo: tamaño y arquitectura de la cabecera PE. La arquitectura
    /// importa porque los Wine que funcionan hoy en Apple Silicon son solo de 64 bits.
    private func programFacts(for program: URL) -> [String] {
        var facts: [String] = []
        if let size = program.formattedFileSize { facts.append(size) }
        if model.programArchitecture != .unknown {
            facts.append(s[model.programArchitecture.textKey])
        }
        facts.append(program.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        return facts
    }

    @ViewBuilder
    private var wineState: some View {
        if model.wineIsBlocked {
            NoticeBanner(
                kind: .failure,
                title: s[.wineBlockedTitle],
                message: s[.wineBlockedBody],
                actionTitle: model.isUnblockingWine ? s[.unblocking] : s[.unblockWine],
                action: { model.unblockWine() }
            )
        } else if model.runtimeStatus.wineURL == nil {
            NoticeBanner(
                kind: .warning,
                title: s[.missingWineTitle],
                message: s[.missingWineBody],
                actionTitle: s[.howToInstall],
                action: { showsWineHelp = true }
            )
        } else if !model.runtimeStatus.hasRosetta {
            NoticeBanner(kind: .failure, title: s[.rosettaTitle], message: s[.rosettaBody])
        } else {
            windowsPanel
        }
    }

    private var windowsPanel: some View {
        Panel(padding: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                    Text(s[.windowsCardTitle])
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

                Text(s[.windowsCardBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.tight) {
                    Button(s[.wineSettings], action: model.openWineSettings)
                    Button(s[.closeAll], action: model.closeWindowsPrograms)
                    Button(s[.resetWindows], action: model.resetWindowsEnvironment)
                    Spacer()
                    Button(s[.otherWine], action: model.selectWine)
                }
                .controlSize(.small)
            }
        }
    }

    private var disclaimer: some View {
        Text(s[.wineDisclaimer])
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
