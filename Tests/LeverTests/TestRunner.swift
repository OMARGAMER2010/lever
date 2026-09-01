import Darwin
import Foundation

@main
struct LeverTests {
    static func main() async {
        do {
            try LocalizationTests.run()
            try ProgramInspectorTests.run()
            try GodotTests.run()
            try RenpyTests.run()
            try LoveTests.run()
            try NwjsTests.run()
            try ElectronTests.run()
            try JavaTests.run()
            try ApkInspectorTests.run()
            try AndroidCommandTests.run()
            try AndroidBundleTests.run()
            try EmulationTests.run()
            try SwitchTests.run()
            try GamepadTests.run()
            try RuntimeLocatorTests.run()
            try CommandBuilderTests.run()
            try await ProcessRunnerTests.run()
            try AppModelTests.run()
            try RecentFilesTests.run()
            try await ExtractionIntegrationTests.run()
            try await SwitchIntegrationTests.run()
            print("PASS LocalizationTests")
            print("PASS ProgramInspectorTests")
            print("PASS GodotTests")
            print("PASS RenpyTests")
            print("PASS LoveTests")
            print("PASS NwjsTests")
            print("PASS ElectronTests")
            print("PASS JavaTests")
            print("PASS ApkInspectorTests")
            print("PASS AndroidCommandTests")
            print("PASS AndroidBundleTests")
            print("PASS EmulationTests")
            print("PASS SwitchTests")
            print("PASS GamepadTests")
            print("PASS RuntimeLocatorTests")
            print("PASS CommandBuilderTests")
            print("PASS ProcessRunnerTests")
            print("PASS AppModelTests")
            print("PASS RecentFilesTests")
            print("PASS ExtractionIntegrationTests")
            print("PASS SwitchIntegrationTests")
        } catch {
            fputs("FAIL LeverTests: \(error)\n", stderr)
            exit(1)
        }
    }
}
