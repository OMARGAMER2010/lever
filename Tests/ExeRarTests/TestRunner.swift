import Darwin
import Foundation

@main
struct ExeRarTests {
    static func main() {
        do {
            try RuntimeLocatorTests.run()
            print("PASS RuntimeLocatorTests")
        } catch {
            fputs("FAIL RuntimeLocatorTests: \(error)\n", stderr)
            exit(1)
        }
    }
}
