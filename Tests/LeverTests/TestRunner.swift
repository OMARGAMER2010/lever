import Darwin
import Foundation

@main
struct LeverTests {
    static func main() async {
        do {
            try LocalizationTests.run()
            try ProgramInspectorTests.run()
            try ApkInspectorTests.run()
            try AndroidCommandTests.run()
            try RuntimeLocatorTests.run()
            try CommandBuilderTests.run()
            try await ProcessRunnerTests.run()
            try AppModelTests.run()
            try await ExtractionIntegrationTests.run()
            print("PASS LocalizationTests")
            print("PASS ProgramInspectorTests")
            print("PASS ApkInspectorTests")
            print("PASS AndroidCommandTests")
            print("PASS RuntimeLocatorTests")
            print("PASS CommandBuilderTests")
            print("PASS ProcessRunnerTests")
            print("PASS AppModelTests")
            print("PASS ExtractionIntegrationTests")
        } catch {
            fputs("FAIL LeverTests: \(error)\n", stderr)
            exit(1)
        }
    }
}
