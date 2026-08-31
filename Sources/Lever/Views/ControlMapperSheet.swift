import SwiftUI
import LeverCore

/// El diagrama del mando: se pulsa el botón dibujado y luego la tecla o el botón de verdad.
///
/// Es una sola pantalla y no una lista de ajustes porque el problema es espacial: nadie recuerda
/// qué es «el botón B» de una consola que no ha tenido nunca, pero todo el mundo reconoce el
/// botón de abajo del rombo. El dibujo es el índice.
///
/// Solo salen los botones que la consola elegida tiene de verdad. Enseñar dieciséis casillas para
/// una Game Boy, que tiene cuatro y dos, sería enseñar catorce que no hacen nada.
struct ControlMapperSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var gamepads = GamepadWatcher()

    /// Qué control está esperando a que se pulse algo. `nil` = no se está escuchando.
    @State private var listening: RetroPadInput?
    @State private var monitor: Any?

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    gamepadDiagram
                    gamepadList
                }
                .padding(.vertical, Theme.Spacing.tight)
            }

            Divider()
            footer
        }
        .padding(Theme.Spacing.page)
        .frame(width: 640, height: 620)
        .onAppear { gamepads.start() }
        .onDisappear { stopListening(); gamepads.stop() }
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s[.controlsSection]).font(.system(size: 15, weight: .semibold))
            if let máquina = model.romFacts.platform {
                Text("\(máquina.name) · \(s[máquina.architecture.textKey])")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // A qué se le van a guardar los cambios. Va arriba y no escondido al final porque
            // cambia el significado de todo lo que se toque debajo.
            Picker("", selection: scopeBinding) {
                Text(s[.controlsScopeGlobal]).tag(0)
                Text(s[.controlsScopePlatform]).tag(1)
                Text(s[.controlsScopeGame]).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.romFacts.platform == nil)
        }
    }

    private var scopeBinding: Binding<Int> {
        Binding(
            get: {
                switch model.controlScope {
                case .global: return 0
                case .platform: return 1
                case .game: return 2
                }
            },
            set: { nuevo in
                let máquina = model.romFacts.platform?.id ?? ""
                let juego = model.selectedRom?.lastPathComponent ?? ""
                switch nuevo {
                case 1: model.controlScope = .platform(máquina)
                case 2: model.controlScope = .game(juego)
                default: model.controlScope = .global
                }
            }
        )
    }

    // MARK: - El dibujo

    /// El mando, con cada botón en su sitio. Las posiciones son relativas para que el dibujo
    /// aguante cualquier tamaño sin descolocarse.
    private var gamepadDiagram: some View {
        GeometryReader { geometría in
            let ancho = geometría.size.width
            let alto = geometría.size.height

            ZStack {
                RoundedRectangle(cornerRadius: 60)
                    .strokeBorder(Theme.hairline, lineWidth: 1.5)
                    .frame(width: ancho * 0.74, height: alto * 0.62)
                    .position(x: ancho / 2, y: alto * 0.58)

                ForEach(visibleInputs, id: \.self) { control in
                    let sitio = position(of: control)
                    buttonChip(control)
                        .position(x: ancho * sitio.x, y: alto * sitio.y)
                }
            }
        }
        .frame(height: 330)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s[.controlsSection])
    }

    private var visibleInputs: [RetroPadInput] {
        model.availableInputs
    }

    /// Dónde va cada control dentro del dibujo, en proporción del alto y del ancho. Es la
    /// disposición de un mando de verdad: cruceta a la izquierda, rombo a la derecha, gatillos
    /// arriba y las dos palancas abajo en medio.
    private func position(of input: RetroPadInput) -> (x: CGFloat, y: CGFloat) {
        switch input {
        case .l2: return (0.20, 0.10)
        case .l: return (0.20, 0.22)
        case .r2: return (0.80, 0.10)
        case .r: return (0.80, 0.22)
        case .up: return (0.22, 0.42)
        case .left: return (0.13, 0.55)
        case .right: return (0.31, 0.55)
        case .down: return (0.22, 0.68)
        case .x: return (0.78, 0.42)
        case .y: return (0.69, 0.55)
        case .a: return (0.87, 0.55)
        case .b: return (0.78, 0.68)
        case .select: return (0.42, 0.42)
        case .start: return (0.58, 0.42)
        case .l3: return (0.40, 0.78)
        case .r3: return (0.60, 0.78)
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight: return (0.40, 0.62)
        case .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight: return (0.60, 0.62)
        }
    }

    /// Un botón del dibujo: su nombre, lo que tiene asignado, y el estado de escucha.
    ///
    /// Enseña las dos asignaciones, la del teclado y la del mando, porque las dos valen a la vez:
    /// RetroArch escribe una línea para cada una. Con una sola casilla, asignar el mando parecería
    /// haber borrado la tecla.
    private func buttonChip(_ input: RetroPadInput) -> some View {
        let escuchando = listening == input
        let tecla = model.controlProfile.binding(for: input)
        let mando = model.controlProfile.gamepadBinding(for: input)

        return Button {
            escuchando ? stopListening() : startListening(input)
        } label: {
            VStack(spacing: 1) {
                Text(input.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(escuchando ? "…" : tecla.label(s))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tecla.isAssigned ? Color.secondary : Theme.attention)
                if mando.isAssigned, !escuchando {
                    Text(mando.label(s))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 66, height: 46)
            .background(
                escuchando ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: Theme.Radius.inline)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.inline)
                    .strokeBorder(escuchando ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(escuchando ? s[.controlsListening] : s(.controlsPressPrompt, input.symbol))
        .accessibilityLabel("\(input.symbol): \(tecla.label(s)), \(mando.label(s))")
    }

    // MARK: - Mandos conectados

    private var gamepadList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s[.controlsGamepads]).font(.system(size: 12, weight: .semibold))

            if gamepads.gamepads.isEmpty {
                Text(s[.controlsNoGamepad])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(gamepads.gamepads) { mando in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.ready).frame(width: 6, height: 6)
                        Text(mando.name).font(.system(size: 11, weight: .medium))
                        Text(mando.family.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Text(s[.controlsGamepadHint])
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pie

    private var footer: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button(s[.controlsReset]) { model.resetControls() }
            Spacer()
            Button(s[.controlsSaveHere]) {
                model.saveControls()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
    }

    // MARK: - Escuchar

    /// Empieza a escuchar para un control. Mientras dura, **el teclado se traga entero**: si no,
    /// pulsar Enter para asignarlo cerraría la hoja, que es el botón por omisión.
    private func startListening(_ input: RetroPadInput) {
        stopListening()
        listening = input

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { evento in
            guard let nombre = RetroKeyNames.name(forKeyCode: evento.keyCode) else { return nil }
            assign(.key(nombre), to: input)
            return nil
        }

        // Y a la vez el mando, para que dé igual con qué se conteste.
        gamepads.listen { enlace in
            assign(enlace, to: input)
        }
    }

    /// Guarda la asignación donde le toca. Una tecla y un botón del mando no compiten por el mismo
    /// sitio: RetroArch admite los dos para el mismo control, así que asignar uno deja el otro.
    private func assign(_ binding: ControlBinding, to input: RetroPadInput) {
        if case .key = binding {
            model.controlProfile.keyboard[input] = binding
        } else {
            model.controlProfile.gamepad[input] = binding
        }
        stopListening()
    }

    private func stopListening() {
        listening = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        gamepads.stopListening()
    }
}
