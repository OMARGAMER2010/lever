import SwiftUI
import ExeRarCore

/// Pestaña «Comprimidos»: elegir un .rar (o .zip, .7z…) y sacar su contenido.
struct ArchivePane: View {
    @ObservedObject var model: AppModel
    @State private var showsContents = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.selectedArchive == nil {
                emptyState
            } else {
                Card { mainCardContent }
            }
            missingToolNotice
            footnote
        }
    }

    // MARK: - Tarjeta principal

    private var emptyState: some View {
        DropZone(
            title: "Arrastra aquí tu archivo comprimido",
            subtitle: "Archivos .rar, .zip, .7z, .tar, .iso… · o pulsa para buscarlo",
            systemImage: "archivebox.fill",
            accept: { model.accept(droppedURLs: $0) },
            browse: model.selectArchive
        )
    }

    @ViewBuilder
    private var mainCardContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            picker
        }
    }

    @ViewBuilder
    private var picker: some View {
        if let archive = model.selectedArchive {
            SelectedFileChip(
                url: archive,
                tint: Theme.amber,
                onReveal: { FileActions.reveal(archive) },
                onClear: model.clearArchive
            )
            contentsPreview
            Divider().padding(.vertical, 2)
            options
        }
    }



    @ViewBuilder
    private var missingToolNotice: some View {
        if model.runtimeStatus.archiveTool == nil {
            let canInstall = model.canInstallTools
            let install: (() -> Void)? = canInstall ? { model.installTools() } : nil
            NoticeBanner(
                kind: .warning,
                title: "Falta un extractor",
                message: "macOS no abre archivos .rar por su cuenta. Hacen falta 7zz o unar, dos herramientas libres que se instalan con Homebrew.",
                actionTitle: canInstall ? "Instalar" : nil,
                action: install
            )
        }
    }

    private var footnote: some View {
        Text("El archivo original nunca se borra ni se modifica.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    // MARK: - Opciones de extracción

    private var options: some View {
        VStack(alignment: .leading, spacing: 11) {
            destinationRow
            subfolderRow
            passwordRow
            policyRow
            revealRow
        }
    }

    private var destinationRow: some View {
        SettingRow(label: "Guardar en") {
            HStack(spacing: 8) {
                Text(destinationText)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if model.chosenDestination != nil {
                    Button("Automático", action: model.useSuggestedDestination)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                QuietButton(title: "Cambiar", action: model.selectDestination)
            }
        }
    }

    private var subfolderRow: some View {
        SettingRow(label: "Carpeta propia", hint: "Con el nombre del comprimido") {
            Toggle("", isOn: $model.extractIntoSubfolder)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var passwordRow: some View {
        SettingRow(label: "Contraseña", hint: "Solo si la pide") {
            SecureField("Ninguna", text: $model.archivePassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
    }

    private var policyRow: some View {
        SettingRow(label: "Si ya existe", hint: nil) {
            Picker("", selection: $model.overwritePolicy) {
                ForEach(OverwritePolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }

    private var revealRow: some View {
        SettingRow(label: "Al terminar", hint: "Abrir en el Finder") {
            Toggle("", isOn: $model.revealWhenDone)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var destinationText: String {
        guard let destination = model.effectiveDestination else { return "Sin destino" }
        return destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Vista previa del contenido

    @ViewBuilder
    private var contentsPreview: some View {
        if model.isInspecting {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Leyendo el contenido…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if !model.archiveContents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                contentsToggle
                if showsContents { contentsList }
            }
        }
    }

    private var contentsToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showsContents.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showsContents ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text("\(model.archiveContents.count) elementos dentro")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var contentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.archiveContents.prefix(300)), id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.archiveContents.count > 300 {
                    Text("…y \(model.archiveContents.count - 300) más")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(9)
        }
        .frame(maxHeight: 130)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }

}
