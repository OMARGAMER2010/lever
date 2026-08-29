import SwiftUI
import LeverCore

/// Hoja que explica cómo conseguir algo que la app no puede traer dentro: Wine para los `.exe`,
/// un aparato Android para los `.apk`.
///
/// Es una sola hoja para los dos casos porque el problema es idéntico —no hay una respuesta
/// única buena, hay opciones con precios distintos— y la forma de resolverlo también: enseñar
/// las opciones reales con la orden lista para copiar. Duplicarla haría que las dos se
/// separasen a la primera corrección.
struct RuntimeHelpSheet: View {
    @ObservedObject var model: AppModel

    let title: String
    let body_: String
    let footnote: String
    let options: [WineOption]
    /// Acción secundaria opcional, para cuando el usuario ya tiene la herramienta y solo hay que
    /// señalarla. Wine la usa; Android no la necesita porque `adb` se busca solo.
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(body_)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Spacing.normal) {
                ForEach(options) { option in
                    row(for: option)
                }
            }

            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle) {
                        dismiss()
                        secondaryAction()
                    }
                }
                Spacer()
                Button(s[.close]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.page)
        .frame(width: 560)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.inline))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RuntimeHelpSheet {
    /// Las opciones de Wine, para los `.exe`.
    static func wine(model: AppModel) -> RuntimeHelpSheet {
        RuntimeHelpSheet(
            model: model,
            title: model.strings[.wineHelpTitle],
            body_: model.strings[.wineHelpBody],
            footnote: model.strings[.wineHelpFootnote],
            options: model.wineOptions,
            secondaryTitle: model.strings[.findWineOnMac],
            secondaryAction: { model.selectWine() }
        )
    }

    /// Las maneras de tener un aparato Android donde instalar un `.apk`.
    static func android(model: AppModel) -> RuntimeHelpSheet {
        RuntimeHelpSheet(
            model: model,
            title: model.strings[.androidHelpTitle],
            body_: model.strings[.androidHelpBody],
            footnote: model.strings[.androidHelpFootnote],
            options: model.androidOptions
        )
    }
}
