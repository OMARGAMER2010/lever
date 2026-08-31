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
    }

    // MARK: - Lado izquierdo: qué está pasando

    @ViewBuilder
    private var status: some View {
        switch mode {
        case .archive: archiveStatus
        case .program: programStatus
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

    @ViewBuilder
    private var romStatus: some View {
        if model.isPlayingRom {
            busy(s[.playingRom])
        } else if model.retroArchURL == nil {
            hint(s[.retroMissingTitle])
        } else if model.selectedRom == nil {
            hint(s[.dropRomTitle])
        } else if let máquina = model.romFacts.platform {
            hint("\(máquina.name) · \(s[model.romFacts.evidence.textKey])")
        } else {
            hint(s[.romUnknownTitle])
        }
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
                Button(model.isExtracting ? s[.extracting] : s[.extract], action: model.extractArchive)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canExtractArchive)

            case .program:
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

    private var runTitle: String {
        if model.isPreparingWindows { return s[.preparingWindows] }
        if model.isRunningProgram { return s[.running] }
        return s[.run]
    }
}
