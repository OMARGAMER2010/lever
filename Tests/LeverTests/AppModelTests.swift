import Foundation
import LeverCore

@MainActor
enum AppModelTests {
    static func run() throws {
        try testNothingIsEnabledWithoutTools()
        try testActionsEnableWhenEverythingIsInPlace()
        try testDestinationIsSuggestedNextToTheArchive()
        try testDroppedFilesAreRoutedByExtension()
        try testMissingToolsAreReported()
        try testInstallIsOfferedOnlyWhenSomethingIsMissing()
        try testSwitchingLanguageChangesTextAndKeepsState()
        try testProgramArchitectureIsReadOnSelection()
        try testApkNeedsADeviceBeforeInstalling()
        try testAndroidBundlesAreAccepted()
    }

    private static func emptyModel() -> AppModel {
        AppModel(locator: RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [],
            adbCandidates: [],
            emulatorCandidates: []
        ))
    }

    /// Todo presente: Wine, extractor, Homebrew y `adb`. `/bin/echo` sirve de doble porque lo
    /// único que se comprueba aquí es que la app *encuentre* un ejecutable, no lo que hace.
    private static func readyModel() -> AppModel {
        let echo = URL(fileURLWithPath: "/bin/echo")
        return AppModel(locator: RuntimeLocator(
            wineCandidates: [echo],
            sevenZipCandidates: [echo],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [echo],
            adbCandidates: [echo],
            emulatorCandidates: []
        ))
    }

    private static func testNothingIsEnabledWithoutTools() throws {
        let model = emptyModel()
        try expect(!model.canRunProgram, "ejecutar debe estar desactivado sin Wine")
        try expect(!model.canExtractArchive, "extraer debe estar desactivado sin extractor")
        try expect(!model.canInstallTools, "instalar debe estar desactivado sin Homebrew")
    }

    private static func testActionsEnableWhenEverythingIsInPlace() throws {
        let model = readyModel()
        let fixture = try TemporaryFixture()
        model.selectedProgram = try fixture.makeFile(named: "Instalador.EXE")
        model.selectedArchive = try fixture.makeFile(named: "Paquete.RAR")

        try expect(model.canRunProgram, "ejecutar debe activarse con programa y Wine")
        try expect(model.canExtractArchive, "extraer debe activarse con comprimido y extractor")
        try expect(!model.canInstallTools,
                   "si los extractores ya están, el botón de instalar no debe ofrecerse")
    }

    /// El botón de instalar solo aparece cuando hay Homebrew Y falta algo que instalar.
    private static func testInstallIsOfferedOnlyWhenSomethingIsMissing() throws {
        let echo = URL(fileURLWithPath: "/bin/echo")
        let withBrewNoExtractor = AppModel(locator: RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [echo],
            adbCandidates: [],
            emulatorCandidates: []
        ))
        try expect(withBrewNoExtractor.canInstallTools,
                   "con Homebrew y sin extractor, instalar debe estar disponible")
        try expect(withBrewNoExtractor.missingFormulae == ["sevenzip", "unar", "android-platform-tools"],
                   "sin nada instalado, se ofrecen los extractores y adb")

        // Con los extractores puestos pero sin `adb`, sigue habiendo algo que instalar: el botón
        // ya no es solo de extractores.
        let onlyAdbMissing = AppModel(locator: RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [echo],
            unarCandidates: [echo],
            unrarCandidates: [],
            homebrewCandidates: [echo],
            adbCandidates: [],
            emulatorCandidates: []
        ))
        try expect(onlyAdbMissing.missingFormulae == ["android-platform-tools"],
                   "si solo falta adb, solo se instala adb")

        let noBrew = AppModel(locator: RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [],
            adbCandidates: [],
            emulatorCandidates: []
        ))
        try expect(!noBrew.canInstallTools, "sin Homebrew no se puede instalar nada")
    }

    private static func testDestinationIsSuggestedNextToTheArchive() throws {
        let model = readyModel()
        let fixture = try TemporaryFixture()
        let archive = try fixture.makeFile(named: "Mis Fotos.rar")
        model.selectedArchive = archive

        model.extractIntoSubfolder = true
        let subfolder = fixture.directoryURL.appendingPathComponent("Mis Fotos", isDirectory: true)
        try expect(
            model.effectiveDestination?.standardizedFileURL == subfolder.standardizedFileURL,
            "el destino sugerido debe ser una carpeta hermana con el nombre del comprimido"
        )

        model.extractIntoSubfolder = false
        try expect(
            model.effectiveDestination?.standardizedFileURL == fixture.directoryURL.standardizedFileURL,
            "sin subcarpeta, el destino debe ser la carpeta del comprimido"
        )

        let manual = fixture.directoryURL.appendingPathComponent("Otro sitio", isDirectory: true)
        model.chosenDestination = manual
        try expect(
            model.effectiveDestination == manual,
            "un destino elegido a mano debe tener prioridad sobre el sugerido"
        )
    }

    private static func testDroppedFilesAreRoutedByExtension() throws {
        let model = readyModel()
        let fixture = try TemporaryFixture()
        let program = try fixture.makeFile(named: "juego.exe")
        let archive = try fixture.makeFile(named: "datos.zip")
        let apk = try fixture.makeFile(named: "app.apk")
        let unknown = try fixture.makeFile(named: "notas.txt")

        try expect(model.accept(droppedURLs: [program, archive, apk]), "debe aceptar los tres tipos")
        try expect(model.selectedProgram == program, "el .exe debe ir a la sección de programas")
        try expect(model.selectedArchive == archive, "el .zip debe ir a la sección de comprimidos")
        try expect(model.selectedApk == apk, "el .apk debe ir a la sección de Android")
        try expect(!model.accept(droppedURLs: [unknown]), "un .txt no debe aceptarse")
        try expect(model.lastError != nil, "soltar algo no admitido debe explicar el motivo")
    }

    private static func testMissingToolsAreReported() throws {
        let empty = emptyModel()
        try expect(empty.missingTools.count == 3, "sin herramientas deben faltar las tres")
        try expect(empty.missingTools.contains("Wine"), "Wine debe aparecer entre lo que falta")
        try expect(empty.missingTools.contains("adb"), "adb debe aparecer entre lo que falta")
        try expect(readyModel().missingTools.isEmpty, "sin nada que falte, la lista debe estar vacía")
    }

    /// Cambiar de idioma debe cambiar el texto de verdad, sin perder lo que hubiera elegido.
    private static func testSwitchingLanguageChangesTextAndKeepsState() throws {
        let model = readyModel()
        let fixture = try TemporaryFixture()
        let archive = try fixture.makeFile(named: "Paquete.rar")
        model.selectedArchive = archive

        model.language = .spanish
        let spanish = model.strings[.extract]
        model.language = .english
        let english = model.strings[.extract]

        try expect(spanish != english, "el texto debe cambiar al cambiar de idioma")
        try expect(english == "Extract", "en inglés el botón dice Extract")
        try expect(model.selectedArchive == archive, "cambiar de idioma no debe perder el archivo elegido")
    }

    /// La app lee la cabecera del .exe y avisa si el Wine disponible no podrá con él.
    private static func testProgramArchitectureIsReadOnSelection() throws {
        let model = readyModel()
        let fixture = try TemporaryFixture()
        model.selectedProgram = try fixture.makeFile(named: "cualquiera.exe")
        try expect(model.programArchitecture == .unknown,
                   "un archivo que no es PE debe quedar como desconocido, no inventarse nada")
        try expect(!model.programWontRunOnThisWine,
                   "sin saber la arquitectura no se avisa de nada")
    }

    /// Un `.apk` no se ejecuta en el Mac: hace falta un aparato. Sin él, instalar no se activa
    /// aunque estén el archivo y `adb`.
    private static func testApkNeedsADeviceBeforeInstalling() throws {
        let model = readyModel()
        let fixture = try TemporaryFixture()
        model.selectedApk = try fixture.makeFile(named: "app.apk")

        try expect(!model.canRunApk, "sin aparato ni emulador creado no se puede ejecutar")
        try expect(!model.canLaunchApk, "sin haber instalado nada no hay app que abrir")

        let noAdb = AppModel(locator: RuntimeLocator(
            wineCandidates: [], sevenZipCandidates: [], unarCandidates: [],
            unrarCandidates: [], homebrewCandidates: [], adbCandidates: [], emulatorCandidates: []
        ))
        noAdb.selectedApk = model.selectedApk
        try expect(!noAdb.canRunApk, "sin adb tampoco")

        // En automático la postura sale del .apk; el conmutador manda sobre ella.
        try expect(model.effectiveOrientation == model.apkFacts.orientation,
                   "en automático manda lo que declara el .apk")
        model.rotationChoice = .landscape
        try expect(model.effectiveOrientation == .landscape, "elegir a mano gana")
        model.rotationChoice = .automatic
    }

    /// Los cuatro formatos entran por la misma puerta. Antes se rechazaban con un aviso que
    /// mandaba al usuario a buscarse la vida; ahora se aceptan y se desmontan.
    private static func testAndroidBundlesAreAccepted() throws {
        let fixture = try TemporaryFixture()

        for nombre in ["juego.xapk", "juego.apks", "juego.aab", "juego.apkm"] {
            let model = readyModel()
            let paquete = try fixture.makeFile(named: nombre)
            try expect(model.accept(droppedURLs: [paquete]), "\(nombre) debe aceptarse")
            try expect(model.selectedApk == paquete, "\(nombre) queda elegido")
            try expect(model.lastError == nil, "aceptarlo no es un error: \(model.lastError ?? "")")
        }

        let model = readyModel()
        let ajeno = try fixture.makeFile(named: "cosa.qqq")
        try expect(!model.accept(droppedURLs: [ajeno]), "lo que no es de nadie se sigue rechazando")
    }
}
