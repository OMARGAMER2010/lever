import SwiftUI
import UniformTypeIdentifiers
import LeverCore

/// Zona para soltar archivos.
///
/// El borde discontinuo se queda porque es la convención que dice «suéltalo aquí». Lo que se ha
/// quitado es el círculo con degradado que envolvía el icono: no aportaba área de pulsación ni
/// jerarquía, solo peso visual.
struct DropZone: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accept: ([URL]) -> Void
    let browse: () -> Void

    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: browse) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, Theme.Spacing.loose)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .fill(isTargeted ? Color.accentColor.opacity(0.07) : Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Theme.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Self.load(providers, into: accept)
        }
    }

    /// Extrae las rutas de lo que se ha soltado y las entrega en el hilo principal.
    static func load(_ providers: [NSItemProvider], into accept: @escaping ([URL]) -> Void) -> Bool {
        let collected = URLCollector(expected: providers.count, accept: accept)
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in collected.add(url) }
        }
        return handled
    }
}

/// Junta las rutas que llegan de forma asíncrona y las entrega una sola vez.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let accept: ([URL]) -> Void

    init(expected: Int, accept: @escaping ([URL]) -> Void) {
        self.remaining = expected
        self.accept = accept
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let done = remaining <= 0
        let payload = urls
        lock.unlock()

        guard done, !payload.isEmpty else { return }
        DispatchQueue.main.async { [accept] in accept(payload) }
    }
}

/// Ficha del archivo elegido. Debajo del nombre van los datos que la app ha averiguado leyendo
/// el archivo: no adornos, sino lo que hace falta para decidir si esto va a funcionar.
struct SelectedFileChip: View {
    let url: URL
    let facts: [String]
    let revealLabel: String
    let removeLabel: String
    var onReveal: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.tight)

            Button(action: onReveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(revealLabel)
            .accessibilityLabel(revealLabel)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.inline))
    }
}

/// Fila de ajuste: etiqueta a la izquierda, control a la derecha.
struct SettingRow<Control: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 150, alignment: .leading)

            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Estado de una herramienta: un punto y su nombre. Sin cápsula.
///
/// El detalle —la ruta o la versión— solo se escribe cuando la herramienta **falta**, que es
/// cuando importa. Con ella puesta, el nombre y el punto verde bastan, y la ruta exacta está en
/// la pestaña que la usa. Así los tres indicadores caben juntos en una fila.
///
/// El punto nunca es el único portador: siempre va acompañado del nombre, y VoiceOver lee
/// además el estado completo.
struct ToolStatus: View {
    let title: String
    let detail: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isAvailable ? Theme.ready : Theme.attention)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isAvailable ? .secondary : .primary)
            if !isAvailable {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.attention)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }
}

/// Aviso con una regla de color a la izquierda. Sustituye al bloque redondeado teñido, que
/// llenaba de superficies una pantalla que ya tenía paneles.
struct NoticeBanner: View {
    enum Kind {
        /// Ni problema ni aviso: algo que hay que contar porque no se ve mirando el archivo,
        /// como que un `.xapk` trae la app partida en trozos. En naranja parecería un fallo.
        case info
        case warning, failure

        var tint: Color {
            switch self {
            case .info: return Theme.hairline
            case .warning: return Theme.attention
            case .failure: return Theme.failure
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.normal) {
            Rectangle()
                .fill(kind.tint)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            Spacer(minLength: Theme.Spacing.tight)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.regular)
                    .padding(.top, 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

/// Selector de idioma: bandera y nombre. La bandera es el identificador que pidió el usuario;
/// el nombre en su propio idioma evita que se confunda país con lengua.
struct LanguagePicker: View {
    @Binding var language: Language
    let label: String

    var body: some View {
        Menu {
            Picker(label, selection: $language) {
                ForEach(Language.allCases) { candidate in
                    Text("\(candidate.flag)  \(candidate.nativeName)").tag(candidate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(language.flag)
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(label)
        .accessibilityLabel("\(label): \(language.nativeName)")
    }
}

enum WorkMode: String, CaseIterable, Identifiable {
    case program
    case archive
    case android
    case rom

    var id: String { rawValue }

    var textKey: TextKey {
        switch self {
        case .program: return .tabPrograms
        case .archive: return .tabArchives
        case .android: return .tabAndroid
        case .rom: return .tabEmulation
        }
    }

    /// A qué pestaña lleva un archivo soltado en cualquier parte de la ventana.
    ///
    /// La decisión no se toma aquí: la toma `FileRouter`, el mismo que usa el modelo para decidir
    /// a quién entregarle el archivo. Antes había dos listas y esta se había quedado corta —solo
    /// preguntaba por ROMs—, así que un `.xci` entraba en la pestaña de consolas y la ventana
    /// enseñaba la de comprimidos.
    ///
    /// Lo que no cabe en ninguna parte cae en comprimidos, que es donde el usuario ve el error.
    static func forDroppedFile(_ url: URL) -> WorkMode {
        switch FileRouter.route(for: url) {
        case .program: return .program
        case .android: return .android
        case .rom: return .rom
        case .archive, nil: return .archive
        }
    }
}
