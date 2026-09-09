import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class DetachCLITests: XCTestCase {
    func fixture(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-detach")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testCapturesStdoutAndExitCode() async throws {
        let cli = ProcessDetachCLI(executable: try fixture(#"printf '%s\n' "$@"; echo err >&2; exit 3"#))
        let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "list\n--json\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
    }

    func testReportsEachTruncatedStream() async throws {
        let cli = ProcessDetachCLI(
            executable: try fixture("printf 123456789; printf abcdefghi >&2"),
            maximumOutputBytes: 5)

        let result = try await cli.run(arguments: [], timeout: 5)

        XCTAssertEqual(result.stdout, "12345")
        XCTAssertEqual(result.stderr, "abcde")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
    }

    func testUsesAnExplicitWorkingDirectory() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("detach-cli-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = ProcessDetachCLI(executable: try fixture("pwd -P"))

        let result = try await cli.run(
            arguments: [],
            timeout: 5,
            currentDirectoryURL: directory)

        XCTAssertEqual(result.exitCode, 0)
        let reportedDirectory = result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: reportedDirectory).lastPathComponent,
            directory.lastPathComponent)
        XCTAssertNotEqual(reportedDirectory, FileManager.default.currentDirectoryPath)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let cli = ProcessDetachCLI(executable: try fixture("dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\\0' 'x'"))
        let result = try await cli.run(arguments: [], timeout: 10)
        XCTAssertEqual(result.stdout.count, 512 * 1024)
    }

    func testConcurrentRunsDoNotStarveOutputDrains() async throws {
        let cli = ProcessDetachCLI(executable: try fixture("printf ready"))

        let results = try await withThrowingTaskGroup(
            of: CLIResult.self,
            returning: [CLIResult].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cli.run(arguments: [], timeout: 2)
                }
            }
            var results: [CLIResult] = []
            for try await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy {
            $0.exitCode == 0
                && $0.stdout == "ready"
                && !$0.timedOut
                && !$0.stdoutTruncated
                && !$0.stderrTruncated
        })
    }

    func testAddsCommonExecutablePathsToSparseGUIEnvironment() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-home-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let helper = bin.appendingPathComponent("gui-path-helper")
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let cli = ProcessDetachCLI(
            executable: try fixture("command -v gui-path-helper"),
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let result = try await cli.run(arguments: [], timeout: 5)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), helper.path)
    }

    func testInheritedGUIEnvironmentRemovesDetachRuntimeOverrides() throws {
        let environment = ProcessDetachCLI.runtimeEnvironment([
            "HOME": "/private/tmp/detach-cli-home",
            "PATH": "/usr/bin:/bin",
            "DETACH_STATE_BIN": "/old/detach-state",
            "DETACH_POWER_BIN": "/old/detach-power",
            "DETACH_TMUX_BIN": "/old/tmux",
            "DETACH_CODEX_BIN": "/old/codex",
            "DETACH_STATE_ROOT": "/old/state",
            "DETACH_UI_E2E_ROOT": "/private/tmp/detach-ui-e2e.fixture",
            "UNRELATED_SETTING": "kept",
        ], allowsDetachOverrides: false)

        XCTAssertNil(environment["DETACH_STATE_BIN"])
        XCTAssertNil(environment["DETACH_POWER_BIN"])
        XCTAssertNil(environment["DETACH_TMUX_BIN"])
        XCTAssertNil(environment["DETACH_CODEX_BIN"])
        XCTAssertNil(environment["DETACH_STATE_ROOT"])
        XCTAssertEqual(
            environment["DETACH_UI_E2E_ROOT"],
            "/private/tmp/detach-ui-e2e.fixture")
        XCTAssertEqual(environment["UNRELATED_SETTING"], "kept")
    }

    func testExplicitEnvironmentPreservesDetachTestOverrides() async throws {
        let cli = ProcessDetachCLI(
            executable: try fixture(#"printf '%s' "$DETACH_STATE_BIN""#),
            environment: [
                "HOME": "/private/tmp/detach-cli-home",
                "PATH": "/usr/bin:/bin",
                "DETACH_STATE_BIN": "/fixture/detach-state",
            ])

        let result = try await cli.run(arguments: [], timeout: 5)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "/fixture/detach-state")
    }

    func testFindsProviderInstalledByNVMFromGUIEnvironment() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-nvm-home-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let helperName = "detach-nvm-provider-\(UUID().uuidString)"
        let helper = bin.appendingPathComponent(helperName)
        try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let cli = ProcessDetachCLI(
            executable: try fixture("command -v \(helperName)"),
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let result = try await cli.run(arguments: [], timeout: 5)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), helper.path)
    }

    func testVersionManagerPathsUseSemanticNodeOrdering() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-semver-home-\(UUID().uuidString)")
        let root = home.appendingPathComponent(".nvm/versions/node")
        for version in ["v9.99.0", "v22.1.0-beta.2", "v22.1.0", "current"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(version).appendingPathComponent("bin"),
                withIntermediateDirectories: true)
        }

        let paths = try XCTUnwrap(ProcessDetachCLI.runtimeEnvironment([
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ])["PATH"]?.split(separator: ":").map(String.init))

        let stable = try XCTUnwrap(paths.firstIndex(of:
            root.appendingPathComponent("v22.1.0/bin").path))
        let prerelease = try XCTUnwrap(paths.firstIndex(of:
            root.appendingPathComponent("v22.1.0-beta.2/bin").path))
        let legacy = try XCTUnwrap(paths.firstIndex(of:
            root.appendingPathComponent("v9.99.0/bin").path))
        let invalid = try XCTUnwrap(paths.firstIndex(of:
            root.appendingPathComponent("current/bin").path))
        XCTAssertLessThan(stable, prerelease)
        XCTAssertLessThan(prerelease, legacy)
        XCTAssertLessThan(legacy, invalid)
    }

    func testTimeoutTerminatesProcess() async throws {
        let descendantPID = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-descendant-\(UUID().uuidString)")
        let cli = ProcessDetachCLI(executable: try fixture("""
        (trap '' TERM; while :; do sleep 1; done) &
        printf '%s\n' "$!" >"$1"
        trap '' TERM
        while :; do sleep 1; done
        """), terminationGrace: 0.1)
        let start = Date()
        // Parallel release builds can delay the fixture's first instruction.
        // Keep launch headroom while retaining a strict end-to-end deadline.
        let result = try await cli.run(
            arguments: [descendantPID.path], timeout: 2)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let pid = try XCTUnwrap(Int32(
            String(contentsOf: descendantPID, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = Darwin.kill(pid, SIGKILL) }
        XCTAssertTrue(waitForProcessExit(pid, timeout: 1))
    }

    func testInheritedOutputPipeCannotOutliveCompletedLeader() async throws {
        let descendantPID = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-pipe-owner-\(UUID().uuidString)")
        let cli = ProcessDetachCLI(executable: try fixture("""
        sleep 30 &
        printf '%s\n' "$!" >"$1"
        printf 'leader done\n'
        """))

        let start = Date()
        let result = try await cli.run(
            arguments: [descendantPID.path], timeout: 5)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "leader done\n")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let pid = try XCTUnwrap(Int32(
            String(contentsOf: descendantPID, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = Darwin.kill(pid, SIGKILL) }
        XCTAssertTrue(waitForProcessExit(pid, timeout: 1))
    }

    func testMissingBinaryThrows() async {
        let cli = ProcessDetachCLI(executable: URL(fileURLWithPath: "/nonexistent/detach"))
        do {
            _ = try await cli.run(arguments: [], timeout: 1)
            XCTFail("expected throw")
        } catch {}
    }

    func testSessionEventStreamUsesWatchDecodesAndEndsWithConsumer() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-watch-\(UUID().uuidString)")
        let cli = ProcessDetachCLI(executable: try fixture("""
        [ "$1" = watch ] && [ "$2" = --json ] || exit 9
        printf '%s\n' "$$" >'\(pidFile.path)'
        printf '%s\n' '{"schema":1,"event":"ready"}'
        sleep 0.05
        printf '%s\n' '{"schema":1,"event":"changed"}'
        exec /bin/sleep 30
        """))
        let events = Task {
            var iterator = cli.sessionEvents().makeAsyncIterator()
            return (try await iterator.next(), try await iterator.next())
        }
        let (ready, changed) = try await events.value
        XCTAssertEqual(ready, SessionEvent(event: .ready))
        XCTAssertEqual(changed, SessionEvent(event: .changed))
        let pid = try XCTUnwrap(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        XCTAssertTrue(waitForProcessExit(pid, timeout: 1))
    }

    func testSessionEventStreamRejectsInvalidOrFailedOutput() async throws {
        let invalid = ProcessDetachCLI(executable: try fixture("printf 'not-json\\n'"))
        var invalidIterator = invalid.sessionEvents().makeAsyncIterator()
        do {
            _ = try await invalidIterator.next()
            XCTFail("expected invalid event failure")
        } catch {
            XCTAssertEqual(error as? DetachCLIStreamError, .invalidEvent)
        }

        let failed = ProcessDetachCLI(executable: try fixture("exit 7"))
        var failedIterator = failed.sessionEvents().makeAsyncIterator()
        do {
            _ = try await failedIterator.next()
            XCTFail("expected event process failure")
        } catch {
            XCTAssertEqual(error as? DetachCLIStreamError, .exited(7))
        }
    }

    private func processExists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitForProcessExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while processExists(pid), Date() < deadline {
            usleep(10_000)
        }
        return !processExists(pid)
    }
}
