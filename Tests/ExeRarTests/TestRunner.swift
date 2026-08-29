import Darwin
import Foundation

@main
struct ExeRarTests {
    static func main() async {
        do {
            try RuntimeLocatorTests.run()
            try CommandBuilderTests.run()
            try await ProcessRunnerTests.run()
            try AppModelTests.run()
            print("PASS RuntimeLocatorTests")
            print("PASS CommandBuilderTests")
            print("PASS ProcessRunnerTests")
            print("PASS AppModelTests")
        } catch {
            fputs("FAIL ExeRarTests: \(error)\n", stderr)
            exit(1)
        }
    }
}
