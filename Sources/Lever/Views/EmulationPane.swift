import SwiftUI
import LeverCore

/// Pestaña «Consolas»: elegir el juego de una consola y jugarlo.
///
/// Por qué no se parece a las otras tres: aquí el archivo no se ejecuta ni se instala, se
/// *interpreta*. Hace falta saber de qué máquina es —y eso se lee de su cabecera—, conseguir el
/// núcleo que la emula, y decidir con qué se juega. Ese último paso es el que las otras pestañas
/// no tienen: un `.exe` trae sus controles dentro, una ROM no.
struct EmulationPane: View {
    @ObservedObject var model: AppModel
    @State private var showsMapper = false

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.selectedRom == nil {
                DropZone(
                    title: s[.dropRomTitle],
                    subtitle: s[.dropRomSubtitle],
                    systemImage: "gamecontroller",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectRom
                )
                RecentsList(model: model, kind: .rom)
            } else {
                Panel { romContent }
            }

            romNotices
            retroArchState
            disclaimer
        }
        .sheet(isPresented: $showsMapper) { ControlMapperSheet(model: model) }
    }

    // MARK: - El juego elegido

    @ViewBuilder
    private var romContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            if let rom = model.selectedRom {
                SelectedFileChip(
                    url: rom,
                    facts: romFacts(for: rom),
                    revealLabel: s[.revealInFinder],
                    removeLabel: s[.removeFile],
                    onReveal: { FileActions.reveal(rom) },
                    onClear: model.clearRom
                )

                // El nombre que la ROM lleva escrito dentro, que no es el del archivo. Sirve para
                // ver de un vistazo que es el juego que se cree y no una copia mal nombrada.
                if let interno = model.romFacts.internalName {
                    Text(interno)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                } else if model.isInspectingRom {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(s[.contentsReading]).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                Divider()
                coreSection
                Divider()
                controlsSection
            }
        }
    }

    /// Lo leído del archivo: de qué máquina, de qué generación, cuánto ocupa y —esto importa—
    /// con cuánta seguridad se sabe.
    private func romFacts(for rom: URL) -> [String] {
        var hechos: [String] = []
        if let tamaño = rom.formattedFileSize { hechos.append(tamaño) }
        if let máquina = model.romFacts.platform {
            hechos.append(máquina.name)
            hechos.append(s[máquina.architecture.textKey])
        }
        hechos.append(s[model.romFacts.evidence.textKey])
        return hechos
    }

    // MARK: - El núcleo

    private var coreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.retroCoreSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let máquina = model.romFacts.platform {
                    Text(máquina.core)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.romCoreIsReady ? s[.retroCoreCached] : s[.retroCoreToDownload])
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // La arquitectura del núcleo la manda RetroArch, no el Mac: se dice, porque es la
            // causa del único fallo de carga que no se entiende mirando el mensaje del sistema.
            if let arquitectura = model.retroArchitecture {
                Text(s(.retroArchNote, arquitectura))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Controles

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.controlsSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(s[.controlsEdit]) { showsMapper = true }
                    .controlSize(.small)
            }

            Text("\(model.controlProfile.name) · \(s[scopeKey])")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // Un resumen de lo que va a hacer cada tecla, sin tener que abrir el diagrama.
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopeKey: TextKey {
        switch model.controlScope {
        case .global: return .controlsScopeGlobal
        case .platform: return .controlsScopePlatform
        case .game: return .controlsScopeGame
        }
    }

    private var summary: String {
        model.availableInputs.prefix(6).map { control in
            let mando = model.controlProfile.gamepadBinding(for: control)
            let tecla = model.controlProfile.binding(for: control).label(s)
            // El mando solo sale si se ha tocado: cuando está sin asignar lo pone RetroArch por su
            // cuenta, y anunciar «sin asignar» sería decir que no funciona.
            return mando.isAssigned
                ? "\(control.symbol) \(tecla)/\(mando.label(s))"
                : "\(control.symbol) \(tecla)"
        }.joined(separator: "   ")
    }

    // MARK: - Avisos

    @ViewBuilder
    private var romNotices: some View {
        if model.selectedRom != nil {
            if !model.romFacts.isRecognised, !model.isInspectingRom {
                NoticeBanner(kind: .failure, title: s[.romUnknownTitle], message: s[.romUnknownBody])
            }
            if let máquina = model.romFacts.platform {
                // Una BIOS no se puede descargar: sale de una consola de verdad. Decirlo antes
                // ahorra una descarga y una pantalla en negro sin explicación.
                if máquina.needsBios {
                    NoticeBanner(
                        kind: .warning,
                        title: s[.romNeedsBiosTitle],
                        message: s(.romNeedsBiosBody, máquina.requiredBios.joined(separator: ", "))
                    )
                }
                if máquina.hasTouch {
                    NoticeBanner(kind: .info, title: s[.romTouchTitle], message: s[.romTouchBody])
                }
            }
        }
    }

    @ViewBuilder
    private var retroArchState: some View {
        if model.retroArchURL == nil {
            NoticeBanner(
                kind: .warning,
                title: s[.retroMissingTitle],
                message: s[.retroMissingBody] + " brew install --cask retroarch"
            )
        } else {
            Panel(padding: Theme.Spacing.normal) {
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                        Text(s[.retroCardTitle]).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let ruta = model.retroArchURL {
                            Text(ruta.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Text(s[.retroCardBody])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var disclaimer: some View {
        Text(s[.emulationDisclaimer])
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
