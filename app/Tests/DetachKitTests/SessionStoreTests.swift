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

    var currentListCallCount: Int { listCallCount }

    func finishListCall(_ call: Int, output: String? = nil) {
        listContinuations.removeValue(forKey: call)?.resume(returning: CLIResult(
            exitCode: 0,
            stdout: output ?? listOutput,
            stderr: "",
            timedOut: false))
    }
}

private final class EventCLI: DetachCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var output: String
    private var continuation:
        AsyncThrowingStream<SessionEvent, Error>.Continuation?
    private var subscriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var callCount = 0

    init(output: String) {
        self.output = output
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        let (output, ready) = lock.withLock { () -> (String, [CheckedContinuation<Void, Never>]) in
            callCount += 1
            let count = callCount
            let ready = callWaiters.filter { $0.0 <= count }.map(\.1)
            callWaiters.removeAll { $0.0 <= count }
            return (self.output, ready)
        }
        ready.forEach { $0.resume() }
        return CLIResult(
            exitCode: 0,
            stdout: output,
            stderr: "",
            timedOut: false)
    }

    func sessionEvents() -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let waiters = lock.withLock {
                self.continuation = continuation
                let waiters = subscriptionWaiters
                subscriptionWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func emit(_ kind: SessionEventKind) {
        let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation? =
            lock.withLock { self.continuation }
        continuation?.yield(SessionEvent(event: kind))
    }

    /// Ends the current stream like a watcher exit. A later subscription
    /// installs a fresh continuation, so `waitUntilSubscribed` waits again.
    func end(throwing error: (any Error)?) {
        let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation? =
            lock.withLock {
                let current = self.continuation
                self.continuation = nil
                return current
            }
        continuation?.finish(throwing: error)
    }

    func setOutput(_ output: String) {
        lock.withLock { self.output = output }
    }

    func waitUntilSubscribed() async {
        await withCheckedContinuation { waiter in
            let subscribed = lock.withLock {
                if continuation != nil { return true }
                subscriptionWaiters.append(waiter)
                return false
            }
            if subscribed {
                waiter.resume()
            }
        }
    }

    func waitForCallCount(_ expected: Int) async {
        await withCheckedContinuation { waiter in
            let reached = lock.withLock {
                if callCount >= expected { return true }
                callWaiters.append((expected, waiter))
                return false
            }
            if reached {
                waiter.resume()
            }
        }
    }

    var currentCallCount: Int {
        lock.withLock { callCount }
    }
}

private actor ConfirmationSleepProbe {
    private var callCount = 0
    private var requestedNanoseconds: [UInt64] = []
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    func sleep(nanoseconds: UInt64? = nil) async {
        callCount += 1
        if let nanoseconds { requestedNanoseconds.append(nanoseconds) }
        let ready = callWaiters.filter { $0.0 <= callCount }
        callWaiters.removeAll { $0.0 <= callCount }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { sleepers.append($0) }
    }

    func waitForCallCount(_ expected: Int) async {
        if callCount >= expected { return }
        await withCheckedContinuation { callWaiters.append((expected, $0)) }
    }

    func resumeSleepers() {
        let current = sleepers
        sleepers.removeAll()
        current.forEach { $0.resume() }
    }

    func calls() -> Int { callCount }
    func delays() -> [UInt64] { requestedNanoseconds }
}

private actor CancellableSleepProbe {
    private let immediateCallCount: Int
    private var callCount = 0
    private var cancellationCount = 0
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(immediateCallCount: Int = 0) {
        self.immediateCallCount = immediateCallCount
    }

    func sleep(nanoseconds: UInt64) async throws {
        callCount += 1
        let ready = callWaiters.filter { $0.0 <= callCount }
        callWaiters.removeAll { $0.0 <= callCount }
        ready.forEach { $0.1.resume() }
        if callCount <= immediateCallCount { return }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            cancellationCount += 1
            let cancelled = cancellationWaiters.filter { $0.0 <= cancellationCount }
            cancellationWaiters.removeAll { $0.0 <= cancellationCount }
            cancelled.forEach { $0.1.resume() }
            throw error
        }
    }

    func waitForCallCount(_ expected: Int) async {
        if callCount >= expected { return }
        await withCheckedContinuation { callWaiters.append((expected, $0)) }
    }

    func waitForCancellationCount(_ expected: Int) async {
        if cancellationCount >= expected { return }
        await withCheckedContinuation { cancellationWaiters.append((expected, $0)) }
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

    func testCachedRowsPaintImmediatelyButStayNonAuthoritativeUntilRefresh() async throws {
        let suite = "SessionStoreCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = UserDefaultsSessionSnapshotCache(defaults: defaults)
        let cached = try XCTUnwrap(SessionListParser.parse(line).sessions.first)
        cache.store([cached])
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)

        let store = SessionStore(cli: cli, snapshotCache: cache)

        XCTAssertEqual(store.sessions.map(\.id), [cached.id])
        XCTAssertTrue(store.sessions[0].availableActions.isEmpty)
        XCTAssertFalse(store.hasFreshSnapshot)
        XCTAssertNil(store.lastUpdated)

        await store.refresh()

        XCTAssertTrue(store.hasFreshSnapshot)
        XCTAssertEqual(store.sessions[0].availableActions, [.attach, .stop])
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

    func testTruncatedRefreshUsesExplicitDiagnosticAndPreservesData() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        cli.responses["list --json"] = .success(CLIResult(
            exitCode: 0,
            stdout: line,
            stderr: "",
            timedOut: false,
            stdoutTruncated: true))

        await store.refresh()

        XCTAssertEqual(
            store.state,
            .error(L10n.string("detach returned incomplete output")))
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
            prompt: "review this")

        XCTAssertEqual(
            cli.calls,
            [
                ["codex", "--name", "Rev (ai)", "--detach", "--", "review this"],
                ["list", "--json"],
            ])
        XCTAssertEqual(cli.currentDirectories, [project])
        XCTAssertEqual(result, SessionStartResult(sessionID: "detach-codex-p-1"))
    }

    func testStartDetachedKeepsItsSelectionWhenAnOverlappingRefreshQueuesATrailingRead() async {
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
        await Task.yield()
        let callsBeforeFirstCompletion = await cli.currentListCallCount
        XCTAssertEqual(callsBeforeFirstCompletion, 1)

        await cli.finishListCall(1)
        await cli.waitForListCall(2)
        await cli.finishListCall(2)
        let result = await launch.value
        _ = await backgroundPoll.value

        XCTAssertEqual(result.sessionID, "detach-codex-p-1")
        XCTAssertEqual(store.sessions.first?.id, "detach-codex-p-1")
    }

    func testOverlappingRefreshesUseOneTrailingSnapshotAndPublishNewestObservation() async {
        let cli = OverlappingStartCLI(listOutput: line)
        let store = SessionStore(cli: cli)
        let first = Task { @MainActor in await store.refresh() }
        await cli.waitForListCall(1)

        let second = Task { @MainActor in await store.refresh() }
        let third = Task { @MainActor in await store.refresh() }
        await Task.yield()
        let callsBeforeFirstCompletion = await cli.currentListCallCount
        XCTAssertEqual(callsBeforeFirstCompletion, 1)

        await cli.finishListCall(1, output: "")
        await cli.waitForListCall(2)
        let callsDuringTrailingRead = await cli.currentListCallCount
        XCTAssertEqual(callsDuringTrailingRead, 2)
        await cli.finishListCall(2, output: line)
        _ = await first.value
        _ = await second.value
        _ = await third.value

        let finalCallCount = await cli.currentListCallCount
        XCTAssertEqual(finalCallCount, 2)
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
        // Keep the historical regression ID. Polling and idle cadence were
        // replaced by a native stream; this proves its immediate ready/change
        // snapshots and explicit stop boundary.
        let cli = EventCLI(output: line)
        let store = SessionStore(cli: cli)
        var snapshots: [[Session]] = []
        store.onSnapshot = { snapshots.append($0) }
        store.startObserving()
        await cli.waitUntilSubscribed()
        XCTAssertEqual(cli.currentCallCount, 0)

        cli.emit(.ready)
        await cli.waitForCallCount(1)
        let initial = expectation(description: "initial event snapshot")
        if !store.sessions.isEmpty { initial.fulfill() }
        else {
            store.onSnapshot = {
                snapshots.append($0)
                initial.fulfill()
            }
        }
        await fulfillment(of: [initial], timeout: 1)

        cli.setOutput("")
        let changed = expectation(description: "changed event snapshot")
        store.onSnapshot = {
            snapshots.append($0)
            if $0.isEmpty { changed.fulfill() }
        }
        cli.emit(.changed)
        await fulfillment(of: [changed], timeout: 1)

        XCTAssertEqual(snapshots.last, [])
        store.stopObserving()
    }

    func testChangedEventPublishesAnswerReadyToWorkingTransition() async {
        let waiting = line.replacingOccurrences(
            of: #""finished_at":null"#,
            with: #""finished_at":null,"agent_turn_state":"waiting","agent_turn_id":"turn-1""#)
        let working = line.replacingOccurrences(
            of: #""finished_at":null"#,
            with: #""finished_at":null,"agent_turn_state":"working","agent_turn_id":"turn-2""#)
        let cli = EventCLI(output: waiting)
        let store = SessionStore(cli: cli)
        store.startObserving()
        await cli.waitUntilSubscribed()

        cli.emit(.ready)
        await cli.waitForCallCount(1)
        let answerReady = expectation(description: "answer ready snapshot")
        store.onSnapshot = { sessions in
            if sessions.first?.agentTurnState == .waiting {
                answerReady.fulfill()
            }
        }
        if store.sessions.first?.agentTurnState == .waiting {
            answerReady.fulfill()
        }
        await fulfillment(of: [answerReady], timeout: 1)

        cli.setOutput(working)
        let resumed = expectation(description: "working snapshot")
        store.onSnapshot = { sessions in
            if sessions.first?.agentTurnState == .working {
                resumed.fulfill()
            }
        }
        cli.emit(.changed)
        await fulfillment(of: [resumed], timeout: 1)

        XCTAssertFalse(store.sessions[0].isWaitingForUser)
        XCTAssertEqual(store.sessions[0].section, .active)
        store.stopObserving()
    }

    func testSnapshotObserverReceivesEverySuccessfulPoll() async {
        // Keep the historical regression ID. Native events now request these
        // typed snapshots instead of a periodic poll.
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        var snapshots: [[Session]] = []
        store.onSnapshot = { snapshots.append($0) }

        await store.refresh()
        await store.refresh() // unchanged state still advances transition evidence

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.count, 1)
    }

    func testInterruptedConfirmationRefreshRunsOnlyOncePerTransition() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"interrupted""#))
        let probe = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in await probe.sleep() },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in })
        let confirmed = expectation(description: "confirmation snapshot")
        var snapshotCount = 0
        store.onSnapshot = { _ in
            snapshotCount += 1
            if snapshotCount == 2 { confirmed.fulfill() }
        }

        await store.refresh()
        await probe.waitForCallCount(1)
        await probe.resumeSleepers()
        await fulfillment(of: [confirmed], timeout: 1)
        await Task.yield()
        let confirmationCalls = await probe.calls()

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(confirmationCalls, 1)
    }

    func testDefaultConfirmationDelayPublishesTheFollowUpSnapshot() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"interrupted""#))
        let store = SessionStore(cli: cli)
        let confirmed = expectation(description: "default confirmation snapshot")
        var snapshotCount = 0
        store.onSnapshot = { _ in
            snapshotCount += 1
            if snapshotCount == 2 { confirmed.fulfill() }
        }

        await store.refresh()
        await fulfillment(of: [confirmed], timeout: 1)

        XCTAssertEqual(snapshotCount, 2)
    }

    func testHungConfirmationRefreshRunsOnlyOncePerTransition() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"hung""#))
        let probe = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in await probe.sleep() },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in })
        let confirmed = expectation(description: "confirmation snapshot")
        var snapshotCount = 0
        store.onSnapshot = { _ in
            snapshotCount += 1
            if snapshotCount == 2 { confirmed.fulfill() }
        }

        await store.refresh()
        await probe.waitForCallCount(1)
        await probe.resumeSleepers()
        await fulfillment(of: [confirmed], timeout: 1)
        await Task.yield()
        let confirmationCalls = await probe.calls()

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(confirmationCalls, 1)
    }

    func testEndedEventStreamRestartsAfterBoundedBackoff() async {
        let cli = EventCLI(output: line)
        let restart = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in await restart.sleep() })
        store.startObserving()
        await cli.waitUntilSubscribed()
        cli.emit(.ready)
        await cli.waitForCallCount(1)

        cli.end(throwing: DetachCLIStreamError.exited(1))
        await restart.waitForCallCount(1)
        await restart.resumeSleepers()
        await cli.waitUntilSubscribed()
        cli.emit(.ready)
        await cli.waitForCallCount(2)

        XCTAssertEqual(cli.currentCallCount, 2)
        XCTAssertEqual(store.state, .ok)
        store.stopObserving()
    }

    func testForegroundPollingUsesTheBoundedBaseInterval() async {
        // Keep the historical regression ID. Foreground polling was replaced
        // by a native stream; this now proves the replacement uses the same
        // bounded base delay when its watcher exits.
        let cli = EventCLI(output: line)
        let restart = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { delay in
                await restart.sleep(nanoseconds: delay)
            })
        store.startObserving()
        await cli.waitUntilSubscribed()

        cli.end(throwing: DetachCLIStreamError.exited(1))
        await restart.waitForCallCount(1)

        let delays = await restart.delays()
        XCTAssertEqual(delays, [SessionStore.restartBaseDelayNanoseconds])
        store.stopObserving()
        await restart.resumeSleepers()
    }

    func testCancellationErrorFromEventStreamStillUsesBoundedRestart() async {
        let cli = EventCLI(output: line)
        let restart = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in await restart.sleep() })
        store.startObserving()
        await cli.waitUntilSubscribed()

        cli.end(throwing: CancellationError())
        await restart.waitForCallCount(1)

        let restartCalls = await restart.calls()
        XCTAssertEqual(restartCalls, 1)
        store.stopObserving()
        await restart.resumeSleepers()
    }

    func testStoppingObserverCancelsTheLongReadinessDeadline() async {
        let cli = EventCLI(output: line)
        let readiness = CancellableSleepProbe(immediateCallCount: 1)
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { delay in
                try await readiness.sleep(nanoseconds: delay)
            },
            restartSleep: { _ in })
        store.startObserving()
        await cli.waitUntilSubscribed()
        await readiness.waitForCallCount(2)

        store.stopObserving()
        await readiness.waitForCancellationCount(1)
    }

    func testStoppedObserverNeverRestarts() async {
        let cli = EventCLI(output: line)
        let restart = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in await restart.sleep() })
        store.startObserving()
        await cli.waitUntilSubscribed()
        store.stopObserving()
        cli.end(throwing: nil)
        for _ in 0..<20 { await Task.yield() }

        let restartCalls = await restart.calls()
        XCTAssertEqual(restartCalls, 0)
    }

    func testStoppingObserverCancelsPendingSnapshotRetry() async {
        let cli = EventCLI(output: "invalid")
        let retry = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in await retry.sleep() })
        store.startObserving()
        await cli.waitUntilSubscribed()
        cli.emit(.ready)
        await cli.waitForCallCount(1)
        await retry.waitForCallCount(1)

        store.stopObserving()
        await retry.resumeSleepers()
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(cli.currentCallCount, 1)
    }

    func testFailedTypedSnapshotIsRetriedWithBackoff() async {
        let cli = FakeCLI()
        cli.responses["list --json"] = .success(CLIResult(
            exitCode: 1, stdout: "", stderr: "busy", timedOut: false))
        let retry = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { _ in },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in await retry.sleep() })

        await store.refresh()
        XCTAssertEqual(store.state, .error("busy"))
        cli.responses["list --json"] = ok(line)
        await retry.waitForCallCount(1)
        await retry.resumeSleepers()
        for _ in 0..<200 where store.state != .ok {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(cli.calls.count, 2)
    }

    func testSlowWatcherSurvivesTheReadinessWaitAndRefreshesOnItsFirstEvent() async {
        let cli = EventCLI(output: line)
        let readiness = ConfirmationSleepProbe()
        let store = SessionStore(
            cli: FakeCLI(),
            confirmationSleep: { _ in },
            eventReadinessSleep: { _ in await readiness.sleep() },
            restartSleep: { _ in })
        let configuration = Task { @MainActor in
            await store.configure(cli: cli)
        }
        await cli.waitUntilSubscribed()
        await readiness.waitForCallCount(1)
        await readiness.resumeSleepers()
        await configuration.value
        XCTAssertEqual(cli.currentCallCount, 1)

        // The watcher was slow, not broken. Its late `ready` repeats the
        // snapshot that raced the installation instead of being discarded.
        cli.emit(.ready)
        await cli.waitForCallCount(2)

        XCTAssertEqual(cli.currentCallCount, 2)
        store.stopObserving()
    }

    func testSnapshotObserverIsNotCalledForFailedPolls() async {
        // Keep the historical regression ID. The failure boundary applies to
        // each typed snapshot requested by the native event stream.
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

    func testConfigureWaitsForReadyAndTakesOnlyOneColdStartSnapshot() async {
        let cli = EventCLI(output: line)
        let store = SessionStore(cli: FakeCLI())

        let configuration = Task { @MainActor in
            await store.configure(cli: cli)
        }
        await cli.waitUntilSubscribed()
        XCTAssertEqual(cli.currentCallCount, 0)

        cli.emit(.ready)
        await configuration.value

        XCTAssertEqual(cli.currentCallCount, 1)
        XCTAssertEqual(store.sessions.count, 1)
        store.stopObserving()
    }

    func testConfigureBoundsAWatcherThatNeverBecomesReady() async {
        let cli = EventCLI(output: line)
        let readiness = CancellableSleepProbe(immediateCallCount: 1)
        let store = SessionStore(
            cli: FakeCLI(),
            confirmationSleep: { _ in },
            eventReadinessSleep: { delay in
                try await readiness.sleep(nanoseconds: delay)
            },
            restartSleep: { _ in })

        await store.configure(cli: cli)

        XCTAssertEqual(cli.currentCallCount, 1)
        XCTAssertEqual(store.sessions.count, 1)
        store.stopObserving()
        await readiness.waitForCancellationCount(1)
    }

    func testResynchronizeInstallsTheWatcherBeforeTakingItsSnapshot() async {
        let cli = EventCLI(output: line)
        let store = SessionStore(cli: cli)
        let resynchronization = Task { @MainActor in
            await store.resynchronize()
        }
        await cli.waitUntilSubscribed()
        XCTAssertEqual(cli.currentCallCount, 0)

        cli.emit(.ready)
        await resynchronization.value

        XCTAssertEqual(cli.currentCallCount, 1)
        XCTAssertEqual(store.sessions.count, 1)
        store.stopObserving()
    }

    func testStoppedResynchronizeCannotPublishAfterItsGenerationChanges() async {
        let cli = EventCLI(output: line)
        let store = SessionStore(cli: cli)
        let resynchronization = Task { @MainActor in
            await store.resynchronize()
        }
        await cli.waitUntilSubscribed()

        store.stopObserving()
        await resynchronization.value

        XCTAssertEqual(cli.currentCallCount, 0)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testWaitForSessionReturnsAnExistingUnambiguousMatch() async throws {
        let cli = FakeCLI()
        cli.responses["list --json"] = ok(line)
        let store = SessionStore(cli: cli)
        await store.refresh()
        let expected = try XCTUnwrap(store.sessions.first?.id)

        let match = await store.waitForSession(
            provider: .codex,
            projectDirectory: URL(fileURLWithPath: "/tmp/p"),
            excluding: [])

        XCTAssertEqual(match, expected)
    }

    func testWaitForSessionCancellationReleasesAPendingWaiter() async {
        let store = SessionStore(cli: FakeCLI())
        let waiter = Task { @MainActor in
            await store.waitForSession(
                provider: .claude,
                projectDirectory: URL(fileURLWithPath: "/tmp/missing"),
                excluding: [])
        }
        await Task.yield()

        waiter.cancel()

        let result = await waiter.value
        XCTAssertNil(result)
    }

    func testWaitForSessionHonorsCancellationBeforeRegistration() async {
        let store = SessionStore(cli: FakeCLI())
        let waiter = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.waitForSession(
                provider: .claude,
                projectDirectory: URL(fileURLWithPath: "/tmp/missing"),
                excluding: [])
        }

        let result = await waiter.value
        XCTAssertNil(result)
    }

    func testNewStableSnapshotCancelsTransientConfirmation() async {
        let cli = FakeCLI()
        let interrupted = line.replacingOccurrences(
            of: #""effective_status":"running""#,
            with: #""effective_status":"interrupted""#)
        cli.responses["list --json"] = ok(interrupted)
        let confirmation = CancellableSleepProbe()
        let store = SessionStore(
            cli: cli,
            confirmationSleep: { delay in
                try await confirmation.sleep(nanoseconds: delay)
            },
            eventReadinessSleep: { try await Task.sleep(nanoseconds: $0) },
            restartSleep: { _ in })
        await store.refresh()
        await confirmation.waitForCallCount(1)

        cli.responses["list --json"] = ok(line)
        await store.refresh()
        await confirmation.waitForCancellationCount(1)

        XCTAssertEqual(store.sessions.first?.effectiveStatus, .running)
    }

    func testOverlappingConfigureCannotPublishTheStoppedObserver() async {
        let first = EventCLI(output: line)
        let second = EventCLI(output: "")
        let store = SessionStore(cli: FakeCLI())
        let firstConfiguration = Task { @MainActor in
            await store.configure(cli: first)
        }
        await first.waitUntilSubscribed()

        let secondConfiguration = Task { @MainActor in
            await store.configure(cli: second)
        }
        await second.waitUntilSubscribed()
        second.emit(.ready)
        await secondConfiguration.value
        await firstConfiguration.value

        XCTAssertEqual(first.currentCallCount, 0)
        XCTAssertEqual(second.currentCallCount, 1)
        XCTAssertTrue(store.sessions.isEmpty)
        store.stopObserving()
    }

    func testLateResultFromPreviousCLICannotOverwriteReconfiguredStore() async {
        let first = DelayedCLI()
        let store = SessionStore(cli: first)
        let staleRefresh = Task { await store.refresh() }
        await first.waitUntilStarted()

        let second = FakeCLI()
        second.responses["list --json"] = ok("")
        let configuration = Task { @MainActor in
            await store.configure(cli: second)
        }
        await first.finish(with: CLIResult(
            exitCode: 0, stdout: line, stderr: "", timedOut: false))
        await configuration.value
        _ = await staleRefresh.value

        XCTAssertEqual(store.sessions, [])
        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(second.calls, [["list", "--json"]])
    }

    func testPreviousCLIResultCannotPublishWhileReplacementWaitsForReady() async {
        let first = DelayedCLI()
        let store = SessionStore(cli: first)
        let staleRefresh = Task { await store.refresh() }
        await first.waitUntilStarted()

        let second = EventCLI(output: "")
        let configuration = Task { @MainActor in
            await store.configure(cli: second)
        }
        await second.waitUntilSubscribed()
        await first.finish(with: CLIResult(
            exitCode: 0, stdout: line, stderr: "", timedOut: false))
        _ = await staleRefresh.value
        XCTAssertTrue(store.sessions.isEmpty)

        second.emit(.ready)
        await configuration.value
        XCTAssertEqual(second.currentCallCount, 1)
        XCTAssertTrue(store.sessions.isEmpty)
        store.stopObserving()
    }
}
