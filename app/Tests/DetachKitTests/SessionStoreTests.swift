import XCTest
@testable import DetachKit

final class FakeCLI: DetachCLIRunning, @unchecked Sendable {
    var responses: [String: Result<CLIResult, Error>] = [:]
    private(set) var calls: [[String]] = []
    private(set) var currentDirectories: [URL?] = []

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        calls.append(arguments)
        let key = arguments.joined(separator: " ")
        guard let response = responses[key] else {
            return CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
        }
        return try response.get()
    }

    func run(
        arguments: [String],
        timeout: TimeInterval,
        currentDirectoryURL: URL?
    ) async throws -> CLIResult {
        currentDirectories.append(currentDirectoryURL)
        return try await run(arguments: arguments, timeout: timeout)
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

private actor OverlappingStartCLI: DetachCLIRunning {
    private let listOutput: String
    private var listCallCount = 0
    private var listContinuations: [Int: CheckedContinuation<CLIResult, Never>] = [:]
    private var listWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(listOutput: String) {
        self.listOutput = listOutput
    }

    func run(
        arguments: [String], timeout: TimeInterval
    ) async throws -> CLIResult {
        guard arguments == ["list", "--json"] else {
            return CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
        }
        listCallCount += 1
        let call = listCallCount
        let ready = listWaiters.filter { $0.0 <= call }
        listWaiters.removeAll { $0.0 <= call }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation { continuation in
            listContinuations[call] = continuation
        }
    }

    func waitForListCall(_ call: Int) async {
        if listCallCount >= call { return }
        await withCheckedContinuation { listWaiters.append((call, $0)) }
    }

    func finishListCall(_ call: Int) {
        listContinuations.removeValue(forKey: call)?.resume(returning: CLIResult(
            exitCode: 0,
            stdout: listOutput,
            stderr: "",
            timedOut: false))
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
        cli.responses["list --json"] = ok(line + "\n" + olderWithoutDate + "\n" + newest)
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

    func testStartDetachedUsesProjectAndSelectsTheNewTypedSession() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)

        let result = await store.startDetached(
            provider: .codex,
            projectDirectory: project,
            name: "Rev (ai)",
            prompt: "review this",
            providerArguments: ["--disable", "deferred-tools"])

        XCTAssertEqual(
            cli.calls,
            [
                [
                    "codex", "--name", "Rev (ai)", "--detach", "--",
                    "--disable", "deferred-tools", "review this",
                ],
                ["list", "--json"],
            ])
        XCTAssertEqual(cli.currentDirectories, [project])
        XCTAssertEqual(result, SessionStartResult(sessionID: "detach-codex-p-1"))
    }

    func testStartDetachedKeepsItsSelectionWhenABackgroundPollSupersedesPublication() async {
        let cli = OverlappingStartCLI(listOutput: line)
        let store = SessionStore(cli: cli)
        let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)

        let launch = Task { @MainActor in
            await store.startDetached(
                provider: .codex,
                projectDirectory: project,
                name: nil,
                prompt: nil)
        }
        await cli.waitForListCall(1)
        let backgroundPoll = Task { @MainActor in await store.refresh() }
        await cli.waitForListCall(2)

        await cli.finishListCall(1)
        let result = await launch.value
        await cli.finishListCall(2)
        _ = await backgroundPoll.value

        XCTAssertEqual(result.sessionID, "detach-codex-p-1")
        XCTAssertEqual(store.sessions.first?.id, "detach-codex-p-1")
    }

    func testStartDetachedKeepsFailuresAndTimeoutsInTheCaller() async {
        let failureCLI = FakeCLI()
        failureCLI.responses["claude --detach"] = .success(CLIResult(
            exitCode: 17,
            stdout: "",
            stderr: "start refused\n",
            timedOut: false))
        let failureStore = SessionStore(cli: failureCLI)
        let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)
        let failure = await failureStore.startDetached(
            provider: .claude,
            projectDirectory: project,
            name: nil,
            prompt: nil)
        XCTAssertEqual(failure.message, "start refused")

        let timeoutCLI = FakeCLI()
        timeoutCLI.responses["codex --detach"] = .success(CLIResult(
            exitCode: 0,
            stdout: "",
            stderr: "",
            timedOut: true))
        let timeoutStore = SessionStore(cli: timeoutCLI)
        let timeout = await timeoutStore.startDetached(
            provider: .codex,
            projectDirectory: project,
            name: nil,
            prompt: nil)
        XCTAssertEqual(timeout.message, L10n.string("detach start timed out"))
        XCTAssertEqual(timeoutCLI.calls.last, ["list", "--json"])
    }

    func testStartDetachedReportsEmptyFailureAndLaunchError() async {
        let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)
        let emptyFailureCLI = FakeCLI()
        emptyFailureCLI.responses["claude --detach"] = .success(CLIResult(
            exitCode: 17,
            stdout: "",
            stderr: "",
            timedOut: false))

        let emptyFailure = await SessionStore(cli: emptyFailureCLI).startDetached(
            provider: .claude,
            projectDirectory: project,
            name: nil,
            prompt: nil)

        XCTAssertEqual(
            emptyFailure.message,
            L10n.format("detach exited with status %d", 17))

        let launchFailureCLI = FakeCLI()
        launchFailureCLI.responses["codex --detach"] = .failure(FakeError())

        let launchFailure = await SessionStore(cli: launchFailureCLI).startDetached(
            provider: .codex,
            projectDirectory: project,
            name: nil,
            prompt: nil)

        XCTAssertTrue(launchFailure.message?.hasPrefix("Could not run detach: ") == true)
    }

    func testStartDetachedRejectsAnAmbiguousTypedRefresh() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)
        await store.refresh()

        let second = line
            .replacingOccurrences(of: "detach-codex-p-1", with: "detach-codex-p-2")
            .replacingOccurrences(of: #"\"name\":\"p-1\""#, with: #"\"name\":\"p-2\""#)
        let third = line
            .replacingOccurrences(of: "detach-codex-p-1", with: "detach-codex-p-3")
            .replacingOccurrences(of: #"\"name\":\"p-1\""#, with: #"\"name\":\"p-3\""#)
        cli.responses["list --json"] = ok(line + "\n" + second + "\n" + third)

        let result = await store.startDetached(
            provider: .codex,
            projectDirectory: project,
            name: "",
            prompt: "")

        XCTAssertEqual(cli.calls.suffix(2), [["codex", "--detach"], ["list", "--json"]])
        XCTAssertNil(result.sessionID)
        XCTAssertNil(result.message)
    }

    func testPrepareResumeStartsDetachedThenRefreshes() async throws {
        let cli = FakeCLI()
        let stopped = line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"stopped""#)
        cli.responses["list --json"] = ok(stopped)
        let store = SessionStore(cli: cli)
        await store.refresh()

        let error = await store.prepareInteractive(
            .resume,
            on: try XCTUnwrap(store.sessions.first))

        XCTAssertNil(error)
        XCTAssertEqual(
            cli.calls,
            [["list", "--json"], ["resume", "--detach", "u1"], ["list", "--json"]])
    }

    func testPrepareRecoverUsesProviderAndManagedName() async throws {
        let cli = FakeCLI()
        let recoverable = line
            .replacingOccurrences(of: "codex", with: "claude")
            .replacingOccurrences(
                of: #""effective_status":"running""#,
                with: #""effective_status":"recoverable""#)
        cli.responses["list --json"] = ok(recoverable)
        let store = SessionStore(cli: cli)
        await store.refresh()

        let error = await store.prepareInteractive(
            .recover,
            on: try XCTUnwrap(store.sessions.first))

        XCTAssertNil(error)
        XCTAssertTrue(cli.calls.contains([
            "claude", "recover", "--detach", "detach-claude-p-1",
        ]))
    }

    func testPrepareInteractiveReturnsTheBoundedCLIFailure() async throws {
        let cli = FakeCLI()
        let stopped = line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"stopped""#)
        cli.responses["list --json"] = ok(stopped)
        cli.responses["resume --detach u1"] = .success(CLIResult(
            exitCode: 17,
            stdout: "",
            stderr: "resume refused",
            timedOut: false))
        let store = SessionStore(cli: cli)
        await store.refresh()

        let error = await store.prepareInteractive(
            .resume,
            on: try XCTUnwrap(store.sessions.first))

        XCTAssertEqual(error, "resume refused")
        XCTAssertEqual(cli.calls.last, ["list", "--json"])
    }

    func testPrepareInteractiveHandlesMissingIDTimeoutAndLaunchFailure() async throws {
        let missingIDCLI = FakeCLI()
        missingIDCLI.responses["list --json"] = ok(line.replacingOccurrences(
            of: #""agent_session_id":"u1""#,
            with: #""agent_session_id":null"#))
        let missingIDStore = SessionStore(cli: missingIDCLI)
        await missingIDStore.refresh()
        let missingIDError = await missingIDStore.prepareInteractive(
            .resume,
            on: try XCTUnwrap(missingIDStore.sessions.first))
        XCTAssertEqual(
            missingIDError,
            L10n.string("The session has no provider UUID to resume."))

        let timeoutCLI = FakeCLI()
        timeoutCLI.responses["list --json"] = ok(line)
        timeoutCLI.responses["resume --detach u1"] = .success(CLIResult(
            exitCode: 124,
            stdout: "",
            stderr: "",
            timedOut: true))
        let timeoutStore = SessionStore(cli: timeoutCLI)
        await timeoutStore.refresh()
        let timeoutError = await timeoutStore.prepareInteractive(
            .resume,
            on: try XCTUnwrap(timeoutStore.sessions.first))
        XCTAssertEqual(
            timeoutError,
            L10n.string("detach resume timed out"))

        let failedCLI = FakeCLI()
        failedCLI.responses["list --json"] = ok(line)
        failedCLI.responses["resume --detach u1"] = .failure(FakeError())
        let failedStore = SessionStore(cli: failedCLI)
        await failedStore.refresh()
        let launchError = await failedStore.prepareInteractive(
            .resume,
            on: try XCTUnwrap(failedStore.sessions.first))
        let invalidActionError = await failedStore.prepareInteractive(
            .attach,
            on: try XCTUnwrap(failedStore.sessions.first))
        XCTAssertNotNil(launchError)
        XCTAssertNotNil(invalidActionError)
    }

    func testPrepareInteractiveCoversRecoverTimeoutAndEmptyFailure() async throws {
        let recoverCLI = FakeCLI()
        let recoverable = line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"recoverable""#)
        recoverCLI.responses["list --json"] = ok(recoverable)
        recoverCLI.responses[
            "codex recover --detach detach-codex-p-1"
        ] = .success(CLIResult(
            exitCode: 124,
            stdout: "",
            stderr: "",
            timedOut: true))
        let recoverStore = SessionStore(cli: recoverCLI)
        await recoverStore.refresh()

        let recoverError = await recoverStore.prepareInteractive(
            .recover,
            on: try XCTUnwrap(recoverStore.sessions.first))

        XCTAssertEqual(recoverError, L10n.string("detach recover timed out"))

        let failureCLI = FakeCLI()
        failureCLI.responses["list --json"] = ok(line)
        failureCLI.responses["resume --detach u1"] = .success(CLIResult(
            exitCode: 23,
            stdout: "",
            stderr: " \n",
            timedOut: false))
        let failureStore = SessionStore(cli: failureCLI)
        await failureStore.refresh()

        let failure = await failureStore.prepareInteractive(
            .resume,
            on: try XCTUnwrap(failureStore.sessions.first))

        XCTAssertEqual(failure, L10n.format("detach exited with status %d", 23))
    }

    func testBulkFinishedDeleteContinuesAfterFailureAndRefreshesOnce() async throws {
        let cli = FakeCLI()
        let firstLine = line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"completed""#)
        let secondLine = firstLine
            .replacingOccurrences(of: "codex", with: "claude")
            .replacingOccurrences(of: "detach-claude-p-1", with: "detach-claude-p-2")
            .replacingOccurrences(of: #""name":"p-1""#, with: #""name":"p-2""#)
        cli.responses["list --json"] = ok(firstLine + "\n" + secondLine)
        cli.responses["claude delete --force detach-claude-p-2"] = .success(CLIResult(
            exitCode: 17, stdout: "", stderr: "still busy", timedOut: false))
        let store = SessionStore(cli: cli)
        await store.refresh()

        let failures = await store.deleteFinished(
            store.sessions + [try XCTUnwrap(store.sessions.first)])

        XCTAssertEqual(failures, [SessionDeletionFailure(
            sessionName: "detach-claude-p-2",
            displayTitle: "p",
            message: "still busy")])
        XCTAssertEqual(
            cli.calls.filter { $0 == ["codex", "delete", "--force", "detach-codex-p-1"] }.count,
            1)
        XCTAssertEqual(
            cli.calls.filter { $0 == ["claude", "delete", "--force", "detach-claude-p-2"] }.count,
            1)
        XCTAssertEqual(cli.calls.filter { $0 == ["list", "--json"] }.count, 2)
    }

    func testBulkFinishedDeleteRechecksCurrentTypedPermission() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        var staleFinishedSelection = store.sessions[0]
        staleFinishedSelection.effectiveStatus = .completed

        let failures = await store.deleteFinished([staleFinishedSelection])

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(
            failures.first?.message,
            L10n.string("Session is not eligible for deletion from Finished."))
        XCTAssertFalse(cli.calls.contains {
            $0.contains("delete")
        })
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

    func testForegroundPollingUsesTheBoundedBaseInterval() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let sleep = PollSleepProbe()
        let store = SessionStore(
            cli: cli,
            pollSleep: { try await sleep.sleep(nanoseconds: $0) })

        store.startPolling(interval: 0.01)
        await sleep.waitUntilStarted()

        let intervals = await sleep.intervals
        XCTAssertEqual(intervals, [500_000_000])
        store.stopPolling()
        await sleep.waitUntilCancelled()
    }

    func testVisiblePetKeepsBaseCadenceWhileMainWindowIsBackgrounded() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let sleep = PollSleepProbe()
        let store = SessionStore(
            cli: cli,
            pollSleep: { try await sleep.sleep(nanoseconds: $0) })
        store.updateCadence(foreground: false)
        store.updatePetCadence(visible: true)

        store.startPolling(interval: 0.01)
        await sleep.waitUntilStarted()

        let intervals = await sleep.intervals
        XCTAssertEqual(intervals, [500_000_000])
        store.stopPolling()
        await sleep.waitUntilCancelled()
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
        _ = await staleRefresh.value

        XCTAssertEqual(store.sessions, [])
        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(second.calls, [["list", "--json"]])
    }
}
