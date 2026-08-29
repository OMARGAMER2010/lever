import SwiftUI
import PalancaCore

/// Hoja que explica cómo conseguir Wine. No hay una única respuesta buena en un Mac con chip
/// Apple, así que se enseñan las opciones reales con la orden lista para copiar.
struct WineHelpSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            VStack(alignment: .leading, spacing: 5) {
                Text(s[.wineHelpTitle])
                    .font(.system(size: 16, weight: .semibold))
                Text(s[.wineHelpBody])
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Spacing.normal) {
                ForEach(model.wineOptions) { option in
                    row(for: option)
                }
            }

            Text(s[.wineHelpFootnote])
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(s[.findWineOnMac]) {
                    dismiss()
                    model.selectWine()
                }
                Spacer()
                Button(s[.close]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.page)
        .frame(width: 540)
    }

    private func row(for option: WineOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(option.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let command = option.command {
                    Button(s[.copyCommand]) { model.copyCommand(command) }
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
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.inline))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
