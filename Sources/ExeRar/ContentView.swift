import SwiftUI
import ExeRarCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runtimeStatus

                    HStack(alignment: .top, spacing: 16) {
                        exeCard
                        rarCard
                    }

                    if model.runtimeStatus.wineURL == nil {
                        notice(
                            icon: "info.circle.fill",
                            title: "Wine es necesario para los .exe",
                            message: "macOS no ejecuta .exe de forma nativa. Selecciona un runtime Wine para intentarlo."
                        )
                    }

                    if let error = model.lastError {
                        notice(
                            icon: "exclamationmark.triangle.fill",
                            title: "No se pudo completar la acción",
                            message: error,
                            isError: true
                        )
                    }

                    activityLog
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .frame(minWidth: 760, minHeight: 620)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("EXE & RAR")
                    .font(.title2.weight(.semibold))
                Text("Utilidad local para macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(model.activityMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Listo", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.regularMaterial)
    }

    private var runtimeStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Herramientas disponibles")
                .font(.headline)

            HStack(spacing: 10) {
                ToolStatusPill(
                    title: "Wine",
                    detail: model.runtimeStatus.wineURL?.lastPathComponent ?? "No detectado",
                    isAvailable: model.runtimeStatus.wineURL != nil
                )
                ToolStatusPill(
                    title: "Extractor RAR",
                    detail: model.runtimeStatus.archiveToolName ?? "No detectado",
                    isAvailable: model.runtimeStatus.archiveTool != nil
                )
                ToolStatusPill(
                    title: "Homebrew",
                    detail: model.runtimeStatus.homebrewURL == nil ? "No detectado" : "Disponible",
                    isAvailable: model.runtimeStatus.homebrewURL != nil
                )

                Spacer()

                if model.runtimeStatus.wineURL == nil {
                    Button("Buscar Wine", action: model.selectWine)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var exeCard: some View {
        ActionCard(
            icon: "rectangle.and.arrow.up.right",
            title: "Ejecutar .exe",
            subtitle: "Lanza un programa Windows usando Wine."
        ) {
            PathRow(
                label: "Archivo seleccionado",
                value: model.selectedExe,
                placeholder: "Todavía no has elegido un .exe"
            )

            HStack(spacing: 10) {
                Button("Elegir .exe", action: model.selectExe)
                    .buttonStyle(.bordered)

                Button {
                    model.runSelectedExe()
                } label: {
                    Label("Ejecutar", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canRunExe)
            }

            if model.runtimeStatus.wineURL == nil {
                Button("Buscar Wine", action: model.selectWine)
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    private var rarCard: some View {
        ActionCard(
            icon: "archivebox.fill",
            title: "Extraer .rar",
            subtitle: "Descomprime sin sobrescribir archivos existentes."
        ) {
            PathRow(
                label: "Archivo seleccionado",
                value: model.selectedArchive,
                placeholder: "Todavía no has elegido un .rar"
            )
            PathRow(
                label: "Carpeta de destino",
                value: model.extractionDestination,
                placeholder: "Elige dónde extraer el contenido"
            )

            HStack(spacing: 10) {
                Button("Elegir .rar", action: model.selectArchive)
                    .buttonStyle(.bordered)
                Button("Elegir destino", action: model.selectDestination)
                    .buttonStyle(.bordered)
            }

            Button {
                model.extractSelectedArchive()
            } label: {
                Label("Extraer", systemImage: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canExtractArchive)

            if model.runtimeStatus.archiveTool == nil, model.canPrepareTools {
                Button("Preparar herramientas", action: model.prepareTools)
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Actividad")
                    .font(.headline)
                Spacer()
                Text(model.activityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                if model.logLines.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Sin actividad todavía")
                            .font(.subheadline.weight(.semibold))
                        Text("Los resultados y errores aparecerán aquí.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .frame(minHeight: 130, maxHeight: 190)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15))
            }
        }
    }

    private func notice(
        icon: String,
        title: String,
        message: String,
        isError: Bool = false
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(isError ? .red : .blue)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isError ? Color.red : Color.blue).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

private struct ToolStatusPill: View {
    let title: String
    let detail: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isAvailable ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.secondary.opacity(0.14))
        }
    }
}

private struct ActionCard<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    init(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
            }

            Divider()
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.15))
        }
    }
}

private struct PathRow: View {
    let label: String
    let value: URL?
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value?.path ?? placeholder)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
    }
}
