import SwiftUI
import UniformTypeIdentifiers
import ExeRarCore

/// Zona grande para soltar archivos. Es la acción principal de cada pestaña.
struct DropZone: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accept: ([URL]) -> Void
    let browse: () -> Void

    @State private var isTargeted = false
    @State private var isHovering = false

    var body: some View {
        Button(action: browse) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.brand)
                        .opacity(isTargeted ? 0.28 : 0.14)
                        .frame(width: 62, height: 62)
                    Image(systemName: systemImage)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
                .scaleEffect(isTargeted ? 1.08 : 1)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.indigo.opacity(isTargeted ? 0.10 : (isHovering ? 0.05 : 0.025)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(
                        Theme.indigo.opacity(isTargeted ? 0.75 : 0.28),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5])
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isTargeted)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers, into: accept)
        }
    }

    /// Extrae las rutas de lo que se ha soltado y las entrega en el hilo principal.
    static func load(_ providers: [NSItemProvider], into accept: @escaping ([URL]) -> Void) -> Bool {
        let collected = URLCollector(expected: providers.count, accept: accept)
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                collected.add(url)
            }
        }
        return handled
    }

    private func load(_ providers: [NSItemProvider], into accept: @escaping ([URL]) -> Void) -> Bool {
        Self.load(providers, into: accept)
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

/// Ficha del archivo elegido: icono real del Finder, nombre, tamaño y botón para quitarlo.
struct SelectedFileChip: View {
    let url: URL
    let tint: Color
    var onReveal: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let size = url.formattedFileSize {
                        Text(size)
                    }
                    Text(url.deletingLastPathComponent().path)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onReveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Mostrar en el Finder")

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Quitar")
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(tint.opacity(0.22))
        }
    }
}

/// Fila de ajuste: etiqueta a la izquierda, control a la derecha.
struct SettingRow<Control: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 156, alignment: .leading)

            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Indicador compacto del estado de una herramienta, para la barra superior.
struct ToolChip: View {
    let title: String
    let detail: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isAvailable ? Theme.mint : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(isAvailable ? "\(title): \(detail)" : "\(title) no está disponible")
    }
}

/// Aviso destacado con icono, título y explicación. Sirve para errores y para consejos.
struct NoticeBanner: View {
    enum Kind {
        case info, warning, failure

        var tint: Color {
            switch self {
            case .info: return Theme.indigo
            case .warning: return Theme.amber
            case .failure: return Theme.coral
            }
        }

        var symbol: String {
            switch self {
            case .info: return "lightbulb.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "exclamationmark.octagon.fill"
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(kind.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.22))
        }
    }
}

/// El interruptor de las dos secciones de la app.
struct ModeSwitcher: View {
    @Binding var mode: WorkMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WorkMode.allCases) { candidate in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { mode = candidate }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(candidate.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .foregroundStyle(mode == candidate ? Color.white : Color.primary.opacity(0.75))
                    .background {
                        if mode == candidate {
                            Capsule().fill(Theme.brand)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

enum WorkMode: String, CaseIterable, Identifiable {
    case program
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .program: return "Programas"
        case .archive: return "Comprimidos"
        }
    }

    var symbol: String {
        switch self {
        case .program: return "play.rectangle.fill"
        case .archive: return "archivebox.fill"
        }
    }
}
