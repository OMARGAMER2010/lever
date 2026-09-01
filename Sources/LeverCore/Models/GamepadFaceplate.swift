import CoreGraphics
import Foundation

/// Dónde cae cada control en el dibujo del mando, en proporción de su ancho y de su alto.
///
/// **Por qué el dibujo tiene la forma del mando conectado y no la de un esquema.** Nadie recuerda
/// qué es «el botón B» de una consola que no ha tenido nunca, pero todo el mundo reconoce el botón
/// de abajo del rombo **en el mando que tiene en la mano**. Si el dibujo se parece al aparato, la
/// asignación se lee sin pensar; si es un esquema abstracto, hay que traducir dos veces.
///
/// Las posiciones van aquí y no en la vista porque son datos: se pueden comprobar —que no haya dos
/// controles en el mismo sitio, que ninguno se salga del dibujo— sin abrir una ventana.
public enum GamepadFaceplate {
    /// Las dos disposiciones que existen de verdad. No es una preferencia estética: en un mando de
    /// Xbox la palanca izquierda está **donde un PlayStation tiene la cruceta**, y dibujarlas
    /// iguales sería mandar al usuario a buscar un botón donde no está.
    public enum Style: String, Sendable, CaseIterable {
        case sony
        case xbox
    }

    /// El RetroPad tiene forma de mando de PlayStation, así que sin mando conectado se dibuja ese:
    /// es el que describe lo que se está configurando.
    public static func style(for family: ConnectedGamepad.Family?) -> Style {
        family == .xbox ? .xbox : .sony
    }

    public static func spot(of input: RetroPadInput, style: Style) -> CGPoint {
        switch style {
        case .sony: return sony(input)
        case .xbox: return xbox(input)
        }
    }

    // MARK: - Las dos disposiciones

    private static func sony(_ input: RetroPadInput) -> CGPoint {
        switch input {
        // Los gatillos asoman por encima del lomo, como en el mando de verdad: el L2 detrás del L1.
        case .l2: return CGPoint(x: 0.205, y: 0.015)
        case .l: return CGPoint(x: 0.205, y: 0.095)
        case .r2: return CGPoint(x: 0.795, y: 0.015)
        case .r: return CGPoint(x: 0.795, y: 0.095)

        // Los dos de en medio van **al lado** del panel táctil, no encima: ahí es donde están.
        case .select: return CGPoint(x: 0.345, y: 0.175)
        case .start: return CGPoint(x: 0.655, y: 0.175)

        case .up: return CGPoint(x: 0.245, y: 0.215)
        case .left: return CGPoint(x: 0.170, y: 0.315)
        case .right: return CGPoint(x: 0.320, y: 0.315)
        case .down: return CGPoint(x: 0.245, y: 0.415)

        // El rombo, con los nombres que lleva serigrafiados el mando conectado.
        case .x: return CGPoint(x: 0.755, y: 0.215)
        case .y: return CGPoint(x: 0.680, y: 0.315)
        case .a: return CGPoint(x: 0.830, y: 0.315)
        case .b: return CGPoint(x: 0.755, y: 0.415)

        // Las dos palancas, simétricas y abajo. Pulsar la palanca es su centro.
        case .l3: return CGPoint(x: 0.375, y: 0.525)
        case .leftStickUp: return CGPoint(x: 0.375, y: 0.437)
        case .leftStickDown: return CGPoint(x: 0.375, y: 0.613)
        case .leftStickLeft: return CGPoint(x: 0.310, y: 0.525)
        case .leftStickRight: return CGPoint(x: 0.440, y: 0.525)

        case .r3: return CGPoint(x: 0.625, y: 0.525)
        case .rightStickUp: return CGPoint(x: 0.625, y: 0.437)
        case .rightStickDown: return CGPoint(x: 0.625, y: 0.613)
        case .rightStickLeft: return CGPoint(x: 0.560, y: 0.525)
        case .rightStickRight: return CGPoint(x: 0.690, y: 0.525)
        }
    }

    private static func xbox(_ input: RetroPadInput) -> CGPoint {
        switch input {
        case .l2: return CGPoint(x: 0.205, y: 0.015)
        case .l: return CGPoint(x: 0.205, y: 0.095)
        case .r2: return CGPoint(x: 0.795, y: 0.015)
        case .r: return CGPoint(x: 0.795, y: 0.095)

        case .select: return CGPoint(x: 0.420, y: 0.215)
        case .start: return CGPoint(x: 0.580, y: 0.215)

        // Aquí está la diferencia que obliga a tener dos dibujos: arriba a la izquierda va la
        // palanca, en el sitio donde un mando de PlayStation tiene la cruceta.
        case .l3: return CGPoint(x: 0.245, y: 0.265)
        case .leftStickUp: return CGPoint(x: 0.245, y: 0.177)
        case .leftStickDown: return CGPoint(x: 0.245, y: 0.353)
        case .leftStickLeft: return CGPoint(x: 0.180, y: 0.265)
        case .leftStickRight: return CGPoint(x: 0.310, y: 0.265)

        // Y la cruceta baja al hueco que deja la palanca.
        case .up: return CGPoint(x: 0.380, y: 0.455)
        case .left: return CGPoint(x: 0.315, y: 0.555)
        case .right: return CGPoint(x: 0.445, y: 0.555)
        case .down: return CGPoint(x: 0.380, y: 0.655)

        // El rombo no se mueve: es la referencia de todo el dibujo.
        case .x: return CGPoint(x: 0.755, y: 0.215)
        case .y: return CGPoint(x: 0.680, y: 0.315)
        case .a: return CGPoint(x: 0.830, y: 0.315)
        case .b: return CGPoint(x: 0.755, y: 0.415)

        case .r3: return CGPoint(x: 0.625, y: 0.525)
        case .rightStickUp: return CGPoint(x: 0.625, y: 0.437)
        case .rightStickDown: return CGPoint(x: 0.625, y: 0.613)
        case .rightStickLeft: return CGPoint(x: 0.560, y: 0.525)
        case .rightStickRight: return CGPoint(x: 0.690, y: 0.525)
        }
    }
}
