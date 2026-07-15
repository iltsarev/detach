import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class ProcessChildCommandRunnerTests: XCTestCase {
    private final class FakeLauncher: ChildProcessLaunching, @unchecked Sendable {
        var exitCode: Int32 = 0
        private(set) var requests: [ChildProcessRequest] = []

        func run(_ request: ChildProcessRequest) throws -> Int32 {
            requests.append(request)
            return exitCode
        }
    }

    func testAbsoluteExecutableInheritsEnvironmentCWDAndStandardIO() throws {
        let launcher = FakeLauncher()
        launcher.exitCode = 91
        let cwd = URL(fileURLWithPath: "/fixture/project", isDirectory: true)
        let runner = ProcessChildCommandRunner(
            environment: ["PATH": "/fixture/bin", "SENTINEL": "kept"],
            currentDirectoryURL: cwd,
            launcher: launcher)

        let result = try runner.run(ChildCommand(
            executable: "/fixture/provider", arguments: ["--flag", "value"]))

        XCTAssertEqual(result.exitCode, 91)
        XCTAssertEqual(launcher.requests, [ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/fixture/provider"),
            arguments: ["--flag", "value"],
            environment: ["PATH": "/fixture/bin", "SENTINEL": "kept"],
            currentDirectoryURL: cwd,
            inheritsStandardIO: true)])
    }

    func testBareExecutableUsesEnvWithoutChangingArguments() throws {
        let launcher = FakeLauncher()
        let runner = ProcessChildCommandRunner(
            environment: ["PATH": "/fixture/bin"],
            currentDirectoryURL: URL(fileURLWithPath: "/fixture/project"),
            launcher: launcher)

        _ = try runner.run(ChildCommand(executable: "codex", arguments: ["exec", "task"]))

        XCTAssertEqual(launcher.requests.first?.executableURL.path, "/usr/bin/env")
        XCTAssertEqual(launcher.requests.first?.arguments, ["codex", "exec", "task"])
    }

    func testFoundationLauncherMapsSignalTerminationToShellExitCode() throws {
        let launcher = FoundationChildProcessLauncher()

        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            inheritsStandardIO: false))

        XCTAssertEqual(exitCode, 128 + SIGTERM)
    }
}
