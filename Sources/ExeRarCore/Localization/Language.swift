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
    case tabPrograms, tabArchives, toolWine, toolExtractor, toolNotInstalled, languageMenu

    // Menú de herramientas
    case menuTools, menuRefresh, menuInstallExtractors, menuFindWine, menuForgetWine
    case menuUnblockWine, menuResetWindows, menuOpenWindowsFolder
    case menuOpenProgram, menuOpenArchive, menuCopyActivity, menuClearActivity

    // Zonas de soltar
    case dropProgramTitle, dropProgramSubtitle, dropArchiveTitle, dropArchiveSubtitle

    // Ficha de archivo
    case revealInFinder, removeFile, chooseAnotherProgram, chooseAnotherArchive

    // Opciones de extracción
    case saveIn, change, automatic, ownFolder, ownFolderHint
    case password, passwordHint, passwordNone, ifExists, whenDone, whenDoneHint
    case policySkip, policyRename, policyOverwrite
    case policySkipWhy, policyRenameWhy, policyOverwriteWhy

    // Acciones
    case extract, extracting, run, running, stop, preparingWindows

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

    // Hechos del archivo
    case contentsReading, contentsItems, contentsAndMore, willOpenWith, willOpenWithWhy
    case originalUntouched, archiveEncrypted, archiveMultipart

    // Hechos del programa
    case arch64, arch32, archArm, archUnknown, arch32Warning, arch32Title

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
    case errNotAProgram, errNotAnArchive, errUnknownFile, errNoWine, errNoExtractor
    case errPickProgram, errPickArchive, errPickDestination, errCannotCreateFolder
    case errWineBlocked, errNoRosetta, errWinePrefixFailed, errUnblockFailed
    case errNotWineExecutable, errProgramExit, errExtractExit2, errExtractExit1, errExtractExitOther
    case errBusy, errHomebrewMissing, errInstallFailed
    case statusFinished, statusStopped, statusExtracted, statusFailed, statusCannotStart
    case statusExtracting, statusRunning, statusInstalling, statusToolsInstalled
    case statusWindowsReset, statusWineUnblocked, statusPreparing, statusWindowsFailed
}
