import Darwin
import Foundation

@main
struct ExeRarTests {
    static func main() async {
        do {
            try LocalizationTests.run()
            try ProgramInspectorTests.run()
            try RuntimeLocatorTests.run()
            try CommandBuilderTests.run()
            try await ProcessRunnerTests.run()
            try AppModelTests.run()
            try await ExtractionIntegrationTests.run()
            print("PASS LocalizationTests")
            print("PASS ProgramInspectorTests")
            print("PASS RuntimeLocatorTests")
            print("PASS CommandBuilderTests")
            print("PASS ProcessRunnerTests")
            print("PASS AppModelTests")
            print("PASS ExtractionIntegrationTests")
        } catch {
            fputs("FAIL ExeRarTests: \(error)\n", stderr)
            exit(1)
        }
    }
}
