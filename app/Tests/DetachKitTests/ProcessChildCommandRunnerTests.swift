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

    func testPOSIXLauncherPreservesParentProcessGroup() throws {
        let launcher = POSIXChildProcessLauncher()
        var environment = ProcessInfo.processInfo.environment
        environment["DETACH_EXPECTED_PROCESS_GROUP"] = String(getpgrp())

        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                actual=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d '[:space:]')
                test "$actual" = "$DETACH_EXPECTED_PROCESS_GROUP"
                """,
            ],
            environment: environment,
            currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            inheritsStandardIO: false))

        XCTAssertEqual(exitCode, 0)
    }

    func testPOSIXLauncherPassesEnvironmentAndCurrentDirectory() throws {
        let launcher = POSIXChildProcessLauncher()
        let currentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: currentDirectory)
        }

        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                test "$(/bin/pwd -P)" = "$DETACH_EXPECTED_CWD"
                test "$DETACH_SENTINEL" = "preserved"
                """,
            ],
            environment: [
                "DETACH_EXPECTED_CWD": currentDirectory.path,
                "DETACH_SENTINEL": "preserved",
            ],
            currentDirectoryURL: currentDirectory,
            inheritsStandardIO: false))

        XCTAssertEqual(exitCode, 0)
    }

    func testPOSIXLauncherMapsSignalTerminationToShellExitCode() throws {
        let launcher = POSIXChildProcessLauncher()

        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            inheritsStandardIO: false))

        XCTAssertEqual(exitCode, 128 + SIGTERM)
    }

    func testPOSIXLauncherPublishesTheExactProviderPIDAtomically() throws {
        let launcher = POSIXChildProcessLauncher()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("provider.pid")
        let observedFile = directory.appendingPathComponent("observed.pid")

        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while [ ! -s \"$1\" ]; do sleep 0.01; done; cp \"$1\" \"$2\"; test \"$(cat \"$1\")\" = \"$$\"", "sh", pidFile.path, observedFile.path],
            environment: ProcessInfo.processInfo.environment,
            currentDirectoryURL: directory,
            inheritsStandardIO: false,
            pidFile: pidFile.path))

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: pidFile, encoding: .utf8),
            try String(contentsOf: observedFile, encoding: .utf8))
    }
}
