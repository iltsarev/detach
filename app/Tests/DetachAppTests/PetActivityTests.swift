import XCTest
@testable import DetachApp
@testable import DetachKit

final class PetActivityTests: XCTestCase {
    private let now = ISO8601DateFormatter()
        .date(from: "2026-09-01T12:00:00Z")!

    func testPriorityIsNeedsInputBlockedReadyRunning() {
        XCTAssertEqual([
            PetActivityState.needsInput,
            .blocked,
            .ready,
            .running,
        ].map(\.priority), [0, 1, 2, 3])
    }

    func testAnswerReadyOutranksWorkAcrossProviders() {
        let sessions = [
            session(id: "running", provider: .codex, status: .running,
                    turn: .working, createdAt: now.addingTimeInterval(4)),
            session(id: "ready", provider: .claude, status: .completed,
                    finishedAt: now.addingTimeInterval(-1)),
            session(id: "blocked", provider: .codex, status: .failed,
                    finishedAt: now.addingTimeInterval(-2)),
            session(id: "input", provider: .claude, status: .running,
                    turn: .needsInput, createdAt: now.addingTimeInterval(1)),
        ]

        let activities = PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalActivityIDs: [
                "lifecycle:claude:ready:ready",
                "lifecycle:codex:blocked:blocked",
            ])

        XCTAssertEqual(activities.map(\.sessionID), [
            "input", "blocked", "ready", "running",
        ])
        XCTAssertEqual(activities.map(\.state), [
            .needsInput, .blocked, .ready, .running,
        ])
        XCTAssertEqual(activities.map(\.provider), [
            .claude, .codex, .claude, .codex,
        ])
    }

    func testOrdinaryCompletedTurnDoesNotClaimInputIsNeeded() {
        let session = session(
            id: "answer", provider: .claude, status: .running, turn: .waiting)

        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalActivityIDs: []).isEmpty)
    }

    func testTerminalProblemOutranksStaleCompletedTurn() {
        let session = session(
            id: "broken", provider: .claude, status: .recoverable,
            turn: .waiting)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalActivityIDs: [
                "lifecycle:claude:broken:broken",
            ]).map(\.state), [.blocked])
    }

    func testStructuredInputRequestCreatesNeedsInputActivity() {
        let session = session(
            id: "question", provider: .claude, status: .running,
            turn: .needsInput)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalActivityIDs: []).map(\.state), [.needsInput])
    }

    func testStructuredInputOutranksRecoverableWorkerHealth() {
        let session = session(
            id: "question", provider: .claude, status: .recoverable,
            turn: .needsInput)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalActivityIDs: [
                "lifecycle:claude:question:question",
            ]).map(\.state), [.needsInput])
    }

    func testAnswerReadySessionOutranksAnotherWorkingSession() {
        let sessions = [
            session(id: "work", provider: .codex, status: .running,
                    turn: .working),
            session(id: "answer", provider: .claude, status: .running,
                    turn: .needsInput),
        ]

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalActivityIDs: []).map(\.sessionID), ["answer", "work"])
    }

    func testFirstSnapshotDoesNotAnnounceHistoricalTerminalSessions() {
        var tracker = PetActivityTracker()
        tracker.observe([
            session(id: "old", provider: .codex, status: .completed,
                    finishedAt: now.addingTimeInterval(-3_600)),
        ], at: now)

        XCTAssertTrue(tracker.unreadTerminalActivityIDs.isEmpty)
    }

    func testLiveTransitionToCompletionBecomesReadyAndCanBeAcknowledged() {
        var tracker = PetActivityTracker()
        tracker.observe([
            session(id: "work", provider: .claude, status: .running),
        ], at: now)
        tracker.observe([
            session(id: "work", provider: .claude, status: .completed,
                    finishedAt: now.addingTimeInterval(2)),
        ], at: now.addingTimeInterval(2))

        XCTAssertEqual(
            tracker.unreadTerminalActivityIDs,
            ["lifecycle:claude:work:work"])
        tracker.acknowledge(activityID: "lifecycle:claude:work:work")
        XCTAssertTrue(tracker.unreadTerminalActivityIDs.isEmpty)
    }

    func testCompletionWhileAppWasAwayBecomesReady() {
        var tracker = PetActivityTracker(lastObservedAt: now)
        tracker.observe([
            session(id: "away", provider: .codex, status: .completed,
                    finishedAt: now.addingTimeInterval(30)),
        ], at: now.addingTimeInterval(60))

        XCTAssertEqual(
            tracker.unreadTerminalActivityIDs,
            ["lifecycle:codex:away:away"])
    }

    func testCompletionLaterInThePersistedCutoffSecondBecomesReady() {
        let cutoff = Date(timeIntervalSince1970: 10_000.900)
        var tracker = PetActivityTracker(lastObservedAt: cutoff)

        tracker.observe([
            session(
                id: "same-second", provider: .codex, status: .completed,
                finishedAt: Date(timeIntervalSince1970: 10_000)),
        ], at: Date(timeIntervalSince1970: 10_001))

        XCTAssertEqual(
            tracker.unreadTerminalActivityIDs,
            ["lifecycle:codex:same-second:same-second"])
    }

    func testAcknowledgedCompletionDoesNotReturnAfterRelaunchInSameSecond() {
        let cutoff = Date(timeIntervalSince1970: 30_000.900)
        let completed = session(
            id: "done", provider: .codex, status: .completed,
            finishedAt: Date(timeIntervalSince1970: 30_000))
        var first = PetActivityTracker(lastObservedAt: cutoff)
        first.observe([completed], at: cutoff)
        first.acknowledge(activityID: "lifecycle:codex:done:done")

        var relaunched = PetActivityTracker(
            unreadTerminalActivityIDs: first.unreadTerminalActivityIDs,
            observedTerminalActivityIDs: first.observedTerminalActivityIDs,
            lastObservedAt: first.lastObservedAt)
        relaunched.observe(
            [completed],
            at: Date(timeIntervalSince1970: 30_001))

        XCTAssertTrue(relaunched.unreadTerminalActivityIDs.isEmpty)
        XCTAssertEqual(
            relaunched.observedTerminalActivityIDs,
            ["lifecycle:codex:done:done"])
    }

    func testStoppedSessionNeverCreatesPetActivity() {
        let stopped = session(id: "stopped", provider: .claude, status: .stopped)
        XCTAssertNil(PetActivityTracker.terminalActivityState(for: stopped))
        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: [stopped],
            unreadTerminalActivityIDs: [
                "lifecycle:claude:stopped:stopped",
            ]).isEmpty)
    }

    func testFreshSessionWithoutConfirmedTurnStaysIdle() {
        let sessions = [
            session(id: "starting", provider: .codex, status: .starting),
            session(id: "prompt", provider: .claude, status: .running),
            session(id: "recovering", provider: .codex, status: .recovering),
        ]

        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalActivityIDs: []).isEmpty)
    }

    func testConfirmedWorkingTurnUsesRunningActivity() {
        let session = session(
            id: "work", provider: .claude, status: .running, turn: .working)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalActivityIDs: []).map(\.state), [.running])
    }

    func testStaleWorkingTurnOnTerminalSessionDoesNotLookActive() {
        let session = session(
            id: "done", provider: .codex, status: .completed, turn: .working)

        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalActivityIDs: []).isEmpty)
    }

    func testSamePriorityUsesMostRecentCompletion() {
        let sessions = [
            session(id: "created-later", provider: .codex, status: .completed,
                    createdAt: now.addingTimeInterval(-10),
                    finishedAt: now.addingTimeInterval(1)),
            session(id: "finished-later", provider: .claude, status: .completed,
                    createdAt: now.addingTimeInterval(-20),
                    finishedAt: now.addingTimeInterval(2)),
        ]

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalActivityIDs: Set(sessions.map {
                "lifecycle:\($0.provider.rawValue):\($0.id):\($0.id)"
            })).map(\.sessionID),
            ["finished-later", "created-later"])
    }

    func testEqualPriorityAndRecencyUseStableSessionIdentity() {
        let sessions = [
            session(id: "z-session", provider: .claude, status: .running,
                    turn: .working, createdAt: now),
            session(id: "a-session", provider: .codex, status: .running,
                    turn: .working, createdAt: now),
        ]

        let forward = PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalActivityIDs: []).map(\.sessionID)
        let reversed = PetActivityResolver.resolve(
            sessions: Array(sessions.reversed()),
            unreadTerminalActivityIDs: []).map(\.sessionID)

        XCTAssertEqual(forward, ["a-session", "z-session"])
        XCTAssertEqual(reversed, forward)
    }

    func testCopiedLifecycleIDAcrossSessionsDoesNotCollide() {
        let sessions = [
            session(
                id: "first", lifecycleID: "copied", provider: .codex,
                status: .running, turn: .working),
            session(
                id: "second", lifecycleID: "copied", provider: .claude,
                status: .running, turn: .working),
        ]
        var tracker = PetActivityTracker()

        tracker.observe(sessions, at: now)
        let activities = PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalActivityIDs: [])

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(Set(activities.map(\.lifecycleID)).count, 2)
    }

    func testReusedSessionNameDoesNotInheritUnreadLifecycle() {
        let old = session(
            id: "reused", lifecycleID: "old-run", provider: .codex,
            status: .running)
        let replacement = session(
            id: "reused", lifecycleID: "new-run", provider: .codex,
            status: .running)
        var tracker = PetActivityTracker()

        tracker.observe([old], at: now)
        tracker.observe([
            session(
                id: "reused", lifecycleID: "old-run", provider: .codex,
                status: .completed,
                finishedAt: now.addingTimeInterval(1)),
        ], at: now.addingTimeInterval(1))
        XCTAssertEqual(
            tracker.unreadTerminalActivityIDs,
            ["lifecycle:codex:reused:old-run"])

        tracker.observe([replacement], at: now.addingTimeInterval(2))

        XCTAssertTrue(tracker.unreadTerminalActivityIDs.isEmpty)
    }

    func testLegacyUnreadSessionMigratesOnlyToTheObservedLifecycle() {
        let oldRun = session(
            id: "legacy", lifecycleID: "old-run", provider: .codex,
            status: .completed,
            createdAt: now.addingTimeInterval(-60),
            finishedAt: now.addingTimeInterval(-1))
        let replacement = session(
            id: "replacement", lifecycleID: "new-run", provider: .codex,
            status: .completed,
            createdAt: now.addingTimeInterval(10),
            finishedAt: nil)
        var tracker = PetActivityTracker(lastObservedAt: now)

        tracker.migrateLegacyUnreadSessionIDs(
            ["legacy", "replacement"],
            sessions: [oldRun, replacement])
        tracker.observe([oldRun, replacement], at: now.addingTimeInterval(20))

        XCTAssertEqual(
            tracker.unreadTerminalActivityIDs,
            ["lifecycle:codex:legacy:old-run"])
    }

    func testLegacyUnreadDoesNotMoveToLifecycleCreatedInCutoffSecond() {
        let cutoff = Date(timeIntervalSince1970: 20_000.900)
        let replacement = session(
            id: "reused", lifecycleID: "replacement", provider: .claude,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 20_000))
        var tracker = PetActivityTracker(lastObservedAt: cutoff)

        tracker.migrateLegacyUnreadSessionIDs(
            ["reused"],
            sessions: [replacement])

        XCTAssertTrue(tracker.unreadTerminalActivityIDs.isEmpty)
    }

    func testIntentionalStopDoesNotCreateBlockedActivity() {
        let stopped = session(
            id: "stopped", provider: .claude, status: .interrupted,
            stopRequestedAt: now)
        var tracker = PetActivityTracker()

        tracker.observe([
            session(id: "stopped", provider: .claude, status: .running),
        ], at: now.addingTimeInterval(-1))
        tracker.observe([stopped], at: now)

        XCTAssertTrue(tracker.unreadTerminalActivityIDs.isEmpty)
        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: [stopped],
            unreadTerminalActivityIDs: [
                "lifecycle:claude:stopped:stopped",
            ]).isEmpty)
    }

    private func session(
        id: String,
        lifecycleID: String? = nil,
        provider: Provider,
        status: EffectiveStatus,
        turn: AgentTurnState? = nil,
        createdAt: Date? = nil,
        finishedAt: Date? = nil,
        stopRequestedAt: Date? = nil
    ) -> Session {
        Session(
            schema: 1,
            provider: provider,
            sessionName: id,
            name: id,
            displayName: nil,
            effectiveStatus: status,
            metaStatus: nil,
            agentSessionId: nil,
            projectDir: nil,
            createdAt: createdAt,
            lastCheckpointAt: nil,
            exitStatus: nil,
            finishedAt: finishedAt,
            model: nil,
            contextUsedTokens: nil,
            contextWindow: nil,
            agentTurnState: turn,
            agentTurnID: nil,
            sessionColor: nil,
            powerProtectionState: nil,
            healthReason: nil,
            healthActions: nil,
            reconcileAction: nil,
            ownershipProven: nil,
            cleanupEligible: nil,
            workerPID: nil,
            providerPID: nil,
            workerHeartbeatAt: nil,
            heartbeatFresh: nil,
            checkpointFresh: nil,
            lifecycleID: lifecycleID ?? id,
            stopRequestedAt: stopRequestedAt)
    }
}
