import Foundation
import ExeRarCore

@MainActor
enum AppModelTests {
    static func run() throws {
        let emptyLocator = RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: []
        )
        let emptyModel = AppModel(locator: emptyLocator)

        try expect(!emptyModel.canRunExe, "EXE execution should be disabled without a Wine runtime")
        try expect(!emptyModel.canExtractArchive, "RAR extraction should be disabled without an archive tool")

        let echo = URL(fileURLWithPath: "/bin/echo")
        let availableLocator = RuntimeLocator(
            wineCandidates: [echo],
            sevenZipCandidates: [echo],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [echo]
        )
        let model = AppModel(locator: availableLocator)
        let fixture = try TemporaryFixture()
        model.selectedExe = try fixture.makeFile(named: "Installer.EXE")
        model.selectedArchive = try fixture.makeFile(named: "Archive.RAR")
        model.extractionDestination = fixture.directoryURL.appendingPathComponent("Extracted Files")
        try FileManager.default.createDirectory(at: model.extractionDestination!, withIntermediateDirectories: true)

        try expect(model.canRunExe, "EXE execution should enable with a selected EXE and Wine")
        try expect(model.canExtractArchive, "RAR extraction should enable with archive, destination, and extractor")

        model.isBusy = true
        try expect(!model.canRunExe, "EXE execution should disable while another process is running")
        try expect(!model.canExtractArchive, "RAR extraction should disable while another process is running")
    }
}
