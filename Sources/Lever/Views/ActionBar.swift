import SwiftUI
import LeverCore

/// Barra fija sobre el registro de actividad. La acción principal nunca se pierde al hacer scroll.
///
/// El botón es el `borderedProminent` del sistema, no uno propio con degradado y sombra. Un botón
/// nativo hereda el acento que el usuario eligió, el foco de teclado y el comportamiento que ya
/// conoce; el anterior solo aportaba brillo.
struct ActionBar: View {
    @ObservedObject var model: AppModel
    let mode: WorkMode
    @State private var confirmsExtractAgain = false

    private var s: Strings { model.strings }

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            status
            Spacer(minLength: Theme.Spacing.normal)
            controls
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        // Las dos salidas de «ya estaba extraído», con lo que ocupa dicho en cada una. Reemplazar
        // es destructivo y lo dice; quedarse con los dos no borra nada, pero entonces el disco
        // tiene que dar para ambos y el análisis previo lo comprueba sin descontar nada.
        .confirmationDialog(s[.safeExtractAgainTitle], isPresented: $confirmsExtractAgain) {
            Button(s(.safeReplacePrevious, model.previousSafeExtractionsSize), role: .destructive,
                   action: model.extractArchiveReplacingPrevious)
            Button(s[.safeKeepBoth], action: model.extractArchiveKeepingPrevious)
            Button(s[.cancel], role: .cancel) {}
        } message: {
            Text(s(.safeExtractAgainBody, model.previousSafeExtractionsSize))
        }
    }

    // MARK: - Lado izquierdo: qué está pasando

    @ViewBuilder
    private var status: some View {
        switch mode {
        case .archive: archiveStatus
        case .program, .safeRuns: programStatus
        case .android: androidStatus
        case .rom: romStatus
        }
    }

    @ViewBuilder
    private var archiveStatus: some View {
        if model.isExtracting {
            HStack(spacing: Theme.Spacing.normal) {
                if let progress = model.extractionProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                    Text(s(.extractingProgress, String(Int(progress * 100))))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                    Text(s[.extractingNoProgress])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else if let folder = model.lastSuccessFolder {
            Button(action: model.revealResult) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                    Text(s(.doneOpenFolder, folder.lastPathComponent))
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.link)
        } else if model.selectedArchive == nil {
            hint(s[.chooseArchiveFirst])
        } else if model.runtimeStatus.archiveTool == nil {
            hint(s[.missingExtractorShort])
        } else {
            hint(s[.readyToExtract])
        }
    }

    @ViewBuilder
    private var programStatus: some View {
        if model.isPreparingWindows {
            busy(s[.preparingWindows])
        } else if model.isRunningProgram {
            busy(s[.programIsOpen])
        } else if model.isInspectingFolder {
            busy(s[.folderScanning])
        } else if model.selectedFolder != nil && model.selectedProgram == nil {
            hint(s[.folderChooseEntry])
        } else if model.selectedProgram == nil {
            hint(s[.chooseProgramFirst])
        } else if model.wineIsBlocked {
            hint(s[.wineBlockedShort])
        } else if model.runtimeStatus.wineURL == nil {
            hint(s[.missingWineShort])
        } else {
            hint(s[.readyToRun])
        }
    }

    @ViewBuilder
    private var androidStatus: some View {
        if model.isSettingUpEmulator {
            busy(s[.emulatorSettingUp])
        } else if model.isRunningApk {
            busy(model.activityMessage)
        } else if model.isScanningDevices {
            busy(s[.deviceScanning])
        } else if model.installedPackage != nil, let device = model.selectedDevice {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                Text(s(.apkInstalledOn, device.displayName))
            }
            .font(.system(size: 12))
        } else if !model.runtimeStatus.canReachAndroid {
            hint(s[.missingAdbShort])
        } else if model.selectedApk == nil {
            hint(s[.chooseApkFirst])
        } else if model.selectedDevice?.availability != .ready {
            hint(s[.noDeviceShort])
        } else {
            hint(s[.readyToInstall])
        }
    }

    /// El renglón de estado de la pestaña de consolas.
    ///
    /// Las dos familias que ejecuta un programa aparte se preguntan **antes** que la de RetroArch,
    /// y no es un detalle de orden: un cartucho de la consola híbrida no tiene `platform` —eso solo
    /// lo tienen las máquinas que lleva un núcleo— así que caía al final y salía «no sé de qué
    /// consola es» justo debajo de un panel que acababa de decir de qué consola era. Y con
    /// RetroArch sin instalar decía que faltaba RetroArch, que para un `.xci` no hace ninguna falta.
    ///
    /// De ahí que cada familia diga cuál es **su** programa: es lo único que el usuario puede hacer
    /// para desbloquearse, y nombrar el equivocado manda a instalar lo que no era.
    @ViewBuilder
    private var romStatus: some View {
        if model.isPlayingRom {
            busy(s[.playingRom])
        } else if model.selectedRom == nil {
            // Sin juego elegido sí toca hablar de RetroArch: es lo que hace falta para la mayoría
            // de lo que se puede soltar aquí, y todavía no se sabe qué va a ser.
            hint(model.retroArchURL == nil ? s[.retroMissingTitle] : s[.dropRomTitle])
        } else if model.switchFacts.isRecognised {
            hint(
                model.switchEmulator == nil
                    ? s[.switchEmulatorMissingTitle]
                    : "\(SwitchTools.machine.name) · \(s[model.switchFacts.evidence.textKey])"
            )
        } else if let máquina = model.psMachine {
            hint(machineHint(máquina))
        } else if let máquina = model.romFacts.platform {
            hint(
                model.retroArchURL == nil
                    ? s[.retroMissingTitle]
                    : "\(máquina.name) · \(s[model.romFacts.evidence.textKey])"
            )
        } else {
            hint(s[.romUnknownTitle])
        }
    }

    /// El estado de una máquina que ejecuta un programa aparte, de lo que más bloquea a lo que
    /// menos: que no exista emulador, que no esté instalado, y si no, qué máquina es.
    private func machineHint(_ machine: StandaloneMachine) -> String {
        guard machine.isEmulated else { return s[.psNoEmulatorTitle] }
        guard model.psEmulator != nil else { return s[.errNoPsEmulator] }
        return "\(machine.name) · \(s[model.psFacts.evidence.textKey])"
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Lado derecho: los botones

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Theme.Spacing.tight) {
            switch mode {
            case .archive:
                if model.isExtracting {
                    Button(s[.stop], action: model.stopExtraction)
                        .controlSize(.large)
                }
                Button(archiveActionTitle, action: startExtraction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canExtractArchive)

            case .program, .safeRuns:
                if model.isRunningProgram || model.isPreparingWindows {
                    Button(s[.stop], action: model.stopProgram)
                        .controlSize(.large)
                }
                Button(runTitle, action: model.runProgram)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canRunProgram)

            case .android:
                if model.isRunningApk {
                    Button(s[.stop], action: model.stopRun)
                        .controlSize(.large)
                }
                if model.canOpenAndroidFullscreen {
                    Button(s[.androidFullscreen]) {
                        AndroidFullscreenPresenter.shared.present(model: model, emulatorPID: nil, screen: nil)
                    }
                    .controlSize(.large)
                    .help(s[.androidFullscreenHelp])
                }
                Button(model.isRunningApk ? s[.runningApk] : s[.runApk], action: model.runApk)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canRunApk)

            case .rom:
                if model.isPlayingRom {
                    Button(s[.stop], action: model.stopRun)
                        .controlSize(.large)
                }
                Button(model.isPlayingRom ? s[.playingRom] : s[.playRom], action: model.playRom)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canPlayRom)
            }
        }
    }

    /// Cuando este comprimido ya tiene una extracción, el botón lo dice: «Extraer otra vez». Seguir
    /// poniendo «Extraer» es lo que hacía que repetirlo pareciera la primera vez.
    private var archiveActionTitle: String {
        if model.isExtracting { return s[.extracting] }
        if hasPreviousExtraction { return s[.extractAgain] }
        return s[model.archiveOpenMode == .safe ? .extractSafe : .extract]
    }

    private var hasPreviousExtraction: Bool {
        model.archiveOpenMode == .safe && !model.archivePreviousExtractions.isEmpty
    }

    private func startExtraction() {
        // Nunca se extrae otra vez sin preguntar: la respuesta decide si queda un espacio o dos.
        if hasPreviousExtraction {
            confirmsExtractAgain = true
            return
        }
        model.extractArchive()
    }

    private var runTitle: String {
        if model.isPreparingWindows { return s[.preparingWindows] }
        if model.isRunningProgram { return s[.running] }
        return s[model.programOpenMode == .safe ? .runSafe : .run]
    }
}
