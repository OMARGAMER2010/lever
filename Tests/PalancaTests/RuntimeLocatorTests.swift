import Foundation
import PalancaCore

enum RuntimeLocatorTests {
    static func run() throws {
        try testLocateChoosesFirstExecutableWineCandidate()
        try testLocateSkipsNonExecutableWineCandidate()
        try testLocatePrefersSevenZipOverUnarAndUnrar()
        try testLocateFindsHomebrewCandidate()
        try testResolveWineAppToWineBinary()
    }

    private static func testLocateChoosesFirstExecutableWineCandidate() throws {
        let fixture = try TemporaryFixture()
        let first = try fixture.makeExecutable(named: "wine-first")
        let second = try fixture.makeExecutable(named: "wine-second")
        let locator = RuntimeLocator(
            wineCandidates: [first, second],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: []
        )

        try expect(locator.locate().wineURL == first, "first executable Wine candidate should win")
    }

    private static func testLocateSkipsNonExecutableWineCandidate() throws {
        let fixture = try TemporaryFixture()
        let nonExecutable = try fixture.makeFile(named: "not-wine")
        let executable = try fixture.makeExecutable(named: "wine")
        let locator = RuntimeLocator(
            wineCandidates: [nonExecutable, executable],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: []
        )

        try expect(locator.locate().wineURL == executable, "non-executable Wine candidates should be skipped")
    }

    private static func testLocatePrefersSevenZipOverUnarAndUnrar() throws {
        let fixture = try TemporaryFixture()
        let sevenZip = try fixture.makeExecutable(named: "7zz")
        let unar = try fixture.makeExecutable(named: "unar")
        let unrar = try fixture.makeExecutable(named: "unrar")
        let locator = RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [sevenZip],
            unarCandidates: [unar],
            unrarCandidates: [unrar],
            homebrewCandidates: []
        )

        try expect(locator.locate().archiveTools == [.sevenZip(sevenZip), .unar(unar), .unrar(unrar)],
                   "se deben encontrar los tres extractores, en orden")
    }

    private static func testLocateFindsHomebrewCandidate() throws {
        let fixture = try TemporaryFixture()
        let brew = try fixture.makeExecutable(named: "brew")
        let locator = RuntimeLocator(
            wineCandidates: [],
            sevenZipCandidates: [],
            unarCandidates: [],
            unrarCandidates: [],
            homebrewCandidates: [brew]
        )

        try expect(locator.locate().homebrewURL == brew, "Homebrew candidate should be reported")
    }

    private static func testResolveWineAppToWineBinary() throws {
        let fixture = try TemporaryFixture()
        let app = try fixture.makeWineAppBundle()
        let binary = app.appendingPathComponent("Contents/Resources/wine/bin/wine")

        try expect(RuntimeLocator.resolveWineURL(app) == binary, "Wine app bundle should resolve to its binary")
    }
}
