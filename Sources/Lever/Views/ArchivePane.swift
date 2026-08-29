import SwiftUI
import LeverCore

/// Pestaña «Comprimidos»: elegir un .rar (o .zip, .7z…) y sacar su contenido.
struct ArchivePane: View {
    @ObservedObject var model: AppModel
    @State private var showsContents = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.selectedArchive == nil {
                DropZone(
                    title: s[.dropArchiveTitle],
                    subtitle: s[.dropArchiveSubtitle],
                    systemImage: "archivebox",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectArchive
                )
                RecentsList(model: model, kind: .rar)
            } else {
                Panel { archiveContent }
            }

            if model.runtimeStatus.archiveTool == nil {
                NoticeBanner(
                    kind: .warning,
                    title: s[.missingExtractorTitle],
                    message: s[.missingExtractorBody],
                    actionTitle: model.canInstallTools ? s[.install] : nil,
                    action: model.canInstallTools ? { model.installTools() } : nil
                )
            }

            Text(s[.originalUntouched])
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var archiveContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            if let archive = model.selectedArchive {
                SelectedFileChip(
                    url: archive,
                    facts: archiveFacts(for: archive),
                    revealLabel: s[.revealInFinder],
                    removeLabel: s[.removeFile],
                    onReveal: { FileActions.reveal(archive) },
                    onClear: model.clearArchive
                )
                toolChoice
                contentsPreview
                Divider()
                options
            }
        }
    }

    /// Lo que la app ha averiguado leyendo el archivo. Solo hechos observados.
    private func archiveFacts(for archive: URL) -> [String] {
        var facts = [archive.archiveFormatName]
        if let size = archive.formattedFileSize { facts.append(size) }
        if archive.looksLikeArchivePart { facts.append(s[.archiveMultipart]) }
        if model.archiveFacts.listingFailed { facts.append(s[.archiveEncrypted]) }
        return facts
    }

    /// Por qué se va a usar esta herramienta y no la otra. Es la decisión menos evidente que toma
    /// la app, y la que más daño hace si se equivoca, así que se dice en voz alta.
    @ViewBuilder
    private var toolChoice: some View {
        if let tool = model.toolForSelectedArchive {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "wrench.adjustable")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(s(.willOpenWith, tool.displayName))
                    .font(.system(size: 11, weight: .medium))
                if model.toolChoiceNeedsExplaining {
                    Text(s[.willOpenWithWhy])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Opciones de extracción

    private var options: some View {
        VStack(alignment: .leading, spacing: 11) {
            SettingRow(label: s[.saveIn]) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(destinationText)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if model.chosenDestination != nil {
                        Button(s[.automatic], action: model.useSuggestedDestination)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    Button(s[.change], action: model.selectDestination)
                        .controlSize(.small)
                }
            }

            SettingRow(label: s[.ownFolder], hint: s[.ownFolderHint]) {
                Toggle("", isOn: $model.extractIntoSubfolder)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(s[.ownFolder])
            }

            SettingRow(label: s[.password], hint: s[.passwordHint]) {
                SecureField(s[.passwordNone], text: $model.archivePassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel(s[.password])
            }

            SettingRow(label: s[.ifExists], hint: policyHint) {
                Picker("", selection: $model.overwritePolicy) {
                    ForEach(OverwritePolicy.allCases) { policy in
                        Text(s[policyLabel(policy)]).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityLabel(s[.ifExists])
            }

            SettingRow(label: s[.whenDone], hint: s[.whenDoneHint]) {
                Toggle("", isOn: $model.revealWhenDone)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(s[.whenDone])
            }
        }
    }

    private func policyLabel(_ policy: OverwritePolicy) -> TextKey {
        switch policy {
        case .skip: return .policySkip
        case .rename: return .policyRename
        case .overwrite: return .policyOverwrite
        }
    }

    private var policyHint: String {
        switch model.overwritePolicy {
        case .skip: return s[.policySkipWhy]
        case .rename: return s[.policyRenameWhy]
        case .overwrite: return s[.policyOverwriteWhy]
        }
    }

    private var destinationText: String {
        guard let destination = model.effectiveDestination else { return "—" }
        return destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Contenido del comprimido

    @ViewBuilder
    private var contentsPreview: some View {
        if model.isInspecting {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(s[.contentsReading])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if !model.archiveContents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if reduceMotion { showsContents.toggle() }
                    else { withAnimation(.easeOut(duration: 0.15)) { showsContents.toggle() } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsContents ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(s(.contentsItems, String(model.archiveContents.count)))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)

                if showsContents { contentsList }
            }
        }
    }

    private var contentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(model.archiveContents.prefix(300)), id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.archiveContents.count > 300 {
                    Text(s(.contentsAndMore, String(model.archiveContents.count - 300)))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 120)
    }
}
