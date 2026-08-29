import Foundation
import ExeRarCore

@MainActor
enum AppModelTests {
    static func run() throws {
        try testNothingIsEnabledWithoutTools()
        try testActionsEnableWhenEverythingIsInPlace()
        try testDestinationIsSuggestedNextToTheArchive()
        try testDroppedFilesAreRoutedByExtension()
        try testMissingToolsAreReported()
        try testInstallIsOfferedOnlyWhenSomethingIsMissing()
    }

    private static func emptyModel() -> AppModel {
        AppModel(locator: RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: []
        ))
    }

    private static func readyModel() -> AppModel {
        let echo = URL(fileURLWithPath: "/bin/echo")
        return AppModel(locator: RuntimeLocator(
            wineCandidates: [echo],
            sevenZipCandidates: [echo],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [echo]
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
            homebrewCandidates: [echo]
        ))
        try expect(withBrewNoExtractor.canInstallTools,
                   "con Homebrew y sin extractor, instalar debe estar disponible")

        let noBrew = AppModel(locator: RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: []
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
        let unknown = try fixture.makeFile(named: "notas.txt")

        try expect(model.accept(droppedURLs: [program, archive]), "debe aceptar programa y comprimido")
        try expect(model.selectedProgram == program, "el .exe debe ir a la sección de programas")
        try expect(model.selectedArchive == archive, "el .zip debe ir a la sección de comprimidos")
        try expect(!model.accept(droppedURLs: [unknown]), "un .txt no debe aceptarse")
        try expect(model.lastError != nil, "soltar algo no admitido debe explicar el motivo")
    }

    private static func testMissingToolsAreReported() throws {
        try expect(emptyModel().missingTools == ["Wine", "un extractor"], "debe listar lo que falta")
        try expect(readyModel().missingTools.isEmpty, "sin nada que falte, la lista debe estar vacía")
    }
}
