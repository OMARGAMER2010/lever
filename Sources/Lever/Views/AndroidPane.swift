import SwiftUI
import LeverCore

/// Pestaña «Android»: elegir un `.apk` e instalarlo en un aparato.
///
/// Por qué no es una copia de «Programas» con otros sustantivos: un `.exe` se ejecuta *aquí*,
/// dentro del Mac, y por eso aquella pestaña solo necesita el archivo. Un `.apk` no se ejecuta
/// en ninguna parte por sí solo — hay que instalarlo **en un aparato**. Ese destino es un objeto
/// más del problema, y por eso esta pantalla tiene una parte que las otras dos no tienen y no
/// podrían reutilizar: elegir dónde.
struct AndroidPane: View {
    @ObservedObject var model: AppModel
    @State private var showsAndroidHelp = false

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if model.selectedApk == nil {
                DropZone(
                    title: s[.dropApkTitle],
                    subtitle: s[.dropApkSubtitle],
                    systemImage: "shippingbox",
                    accept: { model.accept(droppedURLs: $0) },
                    browse: model.selectApk
                )
                RecentsList(model: model, kind: .apk)
            } else {
                Panel { apkContent }
            }

            bundleNotice
            compatibilityNotice
            emulatorState
            bridgeState
            disclaimer
        }
        .sheet(isPresented: $showsAndroidHelp) { RuntimeHelpSheet.android(model: model) }
        .onAppear { model.refreshDevices() }
    }

    // MARK: - El archivo elegido

    @ViewBuilder
    private var apkContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
            if let apk = model.selectedApk {
                SelectedFileChip(
                    url: apk,
                    facts: apkFacts(for: apk),
                    revealLabel: s[.revealInFinder],
                    removeLabel: s[.removeFile],
                    onReveal: { FileActions.reveal(apk) },
                    onClear: model.clearApk
                )

                if let package = model.apkFacts.packageName {
                    // El nombre de paquete es la identidad real de una app de Android: dos
                    // archivos con el mismo nombre visible pueden ser apps distintas, y es lo
                    // que decide si la instalación reemplaza algo que ya está en el aparato.
                    Text(package)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if model.isInspectingApk {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(s[.contentsReading])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                orientationSection
                Divider()
                deviceSection

                if model.installedPackage != nil { installedActions }
            }
        }
    }

    /// Lo leído del propio `.apk`: tamaño, versión, Android mínimo y para qué procesadores trae
    /// código. Nada de esto se supone; sale del archivo.
    private func apkFacts(for apk: URL) -> [String] {
        var facts: [String] = []
        if let size = apk.formattedFileSize { facts.append(size) }
        if let version = model.apkFacts.versionName { facts.append("v\(version)") }
        if let minSdk = model.apkFacts.minSdk {
            facts.append(
                AndroidRelease.name(forApi: minSdk).map { s(.apkMinAndroid, $0) }
                    ?? s(.apkMinApi, String(minSdk))
            )
        }
        if !model.androidPackage.parts.isEmpty {
            facts.append(s(.bundleParts, String(model.androidPackage.distinctPartCount)))
        }
        // Los datos de expansión pesan más que la app en muchos juegos: se dice antes, porque
        // son los que hacen que instalar tarde.
        let expansiones = model.androidPackage.expansions.reduce(0) { $0 + $1.size }
        if expansiones > 0 {
            facts.append(s(
                .bundleExpansions,
                ByteCountFormatter.string(fromByteCount: Int64(expansiones), countStyle: .file)
            ))
        }
        facts.append(
            model.apkFacts.isPortable
                ? s[.apkNoNativeCode]
                : model.apkFacts.abis.joined(separator: " · ")
        )
        return facts
    }

    // MARK: - En qué postura arranca

    /// El conmutador existe porque la lectura del manifiesto no siempre alcanza: muchos juegos
    /// hechos con Unity dejan `screenOrientation` sin fijar y deciden la postura desde su propio
    /// código al arrancar. Automático hace lo que pide el `.apk`; si sale girado, se fuerza.
    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.orientationSection])
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $model.rotationChoice) {
                    ForEach(RotationChoice.allCases) { choice in
                        Text(s[choice.textKey]).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(s[.orientationSection])
            }

            Text(orientationExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Qué dice el `.apk`, dicho tal cual. Si no dice nada, se avisa de por qué puede salir
    /// girado igualmente en vez de dejar al usuario pensando que la app se ha equivocado.
    private var orientationExplanation: String {
        switch model.apkFacts.orientation {
        case .portrait, .landscape:
            return s(.orientationDeclared, s[model.apkFacts.orientation.textKey].lowercased())
        case .free:
            return s[.orientationRuntimeWarning]
        }
    }

    // MARK: - Dónde instalarla

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text(s[.deviceSection])
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.isScanningDevices {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(s[.deviceScanning])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(s[.deviceRefresh], action: model.refreshDevices)
                        .controlSize(.small)
                        .disabled(!model.runtimeStatus.canReachAndroid)
                }
            }

            if model.androidDevices.isEmpty {
                if !model.isScanningDevices {
                    Text(s[.deviceNoneBody])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.androidDevices) { device in
                        deviceRow(device)
                    }
                }
            }

            if model.runtimeStatus.canStartEmulator { emulatorSection }
        }
    }

    private func deviceRow(_ device: AndroidDevice) -> some View {
        let isSelected = device.serial == model.selectedDeviceSerial
        let isUsable = device.availability == .ready

        return Button {
            model.selectedDeviceSerial = device.serial
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isUsable ? .primary : .secondary)
                        .lineLimit(1)
                    Text(deviceDetail(device))
                        .font(.system(size: 11))
                        .foregroundStyle(isUsable ? Color.secondary : Theme.attention)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.inline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isUsable)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(device.displayName). \(deviceDetail(device))")
    }

    /// Debajo del nombre va lo que decide si la instalación tiene sentido: qué es, qué Android
    /// tiene y qué procesador. Y si no se puede usar, qué le falta al usuario por hacer.
    private func deviceDetail(_ device: AndroidDevice) -> String {
        switch device.availability {
        case .unauthorized: return s[.deviceUnauthorized]
        case .offline: return s[.deviceOffline]
        case .ready:
            var parts = [device.isEmulator ? s[.deviceEmulator] : s[.devicePhone]]
            if let release = device.release { parts.append(s(.deviceAndroidVersion, release)) }
            if let abi = device.abis.first { parts.append(abi) }
            return parts.joined(separator: " · ")
        }
    }

    private var emulatorSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 2)

            Text(s[.emulatorSection])
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if model.avdNames.isEmpty {
                Text(s[.emulatorNone])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.avdNames, id: \.self) { avd in
                    HStack(spacing: Theme.Spacing.tight) {
                        Text(avd)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button(model.startingAvd == avd ? s[.emulatorStarting] : s[.emulatorStart]) {
                            model.startEmulator(named: avd)
                        }
                        .controlSize(.small)
                        .disabled(model.startingAvd != nil)
                    }
                    .padding(.horizontal, 7)
                }

                Text(s[.emulatorHint])
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
            }
        }
    }

    /// Aparecen solo después de una instalación que salió bien: son lo que se puede hacer con
    /// lo que esta app acaba de dejar en el aparato, y nada más.
    private var installedActions: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button(s[.openAgain], action: model.launchApk)
                .disabled(!model.canLaunchApk)
            Button(model.isUninstalling ? s[.uninstalling] : s[.uninstall], action: model.uninstallApk)
                .disabled(model.isUninstalling)
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: - Avisos

    /// Lo que hay que contar de un archivo que no es un `.apk` suelto: qué formato es —porque
    /// determina qué va a pasar—, qué hay que descargar para poder abrirlo, y si el `.apk` viene
    /// sin firma. Son tres cosas que el usuario no puede saber mirando el archivo.
    @ViewBuilder
    private var bundleNotice: some View {
        if model.selectedApk != nil {
            let paquete = model.androidPackage

            if paquete.readFailed, paquete.kind.isBundle {
                NoticeBanner(
                    kind: .failure,
                    title: s[.bundleUnreadableTitle],
                    message: s[.bundleUnreadableBody]
                )
            } else {
                if let explicación = bundleKindText {
                    NoticeBanner(kind: .info, title: paquete.kind.rawValue.uppercased(), message: explicación)
                }
                if paquete.needsSigning {
                    NoticeBanner(kind: .warning, title: s[.apkUnsignedTitle], message: s[.apkUnsignedBody])
                }
                if !model.androidToolNeeds.isEmpty {
                    NoticeBanner(
                        kind: .info,
                        title: s[.bundleToolsTitle],
                        message: s(.bundleToolsBody, toolNeedsText)
                    )
                }
            }
        }
    }

    private var bundleKindText: String? {
        let paquete = model.androidPackage
        let base: String
        switch paquete.kind {
        case .apk: return nil
        case .xapk: base = s[.bundleKindXapk]
        case .apks: base = s[.bundleKindApks]
        case .aab: base = s[.bundleKindAab]
        }
        guard !paquete.extraModules.isEmpty else { return base }
        return base + " " + s(.bundleModules, paquete.extraModules.joined(separator: ", "))
    }

    /// «Java (45 MB) y bundletool (32 MB)». Se dice el tamaño porque en un disco justo es lo
    /// único que el usuario necesita saber para decidir.
    private var toolNeedsText: String {
        model.androidToolNeeds
            .map { "\(s[$0.tool.textKey]) (\($0.megabytes) MB)" }
            .joined(separator: " · ")
    }

    /// Lo que se sabe antes de intentarlo. Instalar no se bloquea: se avisa y se deja decidir,
    /// igual que con un `.exe` de 32 bits.
    @ViewBuilder
    private var compatibilityNotice: some View {
        if model.selectedApk != nil, model.apkFacts.readFailed, !model.androidPackage.kind.isBundle {
            NoticeBanner(kind: .failure, title: s[.apkUnreadableTitle], message: s[.apkUnreadableBody])
        } else {
            switch model.apkCompatibility {
            case .isSplit:
                NoticeBanner(kind: .failure, title: s[.apkSplitTitle], message: s[.apkSplitBody])
            case .abiMismatch(let apk, let device):
                NoticeBanner(
                    kind: .warning,
                    title: s[.abiMismatchTitle],
                    message: s(.abiMismatchBody, apk.joined(separator: ", "), device.joined(separator: ", "))
                )
            case .sdkTooOld(let needs, let has):
                NoticeBanner(
                    kind: .warning,
                    title: s[.sdkTooOldTitle],
                    message: s(
                        .sdkTooOldBody,
                        AndroidRelease.name(forApi: needs) ?? "API \(needs)",
                        AndroidRelease.name(forApi: has) ?? "API \(has)"
                    )
                )
            case .fits, .unknown:
                EmptyView()
            }
        }
    }

    /// Sin emulador y sin móvil enchufado no hay dónde ejecutar nada. Es el único paso que
    /// cuesta gigas, así que se dice cuántos y cuántos quedarán, antes de empezar.
    @ViewBuilder
    private var emulatorState: some View {
        if model.runtimeStatus.canReachAndroid, model.avdNames.isEmpty, model.installableDevices.isEmpty {
            NoticeBanner(
                kind: .warning,
                title: s[.emulatorSetUpTitle],
                message: s[.emulatorSetUpBody] + " " + emulatorCost,
                actionTitle: model.isSettingUpEmulator ? s[.emulatorSettingUp] : s[.emulatorSetUp],
                action: model.canSetUpEmulator ? { model.setUpEmulator() } : nil
            )
        }
    }

    private var emulatorCost: String {
        guard let free = model.freeDiskSpace else { return "" }
        return s(.emulatorSetUpSize, free)
    }

    @ViewBuilder
    private var bridgeState: some View {
        if !model.runtimeStatus.canReachAndroid {
            NoticeBanner(
                kind: .warning,
                title: s[.missingAdbTitle],
                message: s[.missingAdbBody],
                actionTitle: model.canInstallTools ? s[.install] : s[.howToInstall],
                action: model.canInstallTools
                    ? { model.installTools() }
                    : { showsAndroidHelp = true }
            )
        } else {
            bridgePanel
        }
    }

    private var bridgePanel: some View {
        Panel(padding: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: Theme.Spacing.normal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                    Text(s[.androidCardTitle])
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let adb = model.runtimeStatus.adbURL {
                        Text(adb.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Text(s[.androidCardBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Qué ve `adb` ahora mismo. Sin esto, «Buscar otra vez» no contesta nada visible
                // mientras no haya un .apk elegido, y la pregunta «¿ve mi móvil?» es justo la
                // que se hace antes de ponerse a buscar el archivo.
                connectedSummary

                HStack(spacing: Theme.Spacing.tight) {
                    Button(s[.deviceRefresh], action: model.refreshDevices)
                    Spacer()
                    Button(s[.howToInstall]) { showsAndroidHelp = true }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var connectedSummary: some View {
        HStack(spacing: 6) {
            if model.isScanningDevices {
                ProgressView().controlSize(.small)
                Text(s[.deviceScanning])
            } else {
                Circle()
                    .fill(model.installableDevices.isEmpty ? Theme.attention : Theme.ready)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(
                    model.androidDevices.isEmpty
                        ? s[.deviceNoneTitle]
                        : model.androidDevices.map(\.displayName).joined(separator: ", ")
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var disclaimer: some View {
        Text(s[.androidDisclaimer])
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
