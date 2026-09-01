import SwiftUI
import LeverCore

/// Pestaña «Programas»: elegir un .exe o .msi y lanzarlo con Wine.
struct ProgramPane: View {
    @ObservedObject var model: AppModel
    @State private var showsWineHelp = false

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.selectedProgram == nil {
                DropZone(
                    title: s[.dropProgramTitle],
                    subtitle: s[.dropProgramSubtitle],
                    systemImage: "arrow.down.doc",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectProgram
                )
                RecentsList(model: model, kind: .exe)
            } else {
                Panel { programContent }
            }

            // Va antes que la tarjeta de Wine a propósito: si el juego puede correr nativo, esa
            // es la opción buena y Wine pasa a ser el plan B, no al revés.
            if model.portableGame != nil { portablePanel }

            wineState
            disclaimer
        }
        .sheet(isPresented: $showsWineHelp) { RuntimeHelpSheet.wine(model: model) }
    }

    // MARK: - Juego que puede correr nativo

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
