import SwiftUI
import ExeRarCore

/// Hoja que explica cómo conseguir Wine. No hay una única respuesta buena en un Mac con chip
/// Apple, así que se enseñan las opciones reales con la orden lista para copiar.
struct WineHelpSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            header

            VStack(spacing: 10) {
                ForEach(AppModel.wineOptions) { option in
                    row(for: option)
                }
            }

            Text("Wine no viene con macOS ni se puede incluir dentro de esta app: es un programa aparte, grande, que se instala una vez. Después la app lo encuentra sola.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Buscar Wine en el Mac") {
                    model.selectWine()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cerrar") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.page)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Cómo conseguir Wine")
                .font(.system(size: 17, weight: .semibold))
            Text("Copia una de estas órdenes y pégala en la Terminal. Cuando termine, vuelve aquí y pulsa «Volver a buscar herramientas».")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(for option: WineOption) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(option.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let command = option.command {
                    Button("Copiar orden") { model.copyCommand(command) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            Text(option.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command = option.command {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }
}
