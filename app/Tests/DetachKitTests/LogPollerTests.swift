import XCTest
@testable import DetachKit

private actor ConcurrentLogCLI: DetachCLIRunning {
    private let responses: [String: CLIResult]
    private var calls: [[String]] = []
    private var activeCalls = 0
    private var peakActiveCalls = 0

    init(responses: [String: CLIResult] = [:]) {
        self.responses = responses
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        calls.append(arguments)
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        try await Task.sleep(nanoseconds: 20_000_000)
        activeCalls -= 1
        return responses[arguments.joined(separator: " ")]
            ?? CLIResult(exitCode: 0, stdout: "warm", stderr: "", timedOut: false)
    }

    func recordedCalls() -> [[String]] { calls }
    func peakConcurrency() -> Int { peakActiveCalls }
}

private actor SuspendedLogCLI: DetachCLIRunning {
    private var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        calls += 1
        await withCheckedContinuation { continuations.append($0) }
        return CLIResult(
            exitCode: 0, stdout: "warm", stderr: "", timedOut: false)
    }

    func callCount() -> Int { calls }

    func releaseAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
final class LogPollerTests: XCTestCase {
    func testFetchTrimsToTailLimit() async {
        let cli = FakeCLI()
        let lines = (1...700).map { "line \($0)" }.joined(separator: "\n")
        cli.responses["claude logs --ansi detach-claude-x-1"] =
            .success(CLIResult(exitCode: 0, stdout: lines, stderr: "", timedOut: false))
        let poller = LogPoller(cli: cli, provider: .claude, sessionName: "detach-claude-x-1")
        await poller.fetchOnce()
        XCTAssertEqual(poller.lines.count, 500)
        XCTAssertEqual(poller.lines.first, "line 201")
        XCTAssertEqual(poller.lines.last, "line 700")
        XCTAssertNil(poller.errorText)
        XCTAssertTrue(poller.hasLoaded)
    }

    func testFetchFailureSetsError() async {
        let cli = FakeCLI()
        cli.responses["claude logs --ansi detach-claude-x-1"] =
            .success(CLIResult(exitCode: 1, stdout: "", stderr: "no logs found", timedOut: false))
        let poller = LogPoller(cli: cli, provider: .claude, sessionName: "detach-claude-x-1")
        await poller.fetchOnce()
        XCTAssertEqual(poller.errorText, "no logs found")
    }

    func testUnchangedSuccessfulTailClearsAnEarlierErrorWithoutReparsing() async {
        let cli = FakeCLI()
        let key = "codex logs --ansi detach-codex-x-1"
        cli.responses[key] = .success(CLIResult(
            exitCode: 0, stdout: "\u{001B}[1mbold\u{001B}[0m\nplain", stderr: "", timedOut: false))
        let poller = LogPoller(cli: cli, provider: .codex, sessionName: "detach-codex-x-1")
        await poller.fetchOnce()
        let firstAttributed = poller.attributed
        XCTAssertEqual(firstAttributed.string, "bold\nplain")

        cli.responses[key] = .success(CLIResult(
            exitCode: 1, stdout: "", stderr: " temporary failure \n", timedOut: false))
        await poller.fetchOnce()
        XCTAssertEqual(poller.errorText, "temporary failure")

        cli.responses[key] = .success(CLIResult(
            exitCode: 0, stdout: "\u{001B}[1mbold\u{001B}[0m\nplain", stderr: "", timedOut: false))
        await poller.fetchOnce()

        XCTAssertNil(poller.errorText)
        XCTAssertTrue(poller.attributed === firstAttributed)
    }

    func testThrownCLIFailurePublishesLocalizedError() async {
        let cli = FakeCLI()
        cli.responses["claude logs --ansi detach-claude-x-1"] = .failure(FakeError())
        let poller = LogPoller(
            cli: cli, provider: .claude, sessionName: "detach-claude-x-1")

        await poller.fetchOnce()

        XCTAssertFalse(poller.errorText?.isEmpty ?? true)
        XCTAssertFalse(poller.hasLoaded)
    }

    func testSnapshotCacheReturnsTheReadyPollerImmediately() async {
        let cli = FakeCLI()
        let session = makeSession(name: "cached", status: "completed")
        cli.responses["codex logs --ansi cached"] = .success(CLIResult(
            exitCode: 0,
            stdout: "ready output",
            stderr: "",
            timedOut: false))
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        let first = cache.poller(for: session)
        await first.fetchOnce()
        let second = cache.poller(for: session)

        XCTAssertTrue(first === second)
        XCTAssertEqual(second.attributed.string, "ready output")
    }

    func testSnapshotPrefetchIncludesRecoverableAndSkipsLiveSessions() async {
        let first = makeSession(name: "first", status: "completed")
        let live = makeSession(name: "live", status: "running")
        let recoverable = makeSession(name: "recoverable", status: "recoverable")
        let cli = ConcurrentLogCLI(responses: [
            "codex logs --ansi first": CLIResult(
                exitCode: 0, stdout: "one", stderr: "", timedOut: false),
            "codex logs --ansi recoverable": CLIResult(
                exitCode: 0, stdout: "two", stderr: "", timedOut: false),
        ])
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch([first, live, recoverable])
        await cache.prefetch([first, live, recoverable])

        let calls = await cli.recordedCalls()
        XCTAssertEqual(Set(calls), Set([
            ["codex", "logs", "--ansi", "first"],
            ["codex", "logs", "--ansi", "recoverable"],
        ]))
        XCTAssertTrue(cache.poller(for: first).hasLoaded)
        XCTAssertTrue(cache.poller(for: recoverable).hasLoaded)
        XCTAssertFalse(cache.poller(for: live).hasLoaded)
    }

    func testConfigureWarmsNonLiveSessionsAlreadyPresentAtStartup() async {
        let finished = makeSession(name: "startup", status: "completed")
        let cli = ConcurrentLogCLI()
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        cache.configure(
            cli: cli,
            configurationID: "/tmp/detach",
            sessions: [finished])
        await waitUntil { cache.poller(for: finished).hasLoaded }

        XCTAssertTrue(cache.poller(for: finished).hasLoaded)
        let calls = await cli.recordedCalls()
        XCTAssertEqual(calls, [[
            "codex", "logs", "--ansi", "startup",
        ]])
    }

    func testSnapshotCacheInvalidatesOnlyWhenTypedRevisionChanges() async {
        let initial = makeSession(
            name: "finished", status: "completed",
            checkpoint: "2026-09-01T10:00:00Z")
        let changed = makeSession(
            name: "finished", status: "completed",
            checkpoint: "2026-09-01T10:01:00Z")
        let cli = ConcurrentLogCLI()
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch([initial])
        let firstPoller = cache.poller(for: initial)
        await cache.prefetch([initial])
        XCTAssertTrue(firstPoller === cache.poller(for: initial))
        let unchangedCallCount = await cli.recordedCalls().count
        XCTAssertEqual(unchangedCallCount, 1)

        await cache.prefetch([changed])
        XCTAssertFalse(firstPoller === cache.poller(for: changed))
        let changedCallCount = await cli.recordedCalls().count
        XCTAssertEqual(changedCallCount, 2)
    }

    func testSnapshotCacheDropsPassiveTailWhileSessionIsLive() async {
        let finished = makeSession(name: "again", status: "completed")
        let live = makeSession(name: "again", status: "running")
        let cli = ConcurrentLogCLI()
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch([finished])
        let passivePoller = cache.poller(for: finished)
        await cache.prefetch([live])

        XCTAssertFalse(passivePoller === cache.poller(for: finished))
        let callCount = await cli.recordedCalls().count
        XCTAssertEqual(callCount, 1)
    }

    func testSnapshotPrefetchBoundsConcurrentProcesses() async {
        let cli = ConcurrentLogCLI()
        let sessions = (0..<SessionLogSnapshotCache.capacity).map {
            makeSession(name: "session-\($0)", status: "completed")
        }
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch(sessions)
        let peakConcurrency = await cli.peakConcurrency()
        let callCount = await cli.recordedCalls().count

        XCTAssertEqual(
            peakConcurrency,
            SessionLogSnapshotCache.maximumConcurrentPrefetches)
        XCTAssertEqual(callCount, sessions.count)
    }

    func testCancelledLogPrefetchCannotClearAReplacementTask() async {
        let session = makeSession(name: "generation", status: "completed")
        let oldCLI = SuspendedLogCLI()
        let newCLI = SuspendedLogCLI()
        let cache = SessionLogSnapshotCache(cli: oldCLI, configurationID: "old")
        cache.schedulePrefetch(for: [session])
        await waitUntil { await oldCLI.callCount() == 1 }

        cache.configure(cli: newCLI, configurationID: "new")
        cache.schedulePrefetch(for: [session])
        await waitUntil { await newCLI.callCount() == 1 }
        await oldCLI.releaseAll()
        for _ in 0..<20 { await Task.yield() }

        cache.schedulePrefetch(for: [session])
        for _ in 0..<20 { await Task.yield() }
        let replacementCallCount = await newCLI.callCount()
        XCTAssertEqual(replacementCallCount, 1)
        await newCLI.releaseAll()
    }

    func testFailedLogReadIsNotRepeatedForTheSameTypedRevision() async {
        let session = makeSession(name: "missing", status: "completed")
        let cli = ConcurrentLogCLI(responses: [
            "codex logs --ansi missing": CLIResult(
                exitCode: 1, stdout: "", stderr: "no logs found", timedOut: false),
        ])
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch([session])
        await cache.prefetch([session])
        let repeatedCallCount = await cli.recordedCalls().count
        XCTAssertEqual(repeatedCallCount, 1)
        XCTAssertFalse(cache.poller(for: session).hasLoaded)

        let changed = makeSession(
            name: "missing", status: "completed",
            checkpoint: "2026-09-01T10:01:00Z")
        await cache.prefetch([changed])
        let changedCallCount = await cli.recordedCalls().count
        XCTAssertEqual(changedCallCount, 2)
    }

    func testCancelledWarmUpLeavesUnstartedReadsEligible() async {
        let cli = SuspendedLogCLI()
        let cache = SessionLogSnapshotCache(cli: cli, configurationID: "/tmp/detach")
        let sessions = (0..<SessionLogSnapshotCache.capacity).map {
            makeSession(name: "cold-\($0)", status: "completed")
        }

        let warmUp = Task { await cache.prefetch(sessions) }
        await waitUntil {
            await cli.callCount() == SessionLogSnapshotCache.maximumConcurrentPrefetches
        }
        warmUp.cancel()
        await cli.releaseAll()
        await warmUp.value

        // Only the reads that started are recorded. The rest still need a
        // read and must not be skipped as if they had been attempted. The CLI
        // suspends every read, so release each bounded batch as it starts.
        let second = Task { await cache.prefetch(sessions) }
        var released = SessionLogSnapshotCache.maximumConcurrentPrefetches
        while released < sessions.count {
            let target = min(
                released + SessionLogSnapshotCache.maximumConcurrentPrefetches,
                sessions.count)
            await waitUntil { await cli.callCount() == target }
            await cli.releaseAll()
            released = target
        }
        await second.value
        let total = await cli.callCount()
        XCTAssertEqual(total, sessions.count)
    }

    func testDirectlyLoadedTailIsInvalidatedByAReplacementRun() async {
        let cli = ConcurrentLogCLI()
        let cache = SessionLogSnapshotCache(cli: cli, configurationID: "/tmp/detach")
        let original = makeSession(
            name: "reused", status: "completed", created: "2026-09-01T10:00:00Z")
        let direct = cache.poller(for: original)
        await direct.fetchOnce()
        XCTAssertTrue(direct.hasLoaded)

        // The detail view loaded this tail itself. A new run under the same
        // explicit name must not show it.
        let replacement = makeSession(
            name: "reused", status: "completed", created: "2026-09-02T10:00:00Z")
        await cache.prefetch([replacement])

        XCTAssertFalse(direct === cache.poller(for: replacement))
        let calls = await cli.recordedCalls().count
        XCTAssertEqual(calls, 2)
    }

    func testPrefetchFillsFreeSlotsAndNeverEvictsASelectedEntry() async {
        let cli = ConcurrentLogCLI()
        let cache = SessionLogSnapshotCache(
            cli: cli, configurationID: "/tmp/detach")
        let selected = makeSession(name: "selected", status: "completed")
        let selectedPoller = cache.poller(for: selected)
        await selectedPoller.fetchOnce()
        let others = (0..<(SessionLogSnapshotCache.capacity + 4)).map {
            makeSession(name: "other-\($0)", status: "completed")
        }

        // One direct read for the selection plus one read per free slot.
        await cache.prefetch(others + [selected])
        XCTAssertTrue(selectedPoller === cache.poller(for: selected))
        let firstCallCount = await cli.recordedCalls().count
        XCTAssertEqual(firstCallCount, SessionLogSnapshotCache.capacity)

        await cache.prefetch(others + [selected])
        let secondCallCount = await cli.recordedCalls().count
        XCTAssertEqual(secondCallCount, SessionLogSnapshotCache.capacity)
    }

    func testSnapshotCacheEvictsTheLeastRecentEntry() {
        let cache = SessionLogSnapshotCache(
            cli: FakeCLI(), configurationID: "/tmp/detach")
        let firstSession = makeSession(name: "session-0", status: "completed")
        let firstPoller = cache.poller(for: firstSession)

        for index in 1...SessionLogSnapshotCache.capacity {
            _ = cache.poller(for: makeSession(
                name: "session-\(index)", status: "completed"))
        }

        XCTAssertFalse(firstPoller === cache.poller(for: firstSession))
    }

    private func makeSession(
        name: String,
        status: String,
        checkpoint: String? = nil,
        created: String? = nil
    ) -> Session {
        let checkpointField = checkpoint.map {
            ",\"last_checkpoint_at\":\"\($0)\""
        } ?? ""
        let createdField = created.map { ",\"created_at\":\"\($0)\"" } ?? ""
        return SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"\(name)","name":"\(name)","effective_status":"\(status)"\(checkpointField)\(createdField)}
        """).sessions[0]
    }

    private func waitUntil(
        attempts: Int = 200,
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("asynchronous condition did not become true")
    }
}
