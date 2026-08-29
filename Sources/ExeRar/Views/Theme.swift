import SwiftUI
import ExeRarCore

/// Paleta e ingredientes visuales compartidos. Un único sitio donde cambiar el aspecto.
enum Theme {
    static let indigo = Color(red: 0.29, green: 0.30, blue: 0.88)
    static let violet = Color(red: 0.55, green: 0.31, blue: 0.91)
    static let amber = Color(red: 0.95, green: 0.63, blue: 0.19)
    static let mint = Color(red: 0.20, green: 0.74, blue: 0.51)
    static let coral = Color(red: 0.93, green: 0.35, blue: 0.36)

    static let brand = LinearGradient(
        colors: [indigo, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Radios de esquina, de menor a mayor jerarquía.
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 18
    }

    enum Spacing {
        static let tight: CGFloat = 8
        static let normal: CGFloat = 14
        static let loose: CGFloat = 22
        static let page: CGFloat = 26
    }
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .info: return .secondary
        case .success: return Theme.mint
        case .warning: return Theme.amber
        case .failure: return Theme.coral
        case .output: return .secondary.opacity(0.85)
        }
    }

    var symbol: String? {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .output: return nil
        }
    }
}

/// Tarjeta estándar: material translúcido, borde sutil y esquinas suaves.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.loose
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }
}

/// Botón principal de cada pantalla. Grande, con degradado de marca.
struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    var isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.brand)
                    .opacity(isEnabled ? (isHovering ? 0.92 : 1) : 0.35)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(.white.opacity(isEnabled ? 0.18 : 0))
            }
            .shadow(
                color: Theme.indigo.opacity(isEnabled ? 0.28 : 0),
                radius: isHovering ? 14 : 9,
                y: isHovering ? 5 : 3
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .animation(.easeOut(duration: 0.16), value: isEnabled)
    }
}

/// Botón secundario discreto, con icono.
struct QuietButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
