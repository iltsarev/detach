import XCTest
@testable import DetachKit

final class FakeCLI: DetachCLIRunning, @unchecked Sendable {
    var responses: [String: Result<CLIResult, Error>] = [:]
    private(set) var calls: [[String]] = []

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        calls.append(arguments)
        let key = arguments.joined(separator: " ")
        guard let response = responses[key] else {
            return CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
        }
        return try response.get()
    }
}

struct FakeError: Error {}

private actor DelayedCLI: DetachCLIRunning {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<CLIResult, Never>?

    func run(
        arguments: [String], timeout: TimeInterval
    ) async throws -> CLIResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with result: CLIResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    let line = """
    {"schema":1,"provider":"codex","session_name":"detach-codex-p-1","name":"p-1","effective_status":"running","meta_status":"running","agent_session_id":"u1","project_dir":"/tmp/p","created_at":"2026-07-10T10:00:00Z","last_checkpoint_at":null,"exit_status":null,"finished_at":null}
    """

    func ok(_ stdout: String) -> Result<CLIResult, Error> {
        .success(CLIResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false))
    }

    func testRefreshParsesSessions() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.state, .ok)
        XCTAssertNotNil(store.lastUpdated)
    }

    func testInvalidLinesSetIncompatible() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok("garbage")
        let store = SessionStore(cli: cli)
        await store.refresh()
        XCTAssertEqual(store.state, .incompatible)
    }

    func testMixedLinesKeepPreviousSessions() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        cli.responses["list --json"] = ok(line + "\ngarbage")
        await store.refresh()
        XCTAssertEqual(store.state, .incompatible)
        XCTAssertEqual(store.sessions.count, 1) // spec: never update the list from bad data
    }

    func testLaunchFailureSetsCliMissingAndKeepsData() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        cli.responses["list --json"] = .failure(FakeError())
        await store.refresh()
        XCTAssertEqual(store.state, .cliMissing)
        XCTAssertEqual(store.sessions.count, 1) // keeps last good data
    }

    func testNonZeroExitSetsError() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = .success(CLIResult(exitCode: 1, stdout: "", stderr: "boom", timedOut: false))
        let store = SessionStore(cli: cli)
        await store.refresh()
        XCTAssertEqual(store.state, .error("boom"))
    }

    func testStopCallsCliAndRefreshes() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        let error = await store.perform(.stop, on: store.sessions[0])
        XCTAssertNil(error)
        XCTAssertTrue(cli.calls.contains(["codex", "stop", "detach-codex-p-1"]))
    }

    func testDeleteUsesForce() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        _ = await store.perform(.delete, on: store.sessions[0])
        XCTAssertTrue(cli.calls.contains(["codex", "delete", "--force", "detach-codex-p-1"]))
    }

    func testFailedMutationReturnsStderr() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        cli.responses["codex stop detach-codex-p-1"] =
            .success(CLIResult(exitCode: 1, stdout: "", stderr: "still busy", timedOut: false))
        let store = SessionStore(cli: cli)
        await store.refresh()
        let error = await store.perform(.stop, on: store.sessions[0])
        XCTAssertEqual(error, "still busy")
    }

    func testSnapshotObserverReceivesEverySuccessfulPoll() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        var snapshots: [[Session]] = []
        store.onSnapshot = { snapshots.append($0) }

        await store.refresh()
        await store.refresh() // unchanged list still advances the observer

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.count, 1)
    }

    func testSnapshotObserverIsNotCalledForFailedPolls() async {
        let cli = FakeCLI()
        let store = SessionStore(cli: cli)
        var snapshotCount = 0
        store.onSnapshot = { _ in snapshotCount += 1 }

        cli.responses["list --json"] = ok("garbage")
        await store.refresh()
        cli.responses["list --json"] = .failure(FakeError())
        await store.refresh()
        cli.responses["list --json"] =
            .success(CLIResult(exitCode: 1, stdout: "", stderr: "boom", timedOut: false))
        await store.refresh()

        XCTAssertEqual(snapshotCount, 0)
    }

    func testConfigureSwapsCLIAndRefreshesImmediately() async {
        let first = FakeCLI()
        first.responses["list --json"] = ok(line)
        let store = SessionStore(cli: first)
        await store.refresh()
        XCTAssertEqual(store.sessions.count, 1)

        let second = FakeCLI()
        second.responses["list --json"] = ok("")
        await store.configure(cli: second)

        XCTAssertEqual(store.sessions.count, 0)
        XCTAssertEqual(second.calls, [["list", "--json"]])
    }

    func testLateResultFromPreviousCLICannotOverwriteReconfiguredStore() async {
        let first = DelayedCLI()
        let store = SessionStore(cli: first)
        let staleRefresh = Task { await store.refresh() }
        await first.waitUntilStarted()

        let second = FakeCLI()
        second.responses["list --json"] = ok("")
        await store.configure(cli: second)
        await first.finish(with: CLIResult(
            exitCode: 0, stdout: line, stderr: "", timedOut: false))
        await staleRefresh.value

        XCTAssertEqual(store.sessions, [])
        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(second.calls, [["list", "--json"]])
    }
}
