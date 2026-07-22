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

private actor PollSleepProbe {
    private(set) var intervals: [UInt64] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func sleep(nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepContinuation = continuation
                intervals.append(nanoseconds)
                let waiters = startedWaiters
                startedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
    }

    func waitUntilStarted() async {
        if !intervals.isEmpty { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancelSleep() {
        cancelled = true
        sleepContinuation?.resume(throwing: CancellationError())
        sleepContinuation = nil
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
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

    func testRefreshSortsNewestSessionsFirstAndUsesDistantPastForMissingDates() async {
        let cli = FakeCLI()
        let olderWithoutDate = line
            .replacingOccurrences(of: "detach-codex-p-1", with: "detach-codex-old")
            .replacingOccurrences(of: "p-1", with: "old")
            .replacingOccurrences(of: #""2026-07-10T10:00:00Z""#, with: "null")
        let newest = line
            .replacingOccurrences(of: "detach-codex-p-1", with: "detach-codex-new")
            .replacingOccurrences(of: "p-1", with: "new")
            .replacingOccurrences(
                of: "2026-07-10T10:00:00Z",
                with: "2026-07-11T10:00:00Z")
        cli.responses["list --json"] = ok(olderWithoutDate + "\n" + line + "\n" + newest)
        let store = SessionStore(cli: cli)

        await store.refresh()

        XCTAssertEqual(
            store.sessions.map(\.sessionName),
            ["detach-codex-new", "detach-codex-p-1", "detach-codex-old"])
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

    func testTimedOutRefreshUsesExplicitDiagnosticAndPreservesData() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        cli.responses["list --json"] = .success(CLIResult(
            exitCode: 0, stdout: "", stderr: "ignored", timedOut: true))

        await store.refresh()

        XCTAssertEqual(store.state, .error(L10n.string("detach list timed out")))
        XCTAssertEqual(store.sessions.count, 1)
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

    func testFailedMutationWithoutStderrReportsExitStatus() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        cli.responses["codex stop detach-codex-p-1"] = .success(CLIResult(
            exitCode: 17, stdout: "", stderr: " \n", timedOut: false))
        let store = SessionStore(cli: cli)
        await store.refresh()

        let error = await store.perform(.stop, on: store.sessions[0])

        XCTAssertEqual(error, L10n.format("detach exited with status %d", 17))
    }

    func testMutationLaunchFailureReturnsLocalizedError() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        cli.responses["codex stop detach-codex-p-1"] = .failure(FakeError())
        let store = SessionStore(cli: cli)
        await store.refresh()

        let error = await store.perform(.stop, on: store.sessions[0])

        XCTAssertTrue(error?.hasPrefix(L10n.string("Could not run detach:")) == true)
    }

    func testTerminalOnlyActionsAreRejectedWithoutRunningTheCLI() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        let callsBeforeActions = cli.calls

        for action in [SessionAction.attach, .resume, .recover] {
            let error = await store.perform(action, on: store.sessions[0])
            XCTAssertEqual(
                error,
                L10n.format("Internal error: %@ must run in Terminal", action.rawValue))
        }
        XCTAssertEqual(cli.calls, callsBeforeActions)
    }

    func testPollingStartsImmediatelySupportsIdleCadenceAndStopsCleanly() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let sleep = PollSleepProbe()
        let store = SessionStore(
            cli: cli,
            pollSleep: { try await sleep.sleep(nanoseconds: $0) })
        var snapshots: [[Session]] = []
        store.onSnapshot = { snapshots.append($0) }
        store.updateCadence(foreground: false)

        store.startPolling(interval: 0.01)
        await sleep.waitUntilStarted()

        let intervals = await sleep.intervals
        XCTAssertEqual(intervals, [10_000_000_000])
        XCTAssertEqual(cli.calls, [["list", "--json"]])
        XCTAssertEqual(snapshots.map { $0.map(\.sessionName) }, [["detach-codex-p-1"]])
        XCTAssertEqual(store.state, .ok)

        store.stopPolling()
        await sleep.waitUntilCancelled()

        XCTAssertEqual(cli.calls, [["list", "--json"]])
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
