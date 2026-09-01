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
        // Más ancha que una hoja normal a propósito: el dibujo necesita el mando en medio y una
        // columna de etiquetas a cada lado, y apretarlas parte los nombres en dos líneas.
        .frame(width: 820, height: 660)
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

    /// El mando, con la forma del que está conectado. Todo lo que decide el dibujo —silueta,
    /// posiciones y nombres— vive en `GamepadDiagram`; aquí solo se le dice a qué mando parecerse
    /// y qué hacer cuando se pulsa una casilla.
    private var gamepadDiagram: some View {
        GamepadDiagram(
            family: gamepads.gamepads.first?.family,
            inputs: model.availableInputs,
            profile: model.controlProfile,
            listening: listening,
            strings: s,
            onPick: { control in
                listening == control ? stopListening() : startListening(control)
            }
        )
        .frame(height: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s[.controlsSection])
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
