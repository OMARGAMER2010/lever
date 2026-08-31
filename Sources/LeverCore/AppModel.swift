import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    private let locator: RuntimeLocator
    private let runner: ProcessRunner
    private let fileManager: FileManager
    /// La biblioteca de motores y núcleos. Se inyecta para que las pruebas no toquen —ni ensucien—
    /// lo que el usuario tenga descargado de verdad.
    private let portLibrary: PortLibrary
    private let controlLibrary: ControlLibrary

    private var customWineURL: URL?
    private var programSession: ProcessSession?
    private var extractionSession: ProcessSession?
    private var installSession: ProcessSession?
    private var portSession: ProcessSession?

    // MARK: - Idioma

    @Published public var language: Language {
        didSet {
            guard language != oldValue else { return }
            Preferences.language = language
            strings = Strings.table(for: language)
        }
    }
    @Published public private(set) var strings: Strings

    // MARK: - Herramientas del sistema

    @Published public private(set) var runtimeStatus: RuntimeStatus

    // MARK: - Programa de Windows

    @Published public var selectedProgram: URL? {
        didSet {
            programArchitecture = selectedProgram.map(ProgramInspector.architecture(of:)) ?? .unknown
            portableGame = nil
            inspectPortable()
        }
    }
    @Published public private(set) var programArchitecture: ProgramArchitecture = .unknown
    @Published public private(set) var isRunningProgram = false
    @Published public private(set) var isPreparingWindows = false

    /// Lo que se sabe del `.exe` cuando resulta ser un juego hecho con Godot. Que no sea `nil`
    /// cambia por completo lo que conviene ofrecer: no hay que emular nada, hay que rehacer la app.
    @Published public private(set) var portableGame: PortableEngine?
    @Published public private(set) var isPorting = false
    @Published public private(set) var portStageMessage = ""
    /// Compilar la parte que falta de un complemento nativo tarda y ocupa. Se pregunta antes.
    @Published public var buildsMissingExtensions = true
    /// macOS bloquea Wine si viene marcado como descargado. Se detecta al arrancar.
    @Published public private(set) var wineIsBlocked = false
    @Published public private(set) var isUnblockingWine = false

    // MARK: - Archivo comprimido

    @Published public var selectedArchive: URL?
    /// Destino elegido a mano. Si es `nil`, se usa el sugerido automáticamente.
    @Published public var chosenDestination: URL?
    @Published public var archivePassword = ""
    @Published public var overwritePolicy: OverwritePolicy {
        didSet { Preferences.overwritePolicy = overwritePolicy }
    }
    @Published public var extractIntoSubfolder: Bool {
        didSet {
            Preferences.extractIntoSubfolder = extractIntoSubfolder
            chosenDestination = nil
        }
    }
    @Published public var revealWhenDone: Bool {
        didSet { Preferences.revealWhenDone = revealWhenDone }
    }
    @Published public private(set) var isExtracting = false
    /// De 0 a 1 mientras `7zz` informa. `nil` cuando no hay dato.
    @Published public private(set) var extractionProgress: Double?
    @Published public private(set) var archiveFacts = ArchiveFacts()
    @Published public private(set) var isInspecting = false

    // MARK: - App de Android

    @Published public var selectedApk: URL? {
        didSet {
            guard selectedApk != oldValue else { return }
            installedPackage = nil
            inspectApk()
        }
    }
    /// Lo leído del archivo elegido: un `.apk` suelto o un envoltorio con varios dentro.
    @Published public private(set) var androidPackage = AndroidPackage(kind: .apk)
    /// Lo que se sabe de la app. En un envoltorio sale de su `.apk` de base, no de la ficha que
    /// lo acompaña: la ficha la escribe quien empaquetó y a veces no dice la verdad.
    public var apkFacts: ApkFacts { androidPackage.facts }
    @Published public private(set) var isInspectingApk = false
    /// Herramientas que habría que descargar para poder instalar el archivo elegido.
    @Published public private(set) var androidToolNeeds: [AndroidToolNeed] = []
    @Published public private(set) var androidDevices: [AndroidDevice] = []
    @Published public var selectedDeviceSerial: String?
    @Published public private(set) var isScanningDevices = false
    /// Cubre toda la cadena: arrancar el emulador si hace falta, instalar, abrir y girar.
    @Published public private(set) var isRunningApk = false
    @Published public private(set) var isSettingUpEmulator = false
    /// Postura elegida a mano. En automático manda lo que declare el `.apk`.
    @Published public var rotationChoice: RotationChoice {
        didSet {
            guard rotationChoice != oldValue else { return }
            Preferences.rotationChoice = rotationChoice
            applyRotation()
        }
    }
    @Published public private(set) var isUninstalling = false
    /// Paquete que se ha confirmado instalado en el aparato. Es lo que habilita «Abrir» y
    /// «Desinstalar»: sin una instalación previa esta app no toca nada del móvil.
    @Published public private(set) var installedPackage: String?
    @Published public private(set) var avdNames: [String] = []
    @Published public private(set) var startingAvd: String?

    // MARK: - Juegos de consola

    @Published public var selectedRom: URL? {
        didSet {
            guard selectedRom != oldValue else { return }
            inspectRom()
        }
    }
    @Published public private(set) var romFacts = RomFacts()
    @Published public private(set) var isInspectingRom = false
    @Published public private(set) var isPlayingRom = false
    /// El perfil de controles que se va a usar. Sale de la biblioteca al elegir el juego, y el
    /// usuario lo cambia en el diagrama.
    @Published public var controlProfile = ControlProfile.standard
    /// A qué se le van a guardar los cambios: a todo, a esta consola o a este juego.
    @Published public var controlScope = ControlScope.global

    // MARK: - Abiertos hace poco

    @Published public private(set) var recentFiles: [RecentFile] = []

    // MARK: - Estado común

    @Published public private(set) var log: [LogEntry] = []
    @Published public private(set) var activityMessage = ""
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastSuccessFolder: URL?
    @Published public private(set) var isInstallingTools = false

    public var isBusy: Bool {
        isRunningProgram || isExtracting || isInstallingTools || isPreparingWindows
            || isRunningApk || isScanningDevices || isUninstalling || isSettingUpEmulator
            || isPorting
    }

    // MARK: - Lo que la app sabe del archivo elegido

    public var archiveContents: [String] { archiveFacts.entryNames }

    /// El extractor que abrirá el comprimido elegido.
    public var toolForSelectedArchive: ArchiveTool? {
        selectedArchive.flatMap { runtimeStatus.tool(for: $0) }
    }

    /// La elección merece explicación cuando se descarta `7zz` a propósito por ser un `.rar`.
    public var toolChoiceNeedsExplaining: Bool {
        guard let tool = toolForSelectedArchive, case .unar = tool else { return false }
        return runtimeStatus.archiveTools.contains { if case .sevenZip = $0 { return true }; return false }
    }

    /// El Wine disponible solo ejecuta 64 bits, así que un programa de 32 no arrancará.
    public var programWontRunOnThisWine: Bool {
        runtimeStatus.wineURL != nil && programArchitecture.warnsAboutWine
    }

    public var selectedDevice: AndroidDevice? {
        androidDevices.first { $0.serial == selectedDeviceSerial }
    }

    /// Aparatos donde de verdad se puede instalar. Los demás se enseñan igual, con su motivo:
    /// un móvil sin autorizar no es un fallo, es un paso que le falta al usuario.
    public var installableDevices: [AndroidDevice] {
        androidDevices.filter { $0.availability == .ready }
    }

    /// Se calcula antes de instalar comparando lo leído del `.apk` con lo que dice el aparato.
    public var apkCompatibility: ApkCompatibility {
        ApkCompatibility.check(apk: apkFacts, device: selectedDevice)
    }

    // MARK: - Reglas de habilitación

    public var canRunProgram: Bool {
        guard let selectedProgram, !isRunningProgram, !isPreparingWindows, !wineIsBlocked else { return false }
        return SupportedFileKind.exe.accepts(selectedProgram)
            && fileManager.isReadableFile(atPath: selectedProgram.path)
            && runtimeStatus.wineURL != nil
    }

    /// Carpeta donde acabará el contenido si el usuario no cambia nada.
    public var suggestedDestination: URL? {
        guard let selectedArchive else { return nil }
        let parent = selectedArchive.deletingLastPathComponent()
        guard extractIntoSubfolder else { return parent }
        return parent.appendingPathComponent(selectedArchive.suggestedFolderName, isDirectory: true)
    }

    public var effectiveDestination: URL? { chosenDestination ?? suggestedDestination }

    public var canExtractArchive: Bool {
        guard let selectedArchive, effectiveDestination != nil, !isExtracting else { return false }
        return SupportedFileKind.rar.accepts(selectedArchive)
            && fileManager.isReadableFile(atPath: selectedArchive.path)
            && runtimeStatus.tool(for: selectedArchive) != nil
    }

    /// Instalar el `.apk` no se bloquea aunque `apkCompatibility` diga que va a fallar: el aviso
    /// se enseña y la decisión se deja al usuario, igual que con un `.exe` de 32 bits. Si la
    /// lectura del archivo se equivocara, bloquear dejaría al usuario sin salida.
    public var canRunApk: Bool {
        guard let selectedApk, !isRunningApk, !isUninstalling, !isSettingUpEmulator else { return false }
        guard SupportedFileKind.apk.accepts(selectedApk),
              fileManager.isReadableFile(atPath: selectedApk.path),
              runtimeStatus.adbURL != nil else { return false }
        // Con un aparato listo se ejecuta ya; con un emulador creado, se arranca por el camino.
        return selectedDevice?.availability == .ready || !avdNames.isEmpty
    }

    /// El emulador se monta cuando no hay ninguno y tampoco hay un móvil enchufado.
    public var canSetUpEmulator: Bool {
        !isSettingUpEmulator && runtimeStatus.homebrewURL != nil && avdNames.isEmpty
    }

    /// El guion que monta el emulador viaja dentro del `.app`, para que funcione también cuando
    /// la app se abre desde el Escritorio y no hay código fuente cerca.
    public var emulatorScriptURL: URL? {
        Bundle.main.url(forResource: "android-emulator", withExtension: "sh")
    }

    /// Gigas libres en el disco, para poder decir de antemano lo que va a costar el emulador.
    public var freeDiskSpace: String? {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// La postura que se va a aplicar de verdad: la elegida a mano, o la del `.apk` en automático.
    public var effectiveOrientation: ScreenOrientation {
        rotationChoice.resolved(declaring: apkFacts.orientation)
    }

    /// Solo se puede abrir lo que esta app acaba de instalar y cuyo nombre de paquete conoce.
    public var canLaunchApk: Bool {
        installedPackage != nil && selectedDevice?.availability == .ready
            && !isRunningApk && !isUninstalling
    }

    /// El RetroArch instalado, si lo hay.
    public var retroArchURL: URL? { RetroTools.locate(fileManager: fileManager) }

    /// **La arquitectura de RetroArch, no la del Mac.** Es la que decide qué núcleo hay que bajar:
    /// el núcleo se carga dentro de su proceso, así que tiene que ser de la suya.
    public var retroArchitecture: String? { retroArchURL.flatMap(RetroTools.architecture) }

    /// Si el núcleo de este juego ya está descargado, para poder decirlo antes de pulsar.
    public var romCoreIsReady: Bool {
        guard let núcleo = romFacts.platform?.core, let arquitectura = retroArchitecture else { return false }
        return portLibrary.hasRetroCore(núcleo, architecture: arquitectura)
    }

    public var canPlayRom: Bool {
        guard let selectedRom, !isPlayingRom, romFacts.isRecognised else { return false }
        return fileManager.isReadableFile(atPath: selectedRom.path) && retroArchURL != nil
    }

    /// Los controles que de verdad existen en esta consola. Enseñar dieciséis botones para una
    /// Game Boy sería enseñar catorce casillas que no hacen nada.
    public var availableInputs: [RetroPadInput] {
        RetroPadInput.available(on: romFacts.platform)
    }

    public var canInstallTools: Bool {
        !isInstallingTools && runtimeStatus.homebrewURL != nil && !missingFormulae.isEmpty
    }

    /// Lo que Homebrew puede poner sin pedir nada más: pesa pocos megas, no necesita Java ni
    /// aceptar licencias, y no choca con nada instalado. Wine y el SDK de Android quedan fuera
    /// a propósito —gigas, licencias y casks que se pisan entre sí— y se explican en su hoja.
    public var missingFormulae: [String] {
        var packages: [String] = []
        if runtimeStatus.archiveTool == nil { packages.append(contentsOf: ["sevenzip", "unar"]) }
        if runtimeStatus.adbURL == nil { packages.append("android-platform-tools") }
        return packages
    }

    /// Qué le falta al sistema para que la app funcione entera.
    public var missingTools: [String] {
        var missing: [String] = []
        if runtimeStatus.wineURL == nil { missing.append("Wine") }
        if runtimeStatus.archiveTool == nil { missing.append(strings[.toolExtractor]) }
        if runtimeStatus.adbURL == nil { missing.append("adb") }
        return missing
    }

    /// Las maneras reales de tener un aparato Android donde instalar. Enchufar un móvil es la
    /// primera porque es la única que no descarga gigas.
    public var androidOptions: [WineOption] {
        [
            WineOption(
                name: strings[.androidOptionPhone],
                detail: strings[.androidOptionPhoneWhy],
                command: "brew install android-platform-tools"
            ),
            WineOption(
                name: strings[.androidOptionEmulator],
                detail: strings[.androidOptionEmulatorWhy],
                command: "brew install --cask temurin android-commandlinetools && "
                    + "sdkmanager --install \"emulator\" \"platform-tools\" "
                    + "\"system-images;android-34;google_apis;arm64-v8a\" && "
                    + "avdmanager create avd -n Lever -k \"system-images;android-34;google_apis;arm64-v8a\""
            ),
            WineOption(
                name: strings[.androidOptionStudio],
                detail: strings[.androidOptionStudioWhy],
                command: "brew install --cask android-studio"
            )
        ]
    }

    /// Las formas de conseguir Wine que funcionan hoy en un Mac con chip Apple.
    public var wineOptions: [WineOption] {
        [
            WineOption(
                name: strings[.wineOptionGptk],
                detail: strings[.wineOptionGptkWhy],
                command: "brew tap gcenx/wine && HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask gcenx/wine/game-porting-toolkit"
            ),
            WineOption(
                name: strings[.wineOptionCrossover],
                detail: strings[.wineOptionCrossoverWhy],
                command: "brew install --cask crossover"
            ),
            WineOption(
                name: strings[.wineOptionExisting],
                detail: strings[.wineOptionExistingWhy],
                command: nil
            )
        ]
    }

    // MARK: - Ciclo de vida

    public init(
        locator: RuntimeLocator = RuntimeLocator(),
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        portLibrary: PortLibrary = .shared,
        controlLibrary: ControlLibrary = .shared
    ) {
        self.locator = locator
        self.runner = runner
        self.fileManager = fileManager
        self.portLibrary = portLibrary
        self.controlLibrary = controlLibrary
        self.language = Preferences.language
        self.strings = Strings.table(for: Preferences.language)
        self.customWineURL = Preferences.customWineURL
        self.overwritePolicy = Preferences.overwritePolicy
        self.extractIntoSubfolder = Preferences.extractIntoSubfolder
        self.revealWhenDone = Preferences.revealWhenDone
        self.rotationChoice = Preferences.rotationChoice
        self.recentFiles = RecentFiles.load(fileManager: fileManager)
        self.runtimeStatus = locator.locate(customWineURL: Preferences.customWineURL)
        self.wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)
        self.activityMessage = Strings.table(for: Preferences.language)[.allReady]
    }

    private static func detectBlockedWine(in status: RuntimeStatus) -> Bool {
        guard let wine = status.wineURL else { return false }
        return QuarantineGuard.isQuarantined(wine)
    }

    public func refreshTools() {
        runtimeStatus = locator.locate(customWineURL: customWineURL)
        wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)

        let found = [
            runtimeStatus.wineURL != nil ? "Wine" : nil,
            runtimeStatus.archiveToolName,
            runtimeStatus.adbURL != nil ? "adb" : nil,
            runtimeStatus.emulatorURL != nil ? "emulator" : nil
        ].compactMap { $0 }

        if found.isEmpty {
            add(strings[.logNoTools], level: .warning)
        } else {
            add(strings(.logToolsFound, found.joined(separator: ", ")), level: .info)
        }
    }

    // MARK: - Selección de archivos

    public func selectProgram() {
        guard let url = FileActions.chooseFile(kind: .exe, title: strings[.menuOpenProgram]) else { return }
        acceptProgram(url)
    }

    public func acceptProgram(_ url: URL) {
        guard SupportedFileKind.exe.accepts(url) else {
            showError(strings(.errNotAProgram, url.lastPathComponent))
            return
        }
        selectedProgram = url
        remember(url, kind: .exe)
        clearError()
        add(strings(.logProgramChosen, url.lastPathComponent), level: .info)
    }

    public func clearProgram() {
        selectedProgram = nil
        portableGame = nil
    }

    public func selectArchive() {
        guard let url = FileActions.chooseFile(kind: .rar, title: strings[.menuOpenArchive]) else { return }
        acceptArchive(url)
    }

    public func acceptArchive(_ url: URL) {
        guard SupportedFileKind.rar.accepts(url) else {
            showError(strings(.errNotAnArchive, url.lastPathComponent))
            return
        }
        selectedArchive = url
        remember(url, kind: .rar)
        chosenDestination = nil
        archiveFacts = ArchiveFacts()
        archivePassword = ""
        clearError()
        add(strings(.logArchiveChosen, url.lastPathComponent), level: .info)
        inspectArchive()
    }

    public func selectApk() {
        guard let url = FileActions.chooseFile(kind: .apk, title: strings[.menuOpenApk]) else { return }
        acceptApk(url)
    }

    public func acceptApk(_ url: URL) {
        guard SupportedFileKind.apk.accepts(url) else {
            showError(strings(.errNotAnApk, url.lastPathComponent))
            return
        }
        selectedApk = url
        remember(url, kind: .apk)
        clearError()
        add(strings(.logApkChosen, url.lastPathComponent), level: .info)
        if androidDevices.isEmpty { refreshDevices() }
    }

    public func clearApk() {
        selectedApk = nil
        androidPackage = AndroidPackage(kind: .apk)
        androidToolNeeds = []
        installedPackage = nil
    }

    public func clearArchive() {
        selectedArchive = nil
        chosenDestination = nil
        archiveFacts = ArchiveFacts()
        archivePassword = ""
        lastSuccessFolder = nil
    }

    /// Punto de entrada para arrastrar y soltar, y para «Abrir con» desde el Finder.
    @discardableResult
    public func accept(droppedURLs urls: [URL]) -> Bool {
        var handled = false
        for url in urls {
            if SupportedFileKind.exe.accepts(url) {
                acceptProgram(url)
                handled = true
            } else if SupportedFileKind.apk.accepts(url) {
                acceptApk(url)
                handled = true
            } else if SupportedFileKind.rom.accepts(url), RomInspector.inspect(url).isRecognised {
                // Antes que los comprimidos porque un `.iso` y un `.bin` los reclaman los dos, y
                // aquí decide lo que el archivo tiene dentro, no cómo se llama.
                acceptRom(url)
                handled = true
            } else if SupportedFileKind.rar.accepts(url) {
                acceptArchive(url)
                handled = true
            }
        }
        if !handled, let first = urls.first {
            showError(strings(.errUnknownFile, first.lastPathComponent))
        }
        return handled
    }

    public func selectDestination() {
        let start = chosenDestination ?? selectedArchive?.deletingLastPathComponent()
        guard let url = FileActions.chooseDirectory(startingAt: start, title: strings[.saveIn]) else { return }
        chosenDestination = url
        Preferences.lastDestinationURL = url
        clearError()
        add(strings(.logDestination, url.path), level: .info)
    }

    public func useSuggestedDestination() {
        chosenDestination = nil
    }

    // MARK: - Wine

    public func selectWine() {
        guard let url = FileActions.chooseWine(title: strings[.menuFindWine]) else { return }
        guard let resolved = RuntimeLocator.resolveWineURL(url) else {
            showError(strings[.errNotWineExecutable])
            return
        }
        customWineURL = resolved
        Preferences.customWineURL = resolved
        runtimeStatus = locator.locate(customWineURL: resolved)
        wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)
        clearError()
        add(strings(.logWineChosen, resolved.path), level: .success)
    }

    public func forgetCustomWine() {
        customWineURL = nil
        Preferences.customWineURL = nil
        refreshTools()
    }

    public func openWineSettings() {
        guard let wine = runtimeStatus.wineURL else { return }
        launchDetached(WineLauncher.configCommand(wine: wine), describing: strings[.wineSettings])
    }

    public func closeWindowsPrograms() {
        guard let wine = runtimeStatus.wineURL else { return }
        launchDetached(WineLauncher.killCommand(wine: wine), describing: strings[.closeAll])
    }

    public var windowsFolderURL: URL { WineLauncher.prefixURL }

    /// Borra el entorno de Windows. Se vuelve a crear solo en la siguiente ejecución.
    public func resetWindowsEnvironment() {
        guard !isRunningProgram, !isPreparingWindows else {
            showError(strings[.errBusy])
            return
        }
        do {
            try WineLauncher.resetPrefix()
            add(strings[.logWindowsReset], level: .success)
            activityMessage = strings[.statusWindowsReset]
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Quita la marca de cuarentena que impide arrancar Wine.
    public func unblockWine() {
        guard !isUnblockingWine, let wine = runtimeStatus.wineURL else { return }
        let target = QuarantineGuard.repairTarget(for: wine)

        isUnblockingWine = true
        clearError()

        Task { [weak self] in
            guard let self else { return }
            _ = try? await runner.run(QuarantineGuard.repairCommand(for: wine)) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            isUnblockingWine = false
            wineIsBlocked = Self.detectBlockedWine(in: runtimeStatus)

            if wineIsBlocked {
                showError(strings(.errUnblockFailed, target.path))
            } else {
                activityMessage = strings[.statusWineUnblocked]
                add(strings[.logWineUnblocked], level: .success)
            }
        }
    }

    // MARK: - Ejecutar un programa de Windows

    public func runProgram() {
        guard !isRunningProgram, !isPreparingWindows else { return }
        guard let program = selectedProgram,
              SupportedFileKind.exe.accepts(program),
              fileManager.isReadableFile(atPath: program.path) else {
            showError(strings[.errPickProgram])
            return
        }
        guard let wine = runtimeStatus.wineURL else {
            showError(strings[.errNoWine])
            return
        }
        if !runtimeStatus.hasRosetta {
            showError(strings[.errNoRosetta])
            return
        }
        if wineIsBlocked {
            showError(strings[.errWineBlocked])
            return
        }

        clearError()
        let session = ProcessSession()
        programSession = session

        Task { [weak self] in
            guard let self else { return }

            if WineLauncher.needsFirstRunSetup() {
                isPreparingWindows = true
                activityMessage = strings[.statusPreparing]
                add(strings[.logFirstRun], level: .info)

                _ = try? await runner.run(WineLauncher.bootCommand(wine: wine), session: session) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
                isPreparingWindows = false

                if session.isCancelled {
                    finishProgram(message: strings[.statusStopped], level: .warning)
                    return
                }
                // Si el entorno sigue incompleto, seguir solo llevaría a un error críptico.
                if WineLauncher.needsFirstRunSetup() {
                    finishProgram(message: strings[.statusWindowsFailed], level: .failure)
                    showError(strings[.errWinePrefixFailed])
                    return
                }
                add(strings[.logWindowsReady], level: .success)
            }

            isRunningProgram = true
            activityMessage = strings(.statusRunning, program.lastPathComponent)

            do {
                let result = try await runner.run(
                    WineLauncher.runCommand(wine: wine, program: program),
                    session: session
                ) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }

                if result.wasCancelled {
                    finishProgram(message: strings[.statusStopped], level: .warning)
                } else if result.succeeded {
                    finishProgram(message: strings[.statusFinished], level: .success)
                } else {
                    isRunningProgram = false
                    activityMessage = strings[.statusFailed]
                    showError(strings(.errProgramExit, String(result.exitCode)))
                }
            } catch {
                isRunningProgram = false
                activityMessage = strings[.statusCannotStart]
                showError(error.localizedDescription)
            }
            programSession = nil
        }
    }

    public func stopProgram() {
        programSession?.cancel()
        add(strings[.logStopping], level: .warning)
    }

    // MARK: - Juegos que pueden correr nativos

    /// Reconocer el motor implica leer índices con miles de entradas. Va fuera del hilo principal
    /// para que la ventana no se quede tiesa al soltar un juego de trescientos megas.
    private func inspectPortable() {
        guard let program = selectedProgram, SupportedFileKind.exe.accepts(program) else { return }
        Task { [weak self] in
            let found = await Task.detached { PortableEngineDetector.detect(program: program) }.value
            guard let self, self.selectedProgram == program, let found else { return }
            self.portableGame = found
            self.add(self.strings(.logPortableDetected, found.displayName), level: .info)
        }
    }

    /// Hay un motor reconocido, es de una versión contemplada y no hay nada más en marcha.
    public var canMakeNativeApp: Bool {
        guard let portableGame, portableGame.isSupported else { return false }
        return !isBusy
    }

    /// El motor de esta versión ya está guardado de otra vez: no hay descarga por delante.
    public var portableRuntimeIsCached: Bool {
        portableGame?.runtimeIsCached(in: PortLibrary.shared) ?? false
    }

    /// Partes nativas sin su versión de macOS, con lo que Lever puede hacer con cada una.
    public var portableUnresolvedParts: [(name: String, recipe: NativePartRecipe?)] {
        (portableGame?.unresolvedParts ?? []).map { ($0, NativePartRecipe.recipe(forAddon: $0)) }
    }

    /// Crea el `.app` nativo. El juego original no se toca en ningún momento.
    public func makeNativeApp() {
        guard let game = portableGame, !isPorting else { return }
        guard game.isSupported else {
            showError(strings(game.unsupportedKey, game.runtimeVersionText))
            return
        }

        let needed = game.requiredBytes(
            cached: game.runtimeIsCached(in: PortLibrary.shared),
            buildingParts: buildsMissingExtensions
        )
        if let free = freeDiskBytes, free < needed {
            showError(strings(.errPortNoSpace, ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)))
            return
        }

        clearError()
        let session = ProcessSession()
        portSession = session
        isPorting = true
        activityMessage = strings[.statusPorting]
        showPort(stage: .reading)

        let destination = desktopURL
        let buildParts = buildsMissingExtensions

        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await NativePorter.makeApp(
                    for: game,
                    into: destination,
                    buildMissingParts: buildParts,
                    runner: runner,
                    session: session,
                    scriptProvider: { Bundle.main.url(forResource: $0, withExtension: "sh") },
                    onStage: { stage in Task { @MainActor [weak self] in self?.showPort(stage: stage) } },
                    onLine: { line in Task { @MainActor [weak self] in self?.addOutput(line) } }
                )
                finishPort(outcome: outcome)
            } catch PortFailure.cancelled {
                isPorting = false
                activityMessage = strings[.statusStopped]
                add(strings[.statusStopped], level: .warning)
            } catch let failure as PortFailure {
                isPorting = false
                activityMessage = strings[.statusFailed]
                showError(describe(failure))
            } catch {
                isPorting = false
                activityMessage = strings[.statusFailed]
                showError(error.localizedDescription)
            }
            portSession = nil
            portStageMessage = ""
        }
    }

    public func stopPorting() {
        portSession?.cancel()
        add(strings[.logStopping], level: .warning)
    }

    private func finishPort(outcome: PortOutcome) {
        isPorting = false
        activityMessage = strings[.statusPortDone]
        lastSuccessFolder = outcome.app
        add(strings(.logPorted, outcome.app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
            level: .success)
        // Decirlo aunque la app ya esté hecha: un juego que abre y peta en el primer vídeo sin
        // explicación es peor que un aviso claro por adelantado.
        if !outcome.unresolvedParts.isEmpty {
            add(strings(.logPortUnresolved, outcome.unresolvedParts.joined(separator: ", ")), level: .warning)
        }
        if revealWhenDone { FileActions.reveal(outcome.app) }
    }

    private func showPort(stage: PortStage) {
        let text: String
        switch stage {
        case .downloadingRuntime(let version): text = strings(stage.textKey, version)
        case .buildingPart(let name): text = strings(stage.textKey, name)
        default: text = strings[stage.textKey]
        }
        portStageMessage = text
        activityMessage = text
        add(text, level: .info)
    }

    private func describe(_ failure: PortFailure) -> String {
        switch failure {
        case .downloadFailed(let code): return strings(failure.textKey, String(code))
        case .assemblyFailed(let reason): return strings(failure.textKey, reason)
        case .notEnoughSpace(let bytes):
            return strings(failure.textKey, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        default: return strings[failure.textKey]
        }
    }

    private var desktopURL: URL {
        fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    private var freeDiskBytes: Int64? {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    private func finishProgram(message: String, level: LogLevel) {
        isRunningProgram = false
        isPreparingWindows = false
        activityMessage = message
        add(level == .success ? strings[.logProgramClosed] : message, level: level)
    }

    // MARK: - Extraer

    public func inspectArchive() {
        guard let archive = selectedArchive,
              let tool = runtimeStatus.tool(for: archive) else { return }
        let lister = locator.listerURL(for: tool)
        guard let command = ArchiveCommandBuilder.listCommand(
            for: tool,
            lister: lister,
            archive: archive,
            password: archivePassword
        ) else { return }

        isInspecting = true
        let usedLister = lister != nil

        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(command)
            isInspecting = false

            guard let result, result.succeeded else {
                // El archivo se lee pero la herramienta no pudo listarlo: casi siempre, contraseña.
                archiveFacts = ArchiveFacts(entryNames: [], listingFailed: true)
                return
            }
            archiveFacts = ArchiveFacts(
                entryNames: ArchiveCommandBuilder.names(fromListing: result.output, usedLister: usedLister),
                listingFailed: false
            )
        }
    }

    public func extractArchive() {
        guard !isExtracting else { return }
        guard let archive = selectedArchive,
              SupportedFileKind.rar.accepts(archive),
              fileManager.isReadableFile(atPath: archive.path) else {
            showError(strings[.errPickArchive])
            return
        }
        guard let destination = effectiveDestination else {
            showError(strings[.errPickDestination])
            return
        }
        guard let tool = runtimeStatus.tool(for: archive) else {
            showError(strings[.errNoExtractor])
            return
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            showError(strings(.errCannotCreateFolder, destination.lastPathComponent, error.localizedDescription))
            return
        }

        // Si la carpeta estaba vacía, un reintento puede reemplazar sin miedo lo que quedó a medias.
        let destinationWasEmpty = isEmptyDirectory(destination)

        clearError()
        lastSuccessFolder = nil
        extractionProgress = tool.reportsProgress ? 0 : nil
        isExtracting = true
        activityMessage = strings(.statusExtracting, archive.lastPathComponent)
        add(strings(.logExtracting, archive.lastPathComponent, tool.displayName), level: .info)

        let session = ProcessSession()
        extractionSession = session

        Task { [weak self] in
            guard let self else { return }
            await self.performExtraction(
                archive: archive,
                destination: destination,
                tool: tool,
                session: session,
                destinationWasEmpty: destinationWasEmpty,
                isRetry: false
            )
        }
    }

    private func performExtraction(
        archive: URL,
        destination: URL,
        tool: ArchiveTool,
        session: ProcessSession,
        destinationWasEmpty: Bool,
        isRetry: Bool
    ) async {
        // En un reintento lo escrito por la herramienta anterior no es fiable, así que se reemplaza,
        // pero solo si la carpeta estaba vacía antes de empezar: nunca se pisan archivos del usuario.
        let policy: OverwritePolicy = (isRetry && destinationWasEmpty) ? .overwrite : overwritePolicy

        let command = ArchiveCommandBuilder.command(
            for: tool,
            archive: archive,
            destination: destination,
            policy: policy,
            password: archivePassword
        )

        do {
            let result = try await runner.run(command, session: session) { line in
                Task { @MainActor [weak self] in self?.addExtractionLine(line) }
            }

            if result.wasCancelled {
                finishExtraction(message: strings[.statusStopped])
                add(strings[.logStopped], level: .warning)
                return
            }

            if result.succeeded {
                finishExtraction(message: strings[.statusExtracted])
                add(strings(.logExtractedTo, destination.path), level: .success)
                add(strings[.logOriginalKept], level: .info)
                lastSuccessFolder = destination
                if revealWhenDone { FileActions.openInFinder(destination) }
                return
            }

            // Cada extractor cubre formatos distintos: si uno no puede, se prueba con el otro.
            if !isRetry, let alternative = runtimeStatus.fallbackTool(for: archive, after: tool) {
                add(strings(.logRetryingWith, tool.displayName, alternative.displayName), level: .warning)
                extractionProgress = alternative.reportsProgress ? 0 : nil
                await performExtraction(
                    archive: archive,
                    destination: destination,
                    tool: alternative,
                    session: session,
                    destinationWasEmpty: destinationWasEmpty,
                    isRetry: true
                )
                return
            }

            finishExtraction(message: strings[.statusFailed])
            showError(explain(exitCode: result.exitCode))
        } catch {
            finishExtraction(message: strings[.statusCannotStart])
            showError(error.localizedDescription)
        }
    }

    public func stopExtraction() {
        extractionSession?.cancel()
        add(strings[.logStopping], level: .warning)
    }

    public func revealResult() {
        guard let lastSuccessFolder else { return }
        FileActions.openInFinder(lastSuccessFolder)
    }

    private func finishExtraction(message: String) {
        isExtracting = false
        extractionProgress = nil
        extractionSession = nil
        activityMessage = message
    }

    private func isEmptyDirectory(_ url: URL) -> Bool {
        let contents = try? fileManager.contentsOfDirectory(atPath: url.path)
        return (contents ?? []).filter { $0 != ".DS_Store" }.isEmpty
    }

    // MARK: - Android

    private func inspectApk() {
        guard let apk = selectedApk else {
            androidPackage = AndroidPackage(kind: .apk)
            androidToolNeeds = []
            return
        }
        isInspectingApk = true
        Task { [weak self] in
            // Fuera del hilo principal: leer el directorio de un `.apk` de un giga con decenas
            // de miles de entradas no debe congelar la ventana, y de un envoltorio hay además
            // que sacar su `.apk` de base para poder leerlo.
            let leído = await Task.detached { AndroidBundleInspector.inspect(apk) }.value
            guard let self, selectedApk == apk else { return }
            androidPackage = leído
            androidToolNeeds = AndroidTools.needs(for: leído, having: AndroidTools.locate())
            isInspectingApk = false
        }
    }

    /// Pregunta a `adb` qué aparatos hay y, a los que responden, por sus datos.
    ///
    /// No hay repaso automático en segundo plano a propósito: significaría un proceso corriendo
    /// sin que nadie lo haya pedido. Se repasa al abrir la pestaña, al pulsar el botón y al
    /// arrancar un emulador.
    public func refreshDevices() {
        guard let adb = runtimeStatus.adbURL, !isScanningDevices else { return }

        isScanningDevices = true
        Task { [weak self] in
            guard let self else { return }
            let listing = try? await runner.run(AndroidLauncher.listDevicesCommand(adb: adb))
            var found = AndroidLauncher.devices(fromListing: listing?.output ?? "")

            for (index, device) in found.enumerated() where device.availability == .ready {
                guard let result = try? await runner.run(
                    AndroidLauncher.propertiesCommand(adb: adb, serial: device.serial)
                ), result.succeeded else { continue }

                let properties = AndroidLauncher.properties(fromOutput: result.output)
                found[index] = AndroidDevice(
                    serial: device.serial,
                    availability: .ready,
                    model: properties.model ?? device.model,
                    abis: properties.abis,
                    sdk: properties.sdk,
                    release: properties.release
                )
            }

            // Solo se escribe en el registro si la lista cambió: si no, abrir la pestaña dos
            // veces llenaría la actividad de líneas idénticas.
            let changed = found.map(\.serial) != androidDevices.map(\.serial)
            androidDevices = found
            isScanningDevices = false

            if selectedDeviceSerial == nil || !found.contains(where: { $0.serial == selectedDeviceSerial }) {
                selectedDeviceSerial = found.first { $0.availability == .ready }?.serial
            }
            if changed {
                if found.isEmpty {
                    add(strings[.logNoDevices], level: .info)
                } else {
                    add(strings(.logDevicesFound, found.map(\.displayName).joined(separator: ", ")), level: .info)
                }
            }
            refreshAvds()
        }
    }

    public func refreshAvds() {
        guard let emulator = runtimeStatus.emulatorURL else {
            avdNames = []
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(AndroidLauncher.listAvdsCommand(emulator: emulator))
            avdNames = AndroidLauncher.avdNames(fromListing: result?.output ?? "")
        }
    }

    /// Arranca un emulador. No se espera a que termine: se queda abierto como una ventana más,
    /// y tarda uno o dos minutos en responder a `adb`.
    public func startEmulator(named avd: String) {
        guard let emulator = runtimeStatus.emulatorURL, startingAvd == nil else { return }

        startingAvd = avd
        clearError()
        activityMessage = strings[.statusEmulatorStarting]
        add(strings(.logEmulatorStarting, avd), level: .info)

        Task { [weak self] in
            guard let self else { return }
            _ = try? await runner.run(AndroidLauncher.startEmulatorCommand(emulator: emulator, avd: avd)) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            // El proceso solo termina cuando se cierra la ventana del emulador.
            startingAvd = nil
            refreshDevices()
        }
    }

    /// Ejecutar un `.apk`: arrancar el emulador si no hay ningún aparato, esperar a que termine
    /// de arrancar, instalar, abrir y poner la pantalla en la postura que toque.
    ///
    /// Es un solo botón porque es una sola intención —«quiero jugar a esto»— y partirla en cuatro
    /// pasos manuales sería trasladarle al usuario un trabajo que la app puede hacer. Cada paso
    /// dice en qué va, y se puede detener en cualquiera.
    public func runApk() {
        guard !isRunningApk else { return }
        guard let apk = selectedApk,
              SupportedFileKind.apk.accepts(apk),
              fileManager.isReadableFile(atPath: apk.path) else {
            showError(strings[.errPickApk])
            return
        }
        guard let adb = runtimeStatus.adbURL else {
            showError(strings[.errNoAdb])
            return
        }

        clearError()
        installedPackage = nil
        isRunningApk = true

        let session = ProcessSession()
        installSession = session

        Task { [weak self] in
            guard let self else { return }
            defer {
                isRunningApk = false
                installSession = nil
            }

            guard let serial = await readyDeviceSerial(adb: adb, session: session) else { return }
            guard !session.isCancelled else {
                activityMessage = strings[.statusStopped]
                return
            }
            guard let resultado = await install(apk: apk, adb: adb, serial: serial, session: session)
            else { return }

            installedPackage = resultado.packageName
            await open(package: resultado.packageName, adb: adb, serial: serial)
            await rotate(adb: adb, serial: serial, to: effectiveOrientation)
        }
    }

    /// Devuelve la serie de un aparato listo, arrancando el emulador si hace falta.
    private func readyDeviceSerial(adb: URL, session: ProcessSession) async -> String? {
        if let device = selectedDevice, device.availability == .ready { return device.serial }

        guard let emulator = runtimeStatus.emulatorURL, let avd = avdNames.first else {
            showError(strings[.errNoDevice])
            return nil
        }

        activityMessage = strings[.statusEmulatorStarting]
        add(strings(.logEmulatorStarting, avd), level: .info)
        startingAvd = avd

        // El emulador no termina: se queda abierto como una ventana más. Se lanza sin esperarlo
        // y se vigila por `adb` hasta que conteste.
        Task { [weak self] in
            guard let self else { return }
            _ = try? await runner.run(AndroidLauncher.startEmulatorCommand(emulator: emulator, avd: avd)) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            startingAvd = nil
            refreshDevices()
        }

        guard let serial = await waitForBoot(adb: adb, session: session) else {
            if !session.isCancelled {
                activityMessage = strings[.statusFailed]
                showError(strings[.errEmulatorTimeout])
            }
            return nil
        }

        add(strings[.logEmulatorReady], level: .success)
        refreshDevices()
        return serial
    }

    /// Un emulador sale en `adb devices` mucho antes de poder instalar nada: la señal buena es
    /// `sys.boot_completed`. Se pregunta cada pocos segundos, con un tope, en vez de esperar
    /// indefinidamente a algo que puede no llegar nunca.
    private func waitForBoot(adb: URL, session: ProcessSession) async -> String? {
        let deadline = Date().addingTimeInterval(300)

        while Date() < deadline, !session.isCancelled {
            let listing = try? await runner.run(AndroidLauncher.listDevicesCommand(adb: adb))
            let devices = AndroidLauncher.devices(fromListing: listing?.output ?? "")

            if let ready = devices.first(where: { $0.availability == .ready }) {
                let boot = try? await runner.run(
                    AndroidLauncher.waitForBootCommand(adb: adb, serial: ready.serial)
                )
                if AndroidLauncher.hasFinishedBooting(boot?.output ?? "") {
                    selectedDeviceSerial = ready.serial
                    return ready.serial
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return nil
    }

    private func install(
        apk: URL, adb: URL, serial: String, session: ProcessSession
    ) async -> AndroidInstallOutcome? {
        activityMessage = strings(.statusInstallingApk, apk.lastPathComponent)
        add(strings(.logInstallingApk, apk.lastPathComponent, selectedDevice?.displayName ?? serial), level: .info)

        // Los ABI del aparato se preguntan aquí y no se cogen de la lista: cuando el emulador se
        // acaba de arrancar, la lista todavía no los tiene, y sin ellos no se puede elegir qué
        // trozo de una app partida le toca.
        let device = await deviceForInstall(adb: adb, serial: serial)
        let paquete = androidPackage

        do {
            let resultado = try await AndroidInstaller.install(
                package: paquete, at: apk, adb: adb, device: device,
                runner: runner, session: session,
                onStage: { stage in
                    Task { @MainActor [weak self] in self?.announce(stage) }
                },
                onLine: { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
            )

            add(strings[.logApkInstalled], level: .success)
            if resultado.wasSigned { add(strings[.logApkSigned], level: .info) }
            if resultado.installedParts > 1 {
                add(strings(.logPartsInstalled, String(resultado.installedParts)), level: .info)
            }
            if resultado.pushedExpansions > 0 {
                add(strings(.logExpansionsPushed, String(resultado.pushedExpansions)), level: .success)
            }
            return resultado
        } catch let failure as AndroidInstallFailure {
            if case .cancelled = failure {
                activityMessage = strings[.statusStopped]
                add(strings[.logStopped], level: .warning)
                return nil
            }
            activityMessage = strings[.statusFailed]
            showError(explain(failure))
            return nil
        } catch {
            activityMessage = strings[.statusCannotStart]
            showError(error.localizedDescription)
            return nil
        }
    }

    /// Pregunta al aparato por sus datos justo antes de instalar.
    private func deviceForInstall(adb: URL, serial: String) async -> AndroidDevice {
        if let known = androidDevices.first(where: { $0.serial == serial }), !known.abis.isEmpty {
            return known
        }
        let result = try? await runner.run(AndroidLauncher.propertiesCommand(adb: adb, serial: serial))
        let properties = AndroidLauncher.properties(fromOutput: result?.output ?? "")
        return AndroidDevice(
            serial: serial, availability: .ready, model: properties.model,
            abis: properties.abis, sdk: properties.sdk, release: properties.release
        )
    }

    /// Traduce el paso en el que va la instalación al texto que se enseña.
    private func announce(_ stage: AndroidInstallStage) {
        switch stage {
        case .gettingTool(let need):
            let texto = strings(.statusGettingAndroidTool, strings[need.tool.textKey], String(need.megabytes))
            activityMessage = texto
            add(texto, level: .info)
        case .unpacking:
            activityMessage = strings[.statusUnpackingBundle]
        case .signing:
            activityMessage = strings[.statusSigningApk]
            add(strings[.statusSigningApk], level: .info)
        case .buildingApks:
            activityMessage = strings[.statusBuildingApks]
            add(strings[.statusBuildingApks], level: .info)
        case .installing(let parts):
            activityMessage = parts > 1
                ? strings(.statusInstallingParts, String(parts))
                : strings(.statusInstallingApk, selectedApk?.lastPathComponent ?? "")
        case .pushingExpansion(let name, let index, let total):
            activityMessage = strings(.statusPushingExpansion, name, String(index), String(total))
        }
    }

    private func explain(_ failure: AndroidInstallFailure) -> String {
        switch failure {
        case .cancelled: return strings[.statusStopped]
        case .missingTool(let tool): return strings(.errAndroidToolMissing, strings[tool.textKey])
        case .rejected(let motivo): return explain(installFailure: motivo)
        case .failed(let code): return strings(.errInstallOther, String(code))
        case .unreadable: return strings[.errBundleUnreadable]
        }
    }

    private func open(package: String?, adb: URL, serial: String) async {
        guard let package else {
            // Sin nombre de paquete no hay a quién llamar. Se instaló, y eso se dice.
            activityMessage = strings[.statusApkInstalled]
            return
        }

        activityMessage = strings[.statusApkRunning]
        add(strings[.logApkLaunched], level: .info)

        let result = try? await runner.run(
            AndroidLauncher.launchCommand(adb: adb, serial: serial, package: package)
        ) { line in
            Task { @MainActor [weak self] in self?.addOutput(line) }
        }
        if let output = result?.output, AndroidLauncher.hasNoLauncherActivity(inOutput: output) {
            showError(strings[.errNoLauncher])
        }
    }

    /// Pone la pantalla del aparato en la postura pedida.
    private func rotate(adb: URL, serial: String, to orientation: ScreenOrientation) async {
        let command = orientation.deviceRotation.map {
            AndroidLauncher.lockRotationCommand(adb: adb, serial: serial, quarterTurns: $0)
        } ?? AndroidLauncher.freeRotationCommand(adb: adb, serial: serial)

        _ = try? await runner.run(command)
        add(strings(.logRotated, strings[orientation.textKey]), level: .info)
    }

    /// Aplica la postura al vuelo cuando se toca el conmutador, sin tener que reinstalar nada.
    public func applyRotation() {
        guard let adb = runtimeStatus.adbURL,
              let device = selectedDevice,
              device.availability == .ready else { return }
        let orientation = effectiveOrientation
        Task { [weak self] in
            await self?.rotate(adb: adb, serial: device.serial, to: orientation)
        }
    }

    /// Monta el emulador: SDK, imagen del sistema y el aparato virtual. Son unos 5 GB.
    ///
    /// Lo hace un guion y no una serie de órdenes desde aquí porque `sdkmanager` pide aceptar
    /// licencias por la entrada estándar, y en esta app los procesos van con la entrada cerrada
    /// para que nada se cuelgue esperando. El guion las acepta desde dentro.
    public func setUpEmulator() {
        guard !isSettingUpEmulator else { return }
        guard let script = emulatorScriptURL else {
            showError(strings[.errEmulatorScriptMissing])
            return
        }

        clearError()
        isSettingUpEmulator = true
        activityMessage = strings[.emulatorSettingUp]
        add(strings[.emulatorSettingUp], level: .info)

        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(AndroidLauncher.setUpEmulatorCommand(script: script)) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            isSettingUpEmulator = false
            refreshTools()
            refreshDevices()

            if result?.succeeded == true {
                activityMessage = strings[.emulatorReady]
                add(strings[.emulatorReady], level: .success)
            } else {
                activityMessage = strings[.statusFailed]
                showError(strings[.errEmulatorSetUpFailed])
            }
        }
    }

    public func stopRun() {
        installSession?.cancel()
        add(strings[.logStopping], level: .warning)
    }

    public func launchApk() {
        guard let adb = runtimeStatus.adbURL,
              let device = selectedDevice,
              let package = installedPackage else { return }

        clearError()
        add(strings[.logApkLaunched], level: .info)

        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(
                AndroidLauncher.launchCommand(adb: adb, serial: device.serial, package: package)
            ) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            // Una app sin pantalla propia se instala bien pero no abre nada: sin este aviso el
            // usuario mira el móvil esperando algo que no va a pasar.
            if let output = result?.output, AndroidLauncher.hasNoLauncherActivity(inOutput: output) {
                showError(strings[.errNoLauncher])
            }
        }
    }

    /// Quita del aparato lo que esta app acaba de instalar.
    ///
    /// Sin diálogo de confirmación a propósito: solo puede deshacer la instalación anterior, el
    /// botón dice lo que hace y aparece justo al lado de «Abrir». Confirmar el deshacer de la
    /// última acción sería ceremonia, no seguridad.
    public func uninstallApk() {
        guard !isUninstalling,
              let adb = runtimeStatus.adbURL,
              let device = selectedDevice,
              let package = installedPackage else { return }

        isUninstalling = true
        clearError()

        Task { [weak self] in
            guard let self else { return }
            let result = try? await runner.run(
                AndroidLauncher.uninstallCommand(adb: adb, serial: device.serial, package: package)
            ) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
            isUninstalling = false

            if result?.succeeded == true, AndroidLauncher.installFailure(inOutput: result?.output ?? "") == nil {
                installedPackage = nil
                activityMessage = strings[.statusApkUninstalled]
                add(strings[.logApkUninstalled], level: .success)
            } else {
                activityMessage = strings[.statusFailed]
                showError(strings(.errInstallOther, String(result?.exitCode ?? -1)))
            }
        }
    }

    private func explain(installFailure: AndroidLauncher.InstallFailure) -> String {
        switch installFailure {
        case .noMatchingAbis: return strings[.errInstallNoAbis]
        case .olderSdk: return strings[.errInstallOldSdk]
        case .signatureMismatch: return strings[.errInstallSignature]
        case .versionDowngrade: return strings[.errInstallDowngrade]
        case .noSpace: return strings[.errInstallNoSpace]
        case .notSigned: return strings[.errInstallNotSigned]
        case .blockedByDevice: return strings[.errInstallBlocked]
        case .other(let code): return strings(.errInstallOther, code)
        }
    }

    // MARK: - Consolas

    public func selectRom() {
        guard let url = FileActions.chooseFile(kind: .rom, title: strings[.menuOpenRom]) else { return }
        acceptRom(url)
    }

    public func acceptRom(_ url: URL) {
        selectedRom = url
        remember(url, kind: .rom)
        clearError()
        add(strings(.logApkChosen, url.lastPathComponent), level: .info)
    }

    public func clearRom() {
        selectedRom = nil
        romFacts = RomFacts()
    }

    private func inspectRom() {
        guard let rom = selectedRom else {
            romFacts = RomFacts()
            return
        }
        isInspectingRom = true
        Task { [weak self] in
            // Fuera del hilo principal: una imagen de disco puede pesar gigas y hay que leerle la
            // cabecera.
            let leído = await Task.detached { RomInspector.inspect(rom) }.value
            guard let self, selectedRom == rom else { return }
            romFacts = leído
            // Los controles se cargan aquí porque dependen de qué consola sea: el perfil de la
            // Nintendo 64 no vale para una Game Boy.
            controlProfile = controlLibrary.resolved(platform: leído.platform, gameName: rom.lastPathComponent)
            controlScope = controlLibrary.effectiveScope(
                platform: leído.platform, gameName: rom.lastPathComponent
            )
            isInspectingRom = false
        }
    }

    /// Guarda los controles en el nivel elegido y los deja listos para el próximo lanzamiento.
    public func saveControls() {
        do {
            try controlLibrary.save(controlProfile, for: controlScope)
            add(strings[.controlsSaveHere], level: .success)
        } catch {
            showError(error.localizedDescription)
        }
    }

    public func resetControls() {
        controlLibrary.remove(controlScope)
        controlProfile = controlLibrary.resolved(
            platform: romFacts.platform, gameName: selectedRom?.lastPathComponent
        )
    }

    /// Consigue el núcleo si hace falta, escribe la configuración y lanza el juego.
    ///
    /// Un solo botón porque es una sola intención. Y la configuración se escribe **cada vez**: es
    /// lo que hace que un cambio en los controles se note sin tener que reiniciar nada.
    public func playRom() {
        guard !isPlayingRom else { return }
        guard let rom = selectedRom, let plataforma = romFacts.platform else {
            showError(strings[.errPickRom])
            return
        }
        guard let retroarch = retroArchURL, let arquitectura = retroArchitecture else {
            showError(strings[.errNoRetroArch])
            return
        }

        clearError()
        isPlayingRom = true
        let session = ProcessSession()
        installSession = session

        Task { [weak self] in
            guard let self else { return }
            defer { isPlayingRom = false; installSession = nil }

            let núcleo: URL
            do {
                if !portLibrary.hasRetroCore(plataforma.core, architecture: arquitectura) {
                    activityMessage = strings(.statusGettingCore, plataforma.name)
                    add(activityMessage, level: .info)
                }
                núcleo = try await RetroTools.ensureCore(
                    plataforma.core, architecture: arquitectura,
                    runner: runner, session: session, library: portLibrary,
                    onLine: { línea in Task { @MainActor [weak self] in self?.addOutput(línea) } }
                )
            } catch {
                activityMessage = strings[.statusFailed]
                showError(strings[.errNoCore])
                return
            }

            do {
                let configuración = try writeRetroConfig(for: plataforma)
                activityMessage = strings[.statusLaunchingRetro]
                add(strings(.logInstallingApk, rom.lastPathComponent, plataforma.name), level: .info)

                try RetroTools.open(
                    retroarch: retroarch, core: núcleo, rom: rom, config: configuración,
                    log: portLibrary.retroDataURL.appendingPathComponent("retroarch.log")
                )
                // El juego es otro programa: se abre y sigue por su cuenta, como el emulador de
                // Android. Lever no se queda esperando a que alguien termine de jugar.
                activityMessage = strings[.statusApkRunning]
            } catch {
                activityMessage = strings[.statusFailed]
                showError(error.localizedDescription)
            }
        }
    }

    /// Deja escrita la configuración con la que se lanza. Es un archivo de Lever, no el del
    /// usuario: RetroArch usa solo el que se le pasa con `-c`.
    private func writeRetroConfig(for platform: RetroPlatform) throws -> URL {
        let datos = portLibrary.retroDataURL
        let partidas = datos.appendingPathComponent("partidas", isDirectory: true)
        let estados = datos.appendingPathComponent("estados", isDirectory: true)
        let sistema = datos.appendingPathComponent("sistema", isDirectory: true)
        let listas = datos.appendingPathComponent("listas", isDirectory: true)
        for carpeta in [partidas, estados, sistema, listas] {
            try fileManager.createDirectory(at: carpeta, withIntermediateDirectories: true)
        }

        let archivo = datos.appendingPathComponent("lever.cfg")
        let texto = RetroConfig.makeConfig(
            profile: controlProfile, platform: platform,
            saves: partidas, states: estados, systemFiles: sistema, data: datos
        )
        try texto.write(to: archivo, atomically: true, encoding: .utf8)
        return archivo
    }

    // MARK: - Instalar herramientas

    public func installTools() {
        guard !isInstallingTools else { return }
        guard let homebrew = runtimeStatus.homebrewURL else {
            showError(strings[.errHomebrewMissing])
            return
        }
        // Solo lo que se puede poner sin pedirle nada más al usuario: los extractores y `adb`.
        // Wine y el SDK de Android quedan fuera —gigas, licencias, casks que chocan entre sí— y
        // se explican en su hoja con la orden lista para copiar.
        let formulae = missingFormulae
        guard !formulae.isEmpty else {
            add(strings[.logExtractorsPresent], level: .success)
            return
        }

        clearError()
        isInstallingTools = true
        activityMessage = strings[.statusInstalling]
        add(strings(.logInstalling, formulae.joined(separator: ", ")), level: .info)
        add(strings[.logInstallTakesTime], level: .info)

        let command = ProcessCommand(
            executableURL: homebrew,
            arguments: ["install"] + formulae,
            currentDirectoryURL: nil,
            environment: [
                "PATH": RuntimeLocator.searchPathDirectories.joined(separator: ":"),
                "HOMEBREW_NO_AUTO_UPDATE": "1"
            ]
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.run(command) { line in
                    Task { @MainActor [weak self] in self?.addOutput(line) }
                }
                isInstallingTools = false
                refreshTools()
                // `adb` recién instalado: la lista de aparatos ya se puede pedir.
                if runtimeStatus.adbURL != nil { refreshDevices() }
                if result.succeeded {
                    activityMessage = strings[.statusToolsInstalled]
                    add(strings[.logInstallDone], level: .success)
                } else {
                    activityMessage = strings[.statusFailed]
                    showError(strings(.errInstallFailed, String(result.exitCode)))
                }
            } catch {
                isInstallingTools = false
                activityMessage = strings[.statusCannotStart]
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Abiertos hace poco

    /// Los de un tipo, del más reciente al más antiguo. Cada pestaña enseña solo los suyos: una
    /// lista mezclada obligaría a leer el icono de cada fila para saber cuáles puede abrir.
    public func recentFiles(of kind: SupportedFileKind) -> [RecentFile] {
        RecentFiles.files(of: kind, in: recentFiles)
    }

    private func remember(_ url: URL, kind: SupportedFileKind) {
        RecentFiles.remember(url, kind: kind)
        refreshRecents()
    }

    public func refreshRecents() {
        recentFiles = RecentFiles.load(fileManager: fileManager)
    }

    /// Vuelve a abrir un archivo de la lista, como si se acabara de arrastrar.
    public func reopen(_ file: RecentFile) {
        guard fileManager.fileExists(atPath: file.path) else {
            // Pudo desaparecer entre que se pintó la lista y se pulsó. Se dice y se marca.
            showError(strings(.errRecentMissing, file.name))
            refreshRecents()
            return
        }

        switch file.kind {
        case .exe: acceptProgram(file.url)
        case .rar: acceptArchive(file.url)
        case .apk: acceptApk(file.url)
        case .rom: acceptRom(file.url)
        }
    }

    public func renameRecent(_ file: RecentFile, to newName: String) {
        apply(to: file) { try RecentFiles.rename(file, to: newName, fileManager: fileManager) }
    }

    /// Pregunta a dónde y mueve el archivo allí.
    public func moveRecent(_ file: RecentFile) {
        guard let directory = FileActions.chooseDirectory(
            startingAt: file.url.deletingLastPathComponent(),
            title: strings[.recentsMove]
        ) else { return }
        apply(to: file) { try RecentFiles.move(file, to: directory, fileManager: fileManager) }
    }

    /// Renombrar y mover comparten todo menos la orden: comprobar, contar lo que pasó y dejar
    /// apuntando al sitio nuevo lo que estuviera seleccionado.
    private func apply(to file: RecentFile, operation: () throws -> URL) {
        clearError()
        do {
            let destination = try operation()
            guard destination != file.url else { return }

            refreshRecents()
            followSelection(from: file, to: destination)
            add(
                destination.deletingLastPathComponent() == file.url.deletingLastPathComponent()
                    ? strings(.logRenamed, destination.lastPathComponent)
                    : strings(.logMoved, destination.deletingLastPathComponent().path),
                level: .success
            )
        } catch let error as RecentFileError {
            showError(explain(error))
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Si el archivo movido era el que estaba elegido, la selección va con él. Si no, la pestaña
    /// se quedaría apuntando a una ruta que ya no existe.
    private func followSelection(from file: RecentFile, to destination: URL) {
        switch file.kind {
        case .exe where selectedProgram == file.url: selectedProgram = destination
        case .rar where selectedArchive == file.url: selectedArchive = destination
        case .apk where selectedApk == file.url: selectedApk = destination
        default: break
        }
    }

    public func forgetRecent(_ file: RecentFile) {
        RecentFiles.forget(file)
        refreshRecents()
    }

    public func clearRecents(of kind: SupportedFileKind) {
        RecentFiles.clear(kind: kind)
        refreshRecents()
    }

    private func explain(_ error: RecentFileError) -> String {
        switch error {
        case .emptyName: return strings[.errRenameEmpty]
        case .alreadyExists(let name): return strings(.errNameTaken, name)
        case .failed(let reason): return strings(.errRenameFailed, reason)
        }
    }

    // MARK: - Registro de actividad

    public func clearLog() {
        log.removeAll()
        lastError = nil
        activityMessage = strings[.allReady]
    }

    public func copyLog() {
        let text = log.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
        FileActions.copyToClipboard(text)
        add(strings[.logActivityCopied], level: .info)
    }

    public func copyCommand(_ command: String) {
        FileActions.copyToClipboard(command)
        add(strings[.logCommandCopied], level: .info)
    }

    private func addExtractionLine(_ line: String) {
        if let percentage = ArchiveCommandBuilder.progressPercentage(from: line) {
            extractionProgress = Double(percentage) / 100
            // Las líneas de porcentaje llegan a decenas por segundo: no van al registro.
            return
        }
        addOutput(line)
    }

    private func addOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(trimmed, level: .output)
    }

    private func add(_ text: String, level: LogLevel) {
        log.append(LogEntry(text: text, level: level))
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }

    private func clearError() {
        lastError = nil
    }

    private func showError(_ message: String) {
        lastError = message
        add(message, level: .failure)
    }

    /// Traduce códigos de salida secos en algo accionable.
    private func explain(exitCode: Int32) -> String {
        switch exitCode {
        case 2: return strings[.errExtractExit2]
        case 1: return strings[.errExtractExit1]
        default: return strings(.errExtractExitOther, String(exitCode))
        }
    }

    private func launchDetached(_ command: ProcessCommand, describing activity: String) {
        add(activity, level: .info)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await runner.run(command) { line in
                Task { @MainActor [weak self] in self?.addOutput(line) }
            }
        }
    }
}
