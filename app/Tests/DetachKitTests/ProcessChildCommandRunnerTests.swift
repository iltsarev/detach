import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class ProcessChildCommandRunnerTests: XCTestCase {
    private final class FakeLauncher: ChildProcessLaunching, @unchecked Sendable {
        var exitCode: Int32 = 0
        var error: Error?
        private(set) var requests: [ChildProcessRequest] = []

        func run(_ request: ChildProcessRequest) throws -> Int32 {
            requests.append(request)
            if let error { throw error }
            return exitCode
        }
    }

    private struct ExpectedFailure: Error {}

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

    func testRunnerPreservesPIDFileAndLauncherFailure() {
        let launcher = FakeLauncher()
        launcher.error = ExpectedFailure()
        let runner = ProcessChildCommandRunner(
            environment: [:],
            currentDirectoryURL: URL(fileURLWithPath: "/fixture/project"),
            launcher: launcher)

        XCTAssertThrowsError(try runner.run(ChildCommand(
            executable: "/fixture/provider",
            arguments: [],
            pidFile: "/fixture/provider.pid"))) { error in
                XCTAssertTrue(error is ExpectedFailure)
            }
        XCTAssertEqual(launcher.requests.first?.pidFile, "/fixture/provider.pid")
    }

    func testPOSIXLauncherPreservesParentProcessGroup() throws {
        let launcher = POSIXChildProcessLauncher()
        var environment = ProcessInfo.processInfo.environment
        environment["DETACH_EXPECTED_PROCESS_GROUP"] = String(getpgrp())

        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                "exit(getpgrp(0) == $ENV{DETACH_EXPECTED_PROCESS_GROUP} ? 0 : 1)",
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

    func testPOSIXLauncherReturnsOrdinaryNonzeroExitCode() throws {
        let exitCode = try POSIXChildProcessLauncher().run(ChildProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 37"],
            environment: [:],
            currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            inheritsStandardIO: false))

        XCTAssertEqual(exitCode, 37)
    }

    func testPOSIXLauncherReportsMissingExecutableAsPOSIXSpawnFailure() {
        let missingExecutable = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-missing-provider-\(UUID().uuidString)")
        XCTAssertThrowsError(try POSIXChildProcessLauncher().run(
            ChildProcessRequest(
                executableURL: missingExecutable,
                arguments: [],
                environment: [:],
                currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
                inheritsStandardIO: false))) { error in
                    let error = error as NSError
                    XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                    XCTAssertEqual(error.code, Int(ENOENT))
                    XCTAssertTrue(error.localizedDescription.contains("posix_spawn"))
                }
    }

    func testPOSIXLauncherReportsMissingCurrentDirectory() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-missing-cwd-\(UUID().uuidString)")
        XCTAssertThrowsError(try POSIXChildProcessLauncher().run(
            ChildProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: missingDirectory,
                inheritsStandardIO: false))) { error in
                    let error = error as NSError
                    XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                    XCTAssertEqual(error.code, Int(ENOENT))
                }
    }

    func testPOSIXLauncherKillsAndReapsChildWhenPIDPublicationFails() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-missing-\(UUID().uuidString)")
        let start = Date()

        XCTAssertThrowsError(try POSIXChildProcessLauncher().run(
            ChildProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: [:],
                currentDirectoryURL: URL(fileURLWithPath: "/", isDirectory: true),
                inheritsStandardIO: false,
                pidFile: missingDirectory.appendingPathComponent("provider.pid").path)))

        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            5,
            "PID publication failure must kill and reap instead of waiting for the child")
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
