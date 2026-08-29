import Foundation
import LeverCore

enum ProcessRunnerTests {
    static func run() async throws {
        try await testProcessRunnerCapturesOutputAndExitCode()
        try await testProcessRunnerReportsNonZeroExitCode()
    }

    private static func testProcessRunnerCapturesOutputAndExitCode() async throws {
        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello from process"],
            currentDirectoryURL: nil
        )

        let result = try await ProcessRunner().run(command)

        try expect(result.exitCode == 0, "echo should exit successfully")
        try expect(result.output.contains("hello from process"), "process output should be captured")
    }

    private static func testProcessRunnerReportsNonZeroExitCode() async throws {
        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            currentDirectoryURL: nil
        )

        let result = try await ProcessRunner().run(command)

        try expect(result.exitCode != 0, "false should report a non-zero exit code")
    }
}
