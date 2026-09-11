import Foundation

/// Los dos idiomas de la app.
public enum Language: String, CaseIterable, Identifiable, Sendable {
    case spanish = "es"
    case english = "en"

    public var id: String { rawValue }

    /// Nombre en su propio idioma, como manda la convención.
    public var nativeName: String {
        switch self {
        case .spanish: return "Español"
        case .english: return "English"
        }
    }

    public var flag: String {
        switch self {
        case .spanish: return "🇪🇸"
        case .english: return "🇺🇸"
        }
    }

    /// Idioma inicial según la configuración del sistema; español si no coincide ninguno.
    public static var systemDefault: Language {
        let preferred = Locale.preferredLanguages.first ?? "es"
        return preferred.hasPrefix("en") ? .english : .spanish
    }
}

/// Claves de todo el texto visible. Enumerarlas permite comprobar en las pruebas que ningún
/// idioma se queda corto, en vez de descubrir un hueco en producción.
public enum TextKey: String, CaseIterable, Sendable {
    // Barra superior
    case tabPrograms, tabArchives, tabAndroid
    case toolWine, toolExtractor, toolAndroid, toolNotInstalled, languageMenu

    // Menú de herramientas
    case menuTools, menuRefresh, menuInstallMissing, menuFindWine, menuForgetWine
    case menuUnblockWine, menuResetWindows, menuOpenWindowsFolder
    case menuOpenProgram, menuOpenArchive, menuOpenApk, menuScanDevices
    case menuCopyActivity, menuClearActivity

    // Zonas de soltar
    case dropProgramTitle, dropProgramSubtitle, dropArchiveTitle, dropArchiveSubtitle
    case dropApkTitle, dropApkSubtitle

    // Ficha de archivo
    case revealInFinder, removeFile, chooseAnotherProgram, chooseAnotherArchive

    // Opciones de extracción
    case saveIn, change, automatic, ownFolder, ownFolderHint
    case password, passwordHint, passwordNone, ifExists, whenDone, whenDoneHint
    case policySkip, policyRename, policyOverwrite
    case policySkipWhy, policyRenameWhy, policyOverwriteWhy

    // Acciones
    case extract, extracting, run, running, stop, preparingWindows
    case installingApk, openApp, uninstall, uninstalling

    // Barra de estado
    case readyToExtract, readyToRun, chooseArchiveFirst, chooseProgramFirst
    case missingExtractorShort, missingWineShort, wineBlockedShort
    case extractingProgress, extractingNoProgress, doneOpenFolder, programIsOpen

    // Actividad
    case activity, copyActivity, clearActivity, activityEmpty, allReady

    // Avisos
    case errorTitle, missingWineTitle, missingWineBody, howToInstall
    case wineBlockedTitle, wineBlockedBody, unblockWine, unblocking
    case rosettaTitle, rosettaBody
    case missingExtractorTitle, missingExtractorBody, install
    case installingTitle, installingBody

    // Tarjeta de Wine
    case windowsCardTitle, windowsCardBody, wineSettings, closeAll, resetWindows, otherWine
    case wineDisclaimer, programWillOpen
    case windowsSteamTitle, windowsSteamBody, windowsSteamOpen, windowsSteamOpening
    case windowsSteamMissing, windowsSteamStarted
    case steamGamesNone, steamGamePlay, steamGameOpening, steamGameOptions
    case steamGamePickExecutable, steamGameUseSteam, steamGamePickHint
    case steamGameNoExecutables, steamGameViaExecutable, steamGameExecutableChosen
    case wineSyncShared, wineSyncMismatch, wineSyncUnreadable
    case updateTitle, updateBody, updateNow, updateLater, updateInstalling
    case updateStarted, updateScriptMissing

    // Hechos del archivo
    case contentsReading, contentsItems, contentsAndMore, willOpenWith, willOpenWithWhy
    case originalUntouched, archiveEncrypted, archiveMultipart

    // Hechos del programa
    case arch64, arch32, archArm, archUnknown, arch32Warning, arch32Title

    // Juegos hechos con Godot
    case portableTitle, portableBodyGodot, portableMakeApp, portablePorting, portableWhereItGoes
    case portablePartsNeeded, portableBuildParts, recipeGozen, portablePartUnknown
    case portableUnsupportedGodot, portableRuntimeCached, portableRuntimeDownload
    case portableBodyRenpy, portableUnsupportedRenpy, portableRosettaNote
    case portableBodyLove, portableUnsupportedLove
    case portableBodyNwjs, portableUnsupportedNwjs, portableNwjsNewerEngine
    case portableBodyJava, portableUnsupportedJava
    case portableBodyElectron, portableUnsupportedElectron
    case portStageReading, portStageDownloading, portStageUnpacking
    case portStageBuilding, portStageAssembling, portStageSigning
    case logPortableDetected, logPorted, logPortUnresolved
    case errPortEngine, errPortNoSpace, errPortDownload, errPortRuntime, errPortAssembly
    case statusPorting, statusPortDone

    // Android: hechos del .apk
    case apkMinAndroid, apkMinApi, apkNoNativeCode
    case apkSplitTitle, apkSplitBody, apkUnreadableTitle, apkUnreadableBody

    // Emulación: máquinas, ROMs y controles
    case tabEmulation, dropRomTitle, dropRomSubtitle, menuOpenRom
    case archBits8, archBits16, archBits32, archBits64, archDualScreen, archHybrid
    case romEvidenceHeader, romEvidenceExtension, romEvidenceNone
    case romUnknownTitle, romUnknownBody, romNeedsBiosTitle, romNeedsBiosBody
    case romTouchTitle, romTouchBody
    case retroMissingTitle, retroMissingBody, retroCardTitle, retroCardBody
    case retroCoreSection, retroCoreCached, retroCoreToDownload, retroArchNote
    case controlsSection, controlsProfile, controlsEdit, controlsScopeGlobal
    case controlsScopePlatform, controlsScopeGame, controlsSaveHere, controlsReset
    case controlsPressPrompt, controlsUnassigned, controlsListening, controlsGamepads
    case controlsNoGamepad, controlsKeyboardTab, controlsGamepadTab
    case controlsButton, controlsAxis, controlsHat, controlsGamepadHint
    case retroSessionSection, retroFullscreen, retroFullscreenNote
    case retroResume, retroResumeNote
    case playRom, playingRom, statusGettingCore, statusLaunchingRetro
    case errNoRetroArch, errNoCore, errUnknownRom, errPickRom, emulationDisclaimer

    // La consola híbrida: paquetes, contenidos y llaves
    case contentKindApplication, contentKindPatch, contentKindAddOn, contentKindOther
    case switchEvidenceNca, switchEvidenceTicket, switchEvidenceXml, switchEvidenceContainer
    case switchSection, switchTitles, switchNoTitles, switchVersion
    case switchCompressedTitle, switchCompressedBody
    case switchKeysSection, switchKeysMissingTitle, switchKeysMissingBody
    case switchKeysFound, switchKeysChoose, switchKeysForget, switchKeysGenerations
    case switchEmulatorSection, switchEmulatorMissingTitle, switchEmulatorMissingBody
    case switchEmulatorFound, switchEmulatorChoose
    case dropSwitchSubtitle, switchDisclaimer
    case switchCartridgeFirmwareIncluded, switchCartridgeTrimmed
    case switchCartridgeSection, switchCartridgeTrimmedTitle
    case inputSection, inputKindKeyboard, inputKindGamepad
    case inputNone, inputUnknown, inputPadNotConfigured, inputSlotNote
    case displayModeSection, displayModeDocked, displayModeHandheld
    case displayModeSwitchTo, displayModeNote, displayModeRunning, displayModeFailed
    case switchRebuildTitle, switchRebuildBody, switchCacheNote, switchKeysTooOld
    case switchCartridgeNote

    // Los controles de la consola híbrida, que Lever sí escribe
    case menuSwitchControls, switchControlsTitle, switchControlsSubtitle
    case switchControlsScopeGlobal, switchControlsScopeGame
    case switchFaceSection, switchFaceByPosition, switchFaceByLabel, switchFaceNote
    case switchControlsPadColumn, switchControlsKeyColumn, switchControlsPickPad
    case switchControlsListening, switchControlsNoPad, switchControlsPadFrom
    case switchControlsSave, switchControlsReset, switchControlsApplyNote
    case switchControlsApplied, switchControlsNoPadId, switchControlsEmulatorOpen
    case switchKeyboardMouse, switchGamepad, switchInputChoice, switchMouseHint
    case switchMouseSensitivity, switchMouseInvert, switchDesktopPreset, switchControlsSaved
    case switchMouseUnavailable, switchInputTemplateMissing, switchMouseFailed, switchMouseReady
    case switchMouseInvalidSettings
    case switchMouseLimit
    case switchQualityTitle, switchQualityScale, switchQualityUnknown, switchQualityLowerUnsupported
    case switchQualityNative, switchQualityBalanced, switchQualityPerformance, switchQualityResolution
    case switchQuality150, switchQuality200
    case switchQualityFilter, switchQualityNote, switchQualityFailed, switchQualityApplied
    case switchControlsUnreadable, switchControlsFailed, switchControlsAppliedToGame

    // Máquinas que ejecuta un programa aparte: madurez y firmware
    case maturitySolid, maturityExperimental, maturityNone
    case firmwareFromConsole, firmwareFromVendor

    // La familia PlayStation
    case psEvidenceParamSfo, psEvidencePackage, psEvidenceBoot, psEvidenceLayout
    case psSection, psTitleId, psContainerFolder, psContainerDisc, psContainerPackage
    case psNoEmulatorTitle, psNoEmulatorBody, psFirmwareTitle, psFirmwareBody
    case psFirmwareReady, psExperimentalTitle, psExperimentalBody
    case psUseRetroArchTitle, psUseRetroArchBody, dropPlayStationSubtitle
    case menuOpenFolder, errNoPsEmulator
    case statusRebuildingPackage, statusLaunchingEmulator, logPackageRebuilt
    case errNoSwitchEmulator, errNoZstd, errRebuildFailed, errKeysUnusable
    case errBrokenSwitchPackage

    // Android: los formatos que envuelven varios .apk
    case bundleKindXapk, bundleKindApks, bundleKindAab
    case bundleParts, bundleExpansions, bundleModules, bundleUnreadableTitle, bundleUnreadableBody
    case bundleToolsTitle, bundleToolsBody, apkUnsignedTitle, apkUnsignedBody
    case toolJava, toolBundletool, toolApkSigner
    case statusUnpackingBundle, statusSigningApk, statusBuildingApks
    case statusInstallingParts, statusPushingExpansion, statusGettingAndroidTool
    case logApkSigned, logPartsInstalled, logExpansionsPushed
    case errAndroidToolMissing, errBundleUnreadable

    // Android: aparatos y emuladores
    case deviceSection, deviceScanning, deviceRefresh, deviceNoneTitle, deviceNoneBody
    case deviceUnauthorized, deviceOffline, deviceEmulator, devicePhone, deviceAndroidVersion
    case emulatorSection, emulatorStart, emulatorStarting, emulatorNone, emulatorHint

    // Android: compatibilidad y avisos
    case abiMismatchTitle, abiMismatchBody, sdkTooOldTitle, sdkTooOldBody
    case missingAdbTitle, missingAdbBody, androidCardTitle, androidCardBody, androidDisclaimer
    case chooseApkFirst, readyToInstall, missingAdbShort, noDeviceShort, apkInstalledOn

    // Android: orientación de la pantalla
    case orientationSection, orientationAuto, orientationPortrait, orientationLandscape
    case orientationFree, orientationDeclared, orientationRuntimeWarning

    // Android: montar el emulador
    case emulatorSetUp, emulatorSettingUp, emulatorSetUpTitle, emulatorSetUpBody
    case emulatorSetUpSize, emulatorNoSpace, emulatorReady
    case runApk, runningApk, openAgain
    case logRotated, logEmulatorReady, statusApkRunning
    case errEmulatorTimeout, errEmulatorSetUpFailed, errEmulatorScriptMissing

    // Abiertos hace poco
    case recentsTitle, recentsClear, recentsReopen, recentsRename, recentsRenameHint
    case recentsMove, recentsForget, recentsMissing
    case errRenameEmpty, errNameTaken, errRenameFailed, errRecentMissing
    case logRenamed, logMoved

    // Android: hoja de ayuda
    case androidHelpTitle, androidHelpBody, androidHelpFootnote
    case androidOptionPhone, androidOptionPhoneWhy
    case androidOptionEmulator, androidOptionEmulatorWhy
    case androidOptionStudio, androidOptionStudioWhy

    // Hoja de ayuda de Wine
    case wineHelpTitle, wineHelpBody, wineHelpFootnote, copyCommand, close, findWineOnMac
    case wineOptionGptk, wineOptionGptkWhy, wineOptionCrossover, wineOptionCrossoverWhy
    case wineOptionExisting, wineOptionExistingWhy

    // Mensajes del registro y errores (algunos llevan %@)
    case logProgramChosen, logArchiveChosen, logDestination, logToolsFound, logNoTools
    case logExtracting, logExtractedTo, logOriginalKept, logStopped, logStopping
    case logRetryingWith, logFirstRun, logWindowsReady, logProgramClosed
    case logWineChosen, logCommandCopied, logActivityCopied, logExtractorsPresent
    case logInstalling, logInstallTakesTime, logInstallDone, logWindowsReset, logWineUnblocked
    case logApkChosen, logDevicesFound, logNoDevices, logInstallingApk, logApkInstalled
    case logApkLaunched, logApkUninstalled, logEmulatorStarting
    case errNotAProgram, errNotAnArchive, errUnknownFile, errNoWine, errNoExtractor
    case errPickProgram, errPickArchive, errPickDestination, errCannotCreateFolder
    case errWineBlocked, errNoRosetta, errWinePrefixFailed, errUnblockFailed
    case errNotWineExecutable, errProgramExit, errExtractExit2, errExtractExit1, errExtractExitOther
    case errBusy, errHomebrewMissing, errInstallFailed
    case errNotAnApk, errNoAdb, errNoDevice, errPickApk, errDeviceUnauthorized
    case errInstallNoAbis, errInstallOldSdk, errInstallSignature, errInstallDowngrade
    case errInstallNoSpace, errInstallNotSigned, errInstallBlocked, errInstallOther, errNoLauncher
    case statusFinished, statusStopped, statusExtracted, statusFailed, statusCannotStart
    case statusExtracting, statusRunning, statusInstalling, statusToolsInstalled
    case statusWindowsReset, statusWineUnblocked, statusPreparing, statusWindowsFailed
    case statusInstallingApk, statusApkInstalled, statusApkUninstalled, statusScanning
    case statusEmulatorStarting
}
