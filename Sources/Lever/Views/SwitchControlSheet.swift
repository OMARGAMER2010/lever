import SwiftUI
import LeverCore

/// Los controles de la consola híbrida: el mando de la consola dibujado sobre el que hay puesto, y
/// al lado de cada botón con qué se pulsa.
///
/// **Qué dibuja y qué dice.** La silueta es la del mando conectado, porque es el que el usuario
/// tiene en la mano. Los botones marcados encima son los de **la consola** —`A` a la derecha, `ZL`
/// en el gatillo, `−` y `+` en medio—, porque son los que el juego nombra cuando dice «pulsa A». Y
/// cada etiqueta dice las dos formas de pulsarlo: el botón del mando y la tecla. Así se ve todo de
/// un vistazo, que es justo lo que una lista de ajustes no da.
///
/// **Por qué el botón del mando se elige de una lista y la tecla se escucha.** `GamepadWatcher`
/// devuelve el número que le pondría RetroArch, sacado de la lista de elementos HID en crudo.
/// Traducir ese número al nombre que escribe este emulador —`A`, `LeftShoulder`, `DpadUp`— sería
/// una inferencia, y una inferencia escrita en la configuración de otro programa da un botón mudo
/// sin ningún mensaje de error. La lista es un hecho. La tecla no tiene ese problema: el código de
/// tecla de macOS se traduce sin adivinar nada.
struct SwitchControlSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var gamepads = GamepadWatcher()

    /// Qué botón de la consola se está asignando. `nil` = ninguno.
    @State private var editing: SwitchPadInput?
    @State private var monitor: Any?
    /// Lo último que dijo la escritura, para enseñarlo sin cerrar la hoja.
    @State private var outcome: ControlWriteOutcome?
    /// De dónde salió el identificador del mando. Guardado y no preguntado al dibujar: averiguarlo
    /// abre el `Config.json` y puede arrancar el subsistema de SDL, y SwiftUI redibuja muchas veces
    /// por segundo. Se vuelve a preguntar cuando cambia la lista de mandos, que es lo único que
    /// puede cambiar la respuesta.
    @State private var padSource: String?

    private var s: Strings { model.strings }
    private var family: ConnectedGamepad.Family { gamepads.gamepads.first?.family ?? .generic }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    diagram
                    sticks
                    assignment
                    padList
                }
                .padding(.vertical, Theme.Spacing.tight)
            }

            Divider()
            footer
        }
        .padding(Theme.Spacing.page)
        // Igual de ancha que la de RetroArch y por lo mismo: el dibujo necesita el mando en medio y
        // una columna de etiquetas a cada lado. Un poco más alta porque aquí cada etiqueta lleva dos
        // renglones, el del mando y el de la tecla.
        .frame(width: 860, height: 720)
        .onAppear { gamepads.start(); refreshPadSource() }
        .onChange(of: gamepads.gamepads) { _ in refreshPadSource() }
        .onDisappear { stopListening(); gamepads.stop() }
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s[.switchControlsTitle]).font(.system(size: 15, weight: .semibold))
            Text(s[.switchControlsSubtitle])
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A qué se le guarda. Va arriba y no escondido al final porque cambia el significado
            // de todo lo que se toque debajo.
            Picker("", selection: scopeBinding) {
                Text(s[.switchControlsScopeGlobal]).tag(0)
                Text(s[.switchControlsScopeGame]).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Sin juego delante no hay a qué llamar «este juego».
            .disabled(model.switchGameId == nil)

            faceLayout
        }
    }

    private var scopeBinding: Binding<Int> {
        Binding(
            get: { if case .game = model.switchControlScope { return 1 } else { return 0 } },
            set: { nuevo in
                if nuevo == 1, let juego = model.switchGameId {
                    model.switchControlScope = .game(juego)
                } else {
                    model.switchControlScope = .global
                }
            }
        )
    }

    /// El interruptor del rombo. Es el único ajuste que casi todo el mundo va a querer tocar y el
    /// único cuyo efecto se ve entero en el dibujo sin guardar nada: al cambiarlo, las etiquetas de
    /// los cuatro botones de la derecha se intercambian delante del usuario.
    private var faceLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.tight) {
                Text(s[.switchFaceSection]).font(.system(size: 12, weight: .semibold))
                Picker("", selection: $model.switchControlProfile.faceLayout) {
                    ForEach(SwitchFaceLayout.allCases, id: \.self) { disposición in
                        Text(s[disposición.textKey]).tag(disposición)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(s[.switchFaceNote])
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - El dibujo

    /// El dibujo lleva los dieciséis botones que un mando puede asignar, y **no** los ocho sentidos
    /// de las palancas. No es por gusto: en el dibujo caben doce etiquetas por lado y veinticuatro
    /// se pisarían unas a otras. Y encaja con lo que el archivo permite —un mando asigna la palanca
    /// entera, no sus sentidos—, así que los ocho que faltan son justo los que solo valen para el
    /// teclado y bajan a su propia fila, donde se leen mejor y sin mentir sobre a quién sirven.
    private var diagram: some View {
        GamepadDiagram(
            family: gamepads.gamepads.first?.family,
            inputs: SwitchPadInput.onGamepad.map(\.spot),
            listening: editing?.spot,
            strings: s,
            // Dentro del botón, el nombre que le da **la consola**: es el que el juego dice en
            // pantalla cuando pide que se pulse algo.
            glyph: { sitio in SwitchPadInput.at(sitio)?.label ?? "" },
            // Y en la etiqueta, con qué se pulsa: el botón del mando que hay puesto.
            title: { sitio in
                guard let control = SwitchPadInput.at(sitio) else { return "" }
                guard SwitchPadInput.onGamepad.contains(control) else { return control.label }
                return SDLButton.label(
                    model.switchControlProfile.gamepadBinding(for: control), family: family
                )
            },
            describe: { sitio in
                guard let control = SwitchPadInput.at(sitio) else { return "" }
                return "\(control.label), \(keyLabel(control))"
            },
            onPick: { sitio in
                guard let control = SwitchPadInput.at(sitio) else { return }
                editing == control ? stopListening() : startEditing(control)
            },
            caption: { sitio in
                if let control = SwitchPadInput.at(sitio) {
                    Text(keyLabel(control)).foregroundStyle(.secondary)
                }
            }
        )
        .frame(height: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s[.switchControlsTitle])
    }

    private func keyLabel(_ control: SwitchPadInput) -> String {
        SwitchKeyNames.label(for: model.switchControlProfile.keyboardBinding(for: control))
    }

    // MARK: - Las palancas

    /// Los ocho sentidos de las dos palancas, que son de teclado y de nadie más: un mando mueve la
    /// palanca entera y no hay nada que asignar por sentidos. Se enseñan igual porque quien juega
    /// sin mando los necesita, y porque «todos los botones y teclas» son estos también.
    private var sticks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(s[.switchControlsKeyColumn]) · L3 / R3")
                .font(.system(size: 12, weight: .semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92), spacing: 6)],
                alignment: .leading, spacing: 6
            ) {
                ForEach(SwitchPadInput.allCases.filter { !SwitchPadInput.onGamepad.contains($0) }) {
                    control in
                    Button { editing == control ? stopListening() : startEditing(control) } label: {
                        HStack(spacing: 6) {
                            Text(control.label).font(.system(size: 11, weight: .semibold))
                            Text(editing == control ? s[.switchControlsListening] : keyLabel(control))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(editing == control ? Color.accentColor : .secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 7)
                        .background {
                            let forma = RoundedRectangle(cornerRadius: Theme.Radius.inline)
                            forma.fill(editing == control ? Color.accentColor.opacity(0.12) : .clear)
                            forma.strokeBorder(
                                editing == control ? Color.accentColor : Theme.hairline, lineWidth: 1
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(control.label): \(keyLabel(control))")
                }
            }
        }
    }

    // MARK: - Asignar

    /// El panel de asignación. Sale al pulsar un botón del dibujo y ofrece las dos respuestas a la
    /// vez: elegir el botón del mando de la lista, o pulsar la tecla y ya está.
    @ViewBuilder
    private var assignment: some View {
        if let control = editing {
            VStack(alignment: .leading, spacing: 8) {
                Text(s(.switchControlsPickPad, control.label))
                    .font(.system(size: 12, weight: .semibold))

                // Las direcciones de palanca solo existen para el teclado: un mando asigna la
                // palanca entera, no sus cuatro sentidos. Ofrecer botones aquí sería ofrecer algo
                // que el archivo no sabe guardar.
                if SwitchPadInput.onGamepad.contains(control) {
                    padChoices(for: control)
                }

                HStack(spacing: 6) {
                    Text(s[.switchControlsKeyColumn])
                        .font(.system(size: 11, weight: .medium))
                    Text(s[.switchControlsListening])
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(keyLabel(control))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.normal)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.inline))
        }
    }

    private func padChoices(for control: SwitchPadInput) -> some View {
        let elegido = model.switchControlProfile.gamepadBinding(for: control)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], alignment: .leading, spacing: 6
        ) {
            ForEach(SDLButton.assignable, id: \.self) { botón in
                Button {
                    model.switchControlProfile.gamepad[control] = botón
                    stopListening()
                } label: {
                    Text(SDLButton.label(botón, family: family))
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            let forma = RoundedRectangle(cornerRadius: Theme.Radius.inline)
                            forma.fill(botón == elegido ? Color.accentColor.opacity(0.18) : .clear)
                            forma.strokeBorder(
                                botón == elegido ? Color.accentColor : Theme.hairline, lineWidth: 1
                            )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Los mandos

    private var padList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s[.switchControlsPadColumn]).font(.system(size: 12, weight: .semibold))

            if gamepads.gamepads.isEmpty {
                Text(s[.switchControlsNoPad])
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
            }

            // De dónde salió el identificador con el que el emulador va a reconocer el mando.
            // Se dice porque es el dato que decide si esto va a funcionar, y porque cuando falta,
            // saber que falta es lo que permite arreglarlo.
            if let padSource {
                Text(s(.switchControlsPadFrom, padSource))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(s[.switchControlsApplyNote])
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let outcome, !outcome.isSuccess {
                Text(s[outcome.textKey])
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pie

    private var footer: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button(s[.switchControlsReset]) {
                model.resetSwitchControls()
                stopListening()
            }
            Spacer()
            Button(s[.switchControlsSave]) {
                stopListening()
                let resultado = model.saveSwitchControls()
                outcome = resultado
                // Solo se cierra si salió bien. Cerrarse tras un fallo escondería el motivo, que
                // es lo único que el usuario necesita para arreglarlo.
                if resultado.isSuccess { dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
    }

    // MARK: - Escuchar el teclado

    /// Mientras se escucha, **el teclado se traga entero**: si no, pulsar Intro para asignarlo
    /// activaría el botón por omisión y cerraría la hoja.
    private func startEditing(_ control: SwitchPadInput) {
        stopListening()
        editing = control

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { evento in
            guard let nombre = SwitchKeyNames.name(forKeyCode: evento.keyCode) else { return nil }
            model.switchControlProfile.keyboard[control] = nombre
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        editing = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func refreshPadSource() {
        padSource = model.switchPadIdentity()?.source
    }
}
