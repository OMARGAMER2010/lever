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
                    subtitle: s[.dropRomSubtitle] + " " + s[.dropSwitchSubtitle]
                        + " " + s[.dropPlayStationSubtitle],
                    systemImage: "gamecontroller",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectRom
                )
                // Un juego de PS3 o de PS4 es una carpeta, y el panel de archivos no deja
                // elegir carpetas. Sin este botón, esas dos máquinas solo entran arrastrando.
                Button(s[.menuOpenFolder]) { model.selectGameFolder() }
                    .controlSize(.small)
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
                // Dos caminos, y no es cosmético: una ROM la ejecuta RetroArch con un núcleo y
                // controles que Lever mapea; un paquete de la consola híbrida lo ejecuta un
                // programa aparte que trae los suyos. Enseñar el diagrama del mando aquí sería
                // ofrecer un ajuste que no va a ninguna parte.
                if model.switchFacts.isRecognised {
                    packageSection
                    Divider()
                    keysSection
                    Divider()
                    emulatorSection
                } else if model.psMachine != nil {
                    playStationSection
                    Divider()
                    playStationEmulatorSection
                } else {
                    coreSection
                    Divider()
                    sessionSection
                    Divider()
                    controlsSection
                }
            }
        }
    }

    // MARK: - El paquete de la consola híbrida

    /// Lo que trae dentro, que es lo que no se ve por fuera: un `.nsp` puede ser el juego solo o el
    /// juego con tres actualizaciones y ocho añadidos, y el nombre del archivo no lo dice.
    private var packageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.switchSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(s[model.switchFacts.evidence.textKey])
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if model.switchFacts.titles.isEmpty {
                Text(s[.switchNoTitles]).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(model.switchFacts.titles) { título in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(título.formattedId)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Text(s[título.kind.textKey])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let versión = título.displayVersion {
                            Text(versión).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let bytes = título.bytes {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - La familia PlayStation

    /// Lo que dice el propio juego de sí mismo. Todo esto va **sin cifrar** dentro del archivo, así
    /// que sale sin pedirle nada al usuario: es la diferencia con la consola híbrida.
    private var playStationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.psSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(s[model.psFacts.evidence.textKey])
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let título = model.psFacts.title {
                Text(título)
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let identificador = model.psFacts.titleId {
                    Text(identificador)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text(s[model.psFacts.kind.textKey]).font(.system(size: 11)).foregroundStyle(.secondary)
                if let versión = model.psFacts.version {
                    Text(versión).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let máquina = model.psMachine {
                    Text(s[máquina.maturity.textKey])
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            // Lo que se le va a dar al emulador, cuando no es lo que se soltó. De una carpeta de
            // PS3 se lanza el ejecutable de dentro, y decirlo evita la pregunta de qué está
            // abriendo exactamente.
            if let objetivo = model.psFacts.launchTarget, objetivo != model.selectedRom {
                Text(objetivo.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var playStationEmulatorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.switchEmulatorSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.psMachine?.isEmulated == true {
                    Button(s[.switchEmulatorChoose]) { model.choosePlayStationEmulator() }
                        .controlSize(.small)
                }
            }

            if let encontrado = model.psEmulator {
                Text(s(.switchEmulatorFound, encontrado.emulator.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(encontrado.app.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let firmware = model.psMachine?.firmware {
                    Text(model.psFirmwareIsReady
                         ? s[.psFirmwareReady]
                         : s(.psFirmwareBody, firmware.files.joined(separator: ", "),
                             s[firmware.source.textKey]))
                        .font(.system(size: 11))
                        .foregroundStyle(model.psFirmwareIsReady ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.psMachine?.isEmulated == true {
                Text(s[.switchEmulatorMissingBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Las llaves

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.switchKeysSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(s[.switchKeysChoose]) { model.chooseSwitchKeys() }
                    .controlSize(.small)
                if model.switchKeys != nil {
                    Button(s[.switchKeysForget]) { model.forgetSwitchKeys() }
                        .controlSize(.small)
                }
            }

            if let llaves = model.switchKeys {
                // Cuántas y de qué generación. **Nunca cuáles**: este panel se fotografía para
                // pedir ayuda, y una llave ahí dentro acabaría publicada.
                Text(s(.switchKeysFound, String(llaves.names.count))
                     + " · " + s(.switchKeysGenerations, String(llaves.keyGenerations)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let ruta = model.switchKeysURL {
                    Text(ruta.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                Text(s[.switchKeysMissingBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - El emulador

    private var emulatorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.switchEmulatorSection]).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(s[.switchEmulatorChoose]) { model.chooseSwitchEmulator() }
                    .controlSize(.small)
            }

            if let encontrado = model.switchEmulator {
                Text(s(.switchEmulatorFound, encontrado.emulator.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(encontrado.app.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(s[.switchEmulatorMissingBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isRebuildingPackage {
                ProgressView(value: model.rebuildProgress)
                    .progressViewStyle(.linear)
                Text(s[.statusRebuildingPackage]).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let ocupado = model.rebuiltPackagesSize {
                Text(s(.switchCacheNote, ocupado)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    /// Lo leído del archivo: de qué máquina, de qué generación, cuánto ocupa y —esto importa—
    /// con cuánta seguridad se sabe.
    private func romFacts(for rom: URL) -> [String] {
        var hechos: [String] = []
        if let tamaño = rom.formattedFileSize { hechos.append(tamaño) }
        if let envoltorio = model.switchFacts.container {
            hechos.append(".\(envoltorio.fileExtension)")
            hechos.append(s[model.switchFacts.evidence.textKey])
            return hechos
        }
        if let máquina = model.psMachine {
            hechos.append(máquina.name)
            if let envoltorio = model.psFacts.container {
                hechos.append(s[containerKey(envoltorio)])
            }
            return hechos
        }
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

    // MARK: - La partida

    /// Las dos decisiones que se toman una vez y se quedan: cómo se abre el juego y qué pasa al
    /// cerrarlo. Van juntas porque las dos hablan de la sesión, no del archivo.
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s[.retroSessionSection]).font(.system(size: 12, weight: .semibold))

            Toggle(s[.retroFullscreen], isOn: $model.playFullscreen)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Text(s[.retroFullscreenNote])
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(s[.retroResume], isOn: $model.resumeSessions)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Text(s[.retroResumeNote])
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
        if model.switchFacts.isRecognised {
            switchNotices
        } else if model.psFacts.isRecognised {
            playStationNotices
        } else if model.selectedRom != nil {
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

    /// Los tres avisos que se dan **antes** de que el usuario espere veinte minutos para nada: que
    /// faltan las llaves, que las suyas se quedan cortas, y que el paquete hay que rehacerlo.
    @ViewBuilder
    private var switchNotices: some View {
        if model.switchKeys == nil {
            NoticeBanner(
                kind: .warning,
                title: s[.switchKeysMissingTitle],
                message: s[.switchKeysMissingBody]
            )
        } else if let necesaria = model.switchFacts.requiredKeyGeneration,
                  let tengo = model.switchKeys?.keyGenerations,
                  model.switchFacts.keysAreTooOld(available: tengo) {
            NoticeBanner(
                kind: .failure,
                title: s[.switchKeysMissingTitle],
                message: s(.switchKeysTooOld, String(necesaria + 1), String(tengo))
            )
        }

        if model.switchEmulator == nil {
            NoticeBanner(
                kind: .warning,
                title: s[.switchEmulatorMissingTitle],
                message: s[.switchEmulatorMissingBody]
            )
        }

        if model.switchFacts.needsDecompression {
            NoticeBanner(
                kind: model.canRebuildPackages ? .info : .warning,
                title: s[.switchCompressedTitle],
                message: model.canRebuildPackages
                    ? s[.switchCompressedBody]
                    // De un cartucho comprimido sale un `.nsp`, no un cartucho. Se dice, porque
                    // quien esperaba recuperar su `.xci` tal cual se lo merece antes y no después.
                        + (model.switchFacts.container?.isCartridge == true
                           ? " " + s[.switchCartridgeNote] : "")
                    : s[.errNoZstd]
            )
        }
    }

    private func containerKey(_ container: PlayStationContainer) -> TextKey {
        switch container {
        case .folder: return .psContainerFolder
        case .discImage: return .psContainerDisc
        case .package, .vitaPackage: return .psContainerPackage
        }
    }

    /// Los avisos de la familia PlayStation, del más grave al menos: que de esta máquina no hay
    /// emulador, que la que hay va experimental, y que falta el firmware.
    @ViewBuilder
    private var playStationNotices: some View {
        if model.psFacts.hasNoEmulator {
            NoticeBanner(kind: .failure, title: s[.psNoEmulatorTitle], message: s[.psNoEmulatorBody])
        } else if model.psMachine == nil {
            // PS1 y PSP se reconocen aquí pero se juegan desde el núcleo de siempre. Decirlo evita
            // que alguien se ponga a buscar un emulador que no le hace falta.
            NoticeBanner(kind: .info, title: s[.psUseRetroArchTitle], message: s[.psUseRetroArchBody])
        } else {
            if model.psMachine?.maturity == .experimental {
                NoticeBanner(kind: .info, title: s[.psExperimentalTitle], message: s[.psExperimentalBody])
            }
            if model.psEmulator == nil {
                NoticeBanner(kind: .warning, title: s[.switchEmulatorMissingTitle],
                             message: s[.switchEmulatorMissingBody])
            } else if let firmware = model.psMachine?.firmware, !model.psFirmwareIsReady {
                NoticeBanner(
                    kind: .warning, title: s[.psFirmwareTitle],
                    message: s(.psFirmwareBody, firmware.files.joined(separator: ", "),
                               s[firmware.source.textKey])
                )
            }
        }
    }

    @ViewBuilder
    private var retroArchState: some View {
        // Con un paquete de la consola híbrida delante, RetroArch no pinta nada: ese juego no lo
        // va a abrir él. Enseñar «instala RetroArch» sería mandar a instalar lo que no hace falta.
        if model.switchFacts.isRecognised || model.psMachine != nil {
            EmptyView()
        } else if model.retroArchURL == nil {
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
        Text(model.switchFacts.isRecognised || model.psMachine != nil
             ? s[.switchDisclaimer] : s[.emulationDisclaimer])
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
