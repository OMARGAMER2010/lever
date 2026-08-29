import SwiftUI
import ExeRarCore

/// Barra fija sobre el registro de actividad. La acción principal nunca se pierde al hacer scroll.
struct ActionBar: View {
    @ObservedObject var model: AppModel
    let mode: WorkMode

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            status
            Spacer(minLength: Theme.Spacing.normal)
            controls
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Lado izquierdo: qué está pasando

    @ViewBuilder
    private var status: some View {
        switch mode {
        case .archive:
            archiveStatus
        case .program:
            programStatus
        }
    }

    @ViewBuilder
    private var archiveStatus: some View {
        if model.isExtracting {
            VStack(alignment: .leading, spacing: 4) {
                if let progress = model.extractionProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text("Extrayendo… \(Int(progress * 100)) %")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text("Extrayendo…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else if let folder = model.lastSuccessFolder {
            Button(action: model.revealResult) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.mint)
                    Text("Listo · abrir «\(folder.lastPathComponent)»")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
        } else if model.selectedArchive == nil {
            hint("Elige un comprimido para empezar")
        } else if model.runtimeStatus.archiveTool == nil {
            hint("Falta un extractor: instálalo desde el aviso de arriba")
        } else {
            hint("Todo listo para extraer")
        }
    }

    @ViewBuilder
    private var programStatus: some View {
        if model.isPreparingWindows {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparando Windows por primera vez…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if model.isRunningProgram {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("El programa está abierto")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if model.selectedProgram == nil {
            hint("Elige un programa .exe o .msi")
        } else if model.wineIsBlocked {
            hint("Wine está bloqueado por macOS: desbloquéalo arriba")
        } else if model.runtimeStatus.wineURL == nil {
            hint("Falta Wine")
        } else {
            hint("Todo listo para ejecutar")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Lado derecho: los botones

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Theme.Spacing.tight) {
            switch mode {
            case .archive:
                if model.isExtracting {
                    QuietButton(title: "Detener", systemImage: "stop.fill", action: model.stopExtraction)
                }
                PrimaryActionButton(
                    title: model.isExtracting ? "Extrayendo…" : "Extraer",
                    systemImage: "arrow.down.to.line",
                    isEnabled: model.canExtractArchive,
                    action: model.extractArchive
                )
                .frame(width: 176)

            case .program:
                if model.isRunningProgram || model.isPreparingWindows {
                    QuietButton(title: "Detener", systemImage: "stop.fill", action: model.stopProgram)
                }
                PrimaryActionButton(
                    title: model.isRunningProgram || model.isPreparingWindows ? "En marcha…" : "Ejecutar",
                    systemImage: "play.fill",
                    isEnabled: model.canRunProgram,
                    action: model.runProgram
                )
                .frame(width: 176)
            }
        }
    }
}
