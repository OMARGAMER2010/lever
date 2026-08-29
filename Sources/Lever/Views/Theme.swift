import SwiftUI
import LeverCore

/// Tokens visuales, con el motivo de cada uno.
///
/// Decisiones y por qué:
///
/// - **El acento es el del sistema, no uno propio.** La versión anterior usaba un degradado
///   índigo→violeta. Ese degradado no salía de nada: ni del dominio, ni de una marca, ni de una
///   necesidad de jerarquía. Era el color por defecto con el que sale casi cualquier interfaz
///   generada. `Color.accentColor` toma el que el usuario eligió en Ajustes del Sistema: es una
///   decisión que solo tiene sentido en macOS y que ninguna plantilla puede llevarse puesta.
/// - **Sin degradados.** Ninguno resolvía un problema de legibilidad o de jerarquía.
/// - **Los colores son semánticos.** Verde = herramienta encontrada. Ámbar = falta algo pero se
///   puede seguir. Rojo = ha fallado. Ninguno decora.
/// - **Los radios van por función**, no uno grande para todo: 5 para controles en línea, 9 para
///   paneles. Un radio único hace que todo pese lo mismo.
/// - **Superficies opacas.** El material translúcido se reserva para las barras del sistema
///   (arriba y abajo), donde comunica que algo se desliza por debajo. En los paneles de contenido
///   solo restaba contraste al texto.
enum Theme {
    /// Herramienta presente y utilizable.
    static let ready = Color(nsColor: .systemGreen)
    /// Falta algo, pero hay camino: instalar, desbloquear, elegir otro.
    static let attention = Color(nsColor: .systemOrange)
    /// Ha fallado.
    static let failure = Color(nsColor: .systemRed)

    /// Fondo de los paneles de contenido.
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let pageBackground = Color(nsColor: .underPageBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    enum Radius {
        /// Controles en línea: fichas, campos, celdas.
        static let inline: CGFloat = 5
        /// Paneles y zonas.
        static let panel: CGFloat = 9
    }

    enum Spacing {
        static let tight: CGFloat = 8
        static let normal: CGFloat = 14
        static let loose: CGFloat = 20
        static let page: CGFloat = 24
    }

    /// Ancho máximo de la columna de contenido. Más allá, las filas de ajustes se separan
    /// tanto de su etiqueta que cuesta emparejarlas.
    static let contentWidth: CGFloat = 680
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .info: return .secondary
        case .success: return Theme.ready
        case .warning: return Theme.attention
        case .failure: return Theme.failure
        case .output: return .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .info: return nil
        case .success: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.octagon"
        case .output: return nil
        }
    }
}

/// Panel de contenido: fondo opaco, borde de un pelo, sin sombra ni desenfoque.
struct Panel<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.loose
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.hairline)
            }
    }
}
