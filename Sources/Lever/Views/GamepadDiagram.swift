import SwiftUI
import LeverCore

/// El dibujo del mando: la silueta del que está conectado, con cada botón en su sitio y una línea
/// que lo une a lo que tiene asignado.
///
/// **Por qué se dibuja el mando y no una rejilla de casillas.** El problema de asignar controles es
/// espacial, no de lista: nadie recuerda qué es «el botón B» de una consola que no ha tenido nunca,
/// pero todo el mundo reconoce el botón de abajo del rombo en el mando que tiene en la mano. Si el
/// dibujo se parece al aparato de verdad —su forma, sus nombres, sus palancas donde están— la
/// asignación se lee sin traducir nada.
///
/// Y por eso la silueta cambia con el mando conectado: en uno de Xbox la palanca izquierda está
/// **donde un PlayStation tiene la cruceta**, y dibujarlas iguales sería mandar a buscar un botón
/// donde no está.
struct GamepadDiagram: View {
    let family: ConnectedGamepad.Family?
    /// Los que la consola emulada tiene de verdad. Enseñar dieciséis para una Game Boy sería
    /// enseñar catorce casillas que no hacen nada.
    let inputs: [RetroPadInput]
    let profile: ControlProfile
    let listening: RetroPadInput?
    let strings: Strings
    let onPick: (RetroPadInput) -> Void

    private var style: GamepadFaceplate.Style { GamepadFaceplate.style(for: family) }

    /// Ancho de una columna de etiquetas y hueco que se le deja al mando. El mando se lleva lo que
    /// sobra, hasta un tope: más grande que esto no cabe con las etiquetas al lado.
    private static let labelWidth: CGFloat = 132
    private static let labelGap: CGFloat = 18
    private static let maxPadWidth: CGFloat = 420
    private static let padAspect: CGFloat = 0.76
    /// Lo que ocupa una etiqueta de alto. Es lo que decide cuánto hay que separarlas cuando dos
    /// botones caen a la misma altura.
    private static let labelPitch: CGFloat = 40

    var body: some View {
        GeometryReader { geometría in
            let marco = geometría.size
            let anchoMando = min(marco.width - 2 * (Self.labelWidth + Self.labelGap),
                                 Self.maxPadWidth)
            let tamaño = CGSize(width: anchoMando, height: anchoMando * Self.padAspect)
            let origen = CGPoint(x: (marco.width - tamaño.width) / 2,
                                 y: (marco.height - tamaño.height) / 2)
            let colocados = layout(in: marco, padOrigin: origen, padSize: tamaño)

            ZStack {
                silhouette(origin: origen, size: tamaño)

                // Las líneas van debajo de todo para que no crucen por encima de ningún texto.
                ForEach(colocados.filter { !$0.inline }) { colocado in
                    leader(from: colocado.labelAnchor, to: colocado.spot)
                }

                ForEach(colocados) { colocado in
                    marker(colocado)
                    label(colocado)
                }
            }
        }
    }

    // MARK: - Repartir las etiquetas

    /// Un control ya situado: dónde cae en el mando y dónde va su etiqueta.
    private struct Placed: Identifiable {
        let input: RetroPadInput
        let spot: CGPoint
        let labelCenter: CGPoint
        let labelAnchor: CGPoint
        let onLeft: Bool
        /// Con la etiqueta pegada al botón y sin línea. Ver `usesColumn`.
        let inline: Bool
        var id: RetroPadInput { input }
    }

    /// Si ese control merece etiqueta en la columna del lado o pegada al botón.
    ///
    /// Los dos de en medio y arriba —Create y Options en un DualSense— caen casi en el centro del
    /// dibujo, así que su línea hasta la columna **cruzaría por encima de la cruceta entera**. Una
    /// línea que tapa media docena de botones estorba más de lo que explica: esos van con el
    /// nombre pegado encima y sin línea.
    private static func usesColumn(_ spot: CGPoint) -> Bool {
        !(spot.x > 0.33 && spot.x < 0.67 && spot.y < 0.30)
    }

    /// Cada etiqueta se pone **a la altura de su botón** y en el lado del mando que le pilla más
    /// cerca. Dos cosas que parecen detalles y no lo son:
    ///
    /// - El lado se decide por dónde cae el botón. Si un botón de la izquierda tuviera su etiqueta
    ///   a la derecha, su línea cruzaría el mando entero por encima de todos los demás.
    /// - La altura se respeta, y solo se separan las que chocarían. Repartirlas a intervalos
    ///   iguales queda ordenado pero alarga las líneas y rompe la relación de un vistazo, que es
    ///   justo lo que el dibujo tiene que dar.
    private func layout(in frame: CGSize, padOrigin: CGPoint, padSize: CGSize) -> [Placed] {
        var resultado: [Placed] = []

        func enElDibujo(_ punto: CGPoint) -> CGPoint {
            CGPoint(x: padOrigin.x + punto.x * padSize.width,
                    y: padOrigin.y + punto.y * padSize.height)
        }

        for control in inputs {
            let punto = GamepadFaceplate.spot(of: control, style: style)
            guard !Self.usesColumn(punto) else { continue }
            let sitio = enElDibujo(punto)
            resultado.append(Placed(
                input: control,
                spot: sitio,
                labelCenter: CGPoint(x: sitio.x, y: sitio.y - 26),
                labelAnchor: sitio,
                onLeft: punto.x < 0.5,
                inline: true
            ))
        }

        for izquierda in [true, false] {
            let delLado = inputs
                .map { ($0, GamepadFaceplate.spot(of: $0, style: style)) }
                .filter { Self.usesColumn($0.1) && ($0.1.x < 0.5) == izquierda }
                .sorted { primero, segundo in
                    if primero.1.y != segundo.1.y { return primero.1.y < segundo.1.y }
                    // A la misma altura va arriba el más lejano a la columna: así su línea pasa
                    // por encima de la del cercano en vez de cruzarla a media altura.
                    let lejaníaPrimero = izquierda ? primero.1.x : -primero.1.x
                    let lejaníaSegundo = izquierda ? segundo.1.x : -segundo.1.x
                    return lejaníaPrimero > lejaníaSegundo
                }
            guard !delLado.isEmpty else { continue }

            var alturas = delLado.map { padOrigin.y + $0.1.y * padSize.height }
            separate(&alturas, within: frame.height)

            for (fila, (input, punto)) in delLado.enumerated() {
                let bordeInterior = izquierda
                    ? Self.labelWidth
                    : frame.width - Self.labelWidth
                resultado.append(Placed(
                    input: input,
                    spot: enElDibujo(punto),
                    labelCenter: CGPoint(
                        x: izquierda ? Self.labelWidth / 2 : frame.width - Self.labelWidth / 2,
                        y: alturas[fila]
                    ),
                    labelAnchor: CGPoint(x: bordeInterior, y: alturas[fila]),
                    onLeft: izquierda,
                    inline: false
                ))
            }
        }
        return resultado
    }

    /// Separa las que se pisan sin perder el orden: una pasada hacia abajo empujando y otra hacia
    /// arriba para que la última no se salga por el pie del dibujo.
    private func separate(_ alturas: inout [CGFloat], within height: CGFloat) {
        let paso = Self.labelPitch
        for índice in alturas.indices.dropFirst() {
            alturas[índice] = max(alturas[índice], alturas[índice - 1] + paso)
        }
        alturas[alturas.count - 1] = min(alturas[alturas.count - 1], height - paso / 2)
        for índice in alturas.indices.dropLast().reversed() {
            alturas[índice] = min(alturas[índice], alturas[índice + 1] - paso)
        }
        alturas[0] = max(alturas[0], paso / 2)
    }

    // MARK: - Las piezas del dibujo

    /// La línea que une la etiqueta con su botón. Sale horizontal de la etiqueta y llega curvada al
    /// botón: recta pasaría por encima de los demás.
    private func leader(from anchor: CGPoint, to spot: CGPoint) -> some View {
        Path { trazo in
            trazo.move(to: anchor)
            trazo.addQuadCurve(to: spot, control: CGPoint(x: (anchor.x + spot.x) / 2, y: anchor.y))
        }
        .stroke(Color.secondary.opacity(0.28), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    /// El botón, con la forma que tiene en el mando: el rombo redondo, la cruceta cuadrada y los
    /// gatillos en pastilla.
    private func marker(_ colocado: Placed) -> some View {
        let escuchando = listening == colocado.input
        let esCruceta = [.up, .down, .left, .right].contains(colocado.input)
        let esHombro = [.l, .r, .l2, .r2].contains(colocado.input)
        let esMenú = [.start, .select].contains(colocado.input)
        let ancho: CGFloat = esHombro ? 32 : (esMenú ? 20 : (esCruceta ? 21 : 25))
        let alto: CGFloat = esHombro ? 16 : (esMenú ? 16 : (esCruceta ? 21 : 25))
        let radio: CGFloat = esCruceta ? 3 : (esHombro || esMenú ? 5 : alto / 2)

        return Button { onPick(colocado.input) } label: {
            Text(padGlyph(colocado.input))
                .font(.system(size: esHombro || esMenú ? 10 : 12, weight: .semibold))
                .foregroundStyle(escuchando ? Color.white : .primary)
                .frame(width: ancho, height: alto)
                .background {
                    let forma = RoundedRectangle(cornerRadius: radio)
                    forma.fill(escuchando ? Color.accentColor : Theme.surface)
                    forma.strokeBorder(escuchando ? Color.accentColor : Theme.hairline,
                                       lineWidth: escuchando ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(colocado.spot)
        .help(escuchando ? strings[.controlsListening]
                         : strings(.controlsPressPrompt, name(colocado.input)))
    }

    /// La etiqueta: cómo se llama ese botón en este mando y qué tiene asignado. Se puede pulsar
    /// igual que el botón del dibujo, que es el doble de sitio para acertar.
    private func label(_ colocado: Placed) -> some View {
        let escuchando = listening == colocado.input
        let tecla = profile.binding(for: colocado.input)
        let mando = profile.gamepadBinding(for: colocado.input)

        return Button { onPick(colocado.input) } label: {
            VStack(alignment: colocado.inline ? .center
                              : (colocado.onLeft ? .trailing : .leading), spacing: 0) {
                Text(name(colocado.input))
                    .font(.system(size: 11, weight: .semibold))
                if escuchando {
                    Text(strings[.controlsListening])
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                } else {
                    HStack(spacing: 5) {
                        Text(tecla.label(strings))
                            .foregroundStyle(tecla.isAssigned ? Color.secondary : Theme.attention)
                        if mando.isAssigned {
                            Text(mando.label(strings)).foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: colocado.inline, vertical: false)
            .frame(width: colocado.inline ? nil : Self.labelWidth - 12,
                   alignment: colocado.inline ? .center : (colocado.onLeft ? .trailing : .leading))
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                escuchando ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.inline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(colocado.labelCenter)
        .accessibilityLabel("\(name(colocado.input)): \(tecla.label(strings)), \(mando.label(strings))")
    }

    /// El cuerpo del mando y lo que no se asigna: el panel táctil y el hueco de las dos palancas.
    /// No es adorno: es lo que hace que la silueta se reconozca antes de leer nada.
    private func silhouette(origin: CGPoint, size: CGSize) -> some View {
        let marco = CGRect(origin: origin, size: size)
        return ZStack {
            // **Rellena y sin contorno.** El cuerpo son tres piezas que se solapan —el lomo y los
            // dos mangos— y rellenas se funden en una sola silueta. Con contorno se verían las
            // costuras de dentro, que es lo que delata un dibujo hecho a trozos.
            ZStack {
                GamepadBody(style: style).fill(Color.primary.opacity(0.04))
                GamepadBody(style: style).stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
            .frame(width: size.width, height: size.height)
            .position(x: marco.midX, y: marco.midY)

            // El panel táctil, que es lo que hace que un DualSense se reconozca de un vistazo.
            if style == .sony {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
                    .frame(width: size.width * 0.19, height: size.height * 0.150)
                    .position(x: marco.midX, y: marco.minY + size.height * 0.310)
            }

            // Los botones que este mando tiene pero **esta consola no usa**, apagados y sin poder
            // pulsarse. Sin ellos el mando sale medio vacío y cuesta situarse: para una NES se
            // verían dos botones sueltos flotando donde el usuario espera cuatro. Apagados dicen
            // las dos cosas a la vez: dónde está cada uno y cuáles no hacen nada aquí.
            ForEach(RetroPadInput.onDiagram.filter { !inputs.contains($0) }, id: \.self) { control in
                let punto = GamepadFaceplate.spot(of: control, style: style)
                Text(padGlyph(control))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .background {
                        Circle().strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 1)
                    }
                    .position(x: marco.minX + punto.x * size.width,
                              y: marco.minY + punto.y * size.height)
            }

            // Por posición y no por el punto: `CGPoint` no es identificable hasta macOS 15 y la
            // app llega hasta la 13.
            ForEach(Array(sticks.enumerated()), id: \.offset) { _, centro in
                Circle()
                    .strokeBorder(Theme.hairline, lineWidth: 1)
                    .frame(width: size.width * 0.145, height: size.width * 0.145)
                    .position(x: marco.minX + centro.x * size.width,
                              y: marco.minY + centro.y * size.height)
            }
        }
    }

    /// Dónde van los círculos de las palancas. Se sacan de la posición de `l3` y `r3`, que es
    /// justo el centro de cada una: si algún día se mueve una, el círculo se mueve con ella.
    private var sticks: [CGPoint] {
        [GamepadFaceplate.spot(of: .l3, style: style), GamepadFaceplate.spot(of: .r3, style: style)]
    }

    // MARK: - Los nombres

    /// Lo que va escrito **dentro** del botón: corto, porque el sitio es el de una moneda.
    private func padGlyph(_ input: RetroPadInput) -> String {
        shortGlyph(input, family ?? .generic)
    }

    private func shortGlyph(_ input: RetroPadInput, _ family: ConnectedGamepad.Family) -> String {
        switch input {
        case .a: return family.faceLabels.a
        case .b: return family.faceLabels.b
        case .x: return family.faceLabels.x
        case .y: return family.faceLabels.y
        case .l: return family.shoulderLabels.l
        case .r: return family.shoulderLabels.r
        case .l2: return family.shoulderLabels.l2
        case .r2: return family.shoulderLabels.r2
        case .l3: return family.stickLabels.left
        case .r3: return family.stickLabels.right
        // «Options» y «Create» no caben en un botón de veinte puntos, y son los dos únicos cuyo
        // nombre no es una letra. Dentro va el icono; el nombre entero, en la etiqueta.
        case .start: return "≡"
        case .select: return "⧉"
        default: return input.symbol
        }
    }

    /// Cómo se llama de verdad ese botón en este mando. Es lo que va en la etiqueta y lo que quita
    /// la adivinanza: en un DualSense no pone «Select» por ninguna parte.
    private func name(_ input: RetroPadInput) -> String {
        let family = family ?? .generic
        switch input {
        case .start: return family.menuLabels.start
        case .select: return family.menuLabels.select
        case .leftStickUp: return "\(family.stickLabels.left) ↑"
        case .leftStickDown: return "\(family.stickLabels.left) ↓"
        case .leftStickLeft: return "\(family.stickLabels.left) ←"
        case .leftStickRight: return "\(family.stickLabels.left) →"
        case .rightStickUp: return "\(family.stickLabels.right) ↑"
        case .rightStickDown: return "\(family.stickLabels.right) ↓"
        case .rightStickLeft: return "\(family.stickLabels.right) ←"
        case .rightStickRight: return "\(family.stickLabels.right) →"
        default: return shortGlyph(input, family)
        }
    }
}

/// La silueta del cuerpo del mando: el lomo, los dos mangos y las pestañas de los gatillos.
///
/// Va dibujada y no puesta como imagen porque tiene que seguir el tamaño de la ventana sin
/// pixelarse y cambiar de color con el tema del sistema, y porque una silueta son cuatro
/// rectángulos redondeados: meter un recurso en el bundle por esto sería peor.
struct GamepadBody: Shape {
    var style: GamepadFaceplate.Style

    func path(in rect: CGRect) -> Path {
        func caja(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                   width: w * rect.width, height: h * rect.height)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var piezas: [CGPath] = []

        // El lomo: ancho y muy redondeado, casi una pastilla.
        piezas.append(CGPath(
            roundedRect: caja(0.075, 0.055, 0.850, 0.600),
            cornerWidth: rect.width * 0.16, cornerHeight: rect.height * 0.32, transform: nil
        ))

        // Las pestañas de los gatillos, que asoman por detrás del lomo.
        for lado in [CGFloat(0.205), 0.795] {
            piezas.append(CGPath(
                roundedRect: caja(lado - 0.085, 0.004, 0.17, 0.150),
                cornerWidth: rect.width * 0.045, cornerHeight: rect.height * 0.075,
                transform: nil
            ))
        }

        // Los dos mangos. **Cónicos y no rectángulos girados**: uno girado tiene el mismo ancho
        // arriba que abajo y deja un escalón donde se junta con el lomo. Naciendo anchos y
        // acabando en punta, la unión sale de una pieza.
        for espejo in [false, true] {
            func x(_ valor: CGFloat) -> CGFloat { espejo ? 1 - valor : valor }
            var mango = Path()
            mango.move(to: p(x(0.105), 0.420))
            mango.addQuadCurve(to: p(x(0.205), 0.845), control: p(x(0.082), 0.720))
            mango.addQuadCurve(to: p(x(0.335), 0.785), control: p(x(0.275), 0.900))
            mango.addQuadCurve(to: p(x(0.390), 0.420), control: p(x(0.382), 0.615))
            mango.closeSubpath()
            piezas.append(mango.cgPath)
        }

        // **Unidas de verdad, no superpuestas.** Con las piezas sueltas el relleno sale bien pero
        // el contorno dibuja también las costuras de dentro, que es lo que delata una silueta
        // hecha a trozos. `union` devuelve un solo borde, y entonces se puede perfilar.
        let entera = piezas.dropFirst().reduce(piezas[0]) { $0.union($1) }
        return Path(entera)
    }
}
