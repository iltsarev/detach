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
            unreadTerminalSessionIDs: ["ready", "blocked"])

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
            unreadTerminalSessionIDs: []).isEmpty)
    }

    func testTerminalProblemOutranksStaleCompletedTurn() {
        let session = session(
            id: "broken", provider: .claude, status: .recoverable,
            turn: .waiting)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalSessionIDs: [session.id]).map(\.state), [.blocked])
    }

    func testStructuredInputRequestCreatesNeedsInputActivity() {
        let session = session(
            id: "question", provider: .claude, status: .running,
            turn: .needsInput)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalSessionIDs: []).map(\.state), [.needsInput])
    }

    func testStructuredInputOutranksRecoverableWorkerHealth() {
        let session = session(
            id: "question", provider: .claude, status: .recoverable,
            turn: .needsInput)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalSessionIDs: [session.id]).map(\.state), [.needsInput])
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
            unreadTerminalSessionIDs: []).map(\.sessionID), ["answer", "work"])
    }

    func testFirstSnapshotDoesNotAnnounceHistoricalTerminalSessions() {
        var tracker = PetActivityTracker()
        tracker.observe([
            session(id: "old", provider: .codex, status: .completed,
                    finishedAt: now.addingTimeInterval(-3_600)),
        ], at: now)

        XCTAssertTrue(tracker.unreadTerminalSessionIDs.isEmpty)
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

        XCTAssertEqual(tracker.unreadTerminalSessionIDs, ["work"])
        tracker.acknowledge(sessionID: "work")
        XCTAssertTrue(tracker.unreadTerminalSessionIDs.isEmpty)
    }

    func testCompletionWhileAppWasAwayBecomesReady() {
        var tracker = PetActivityTracker(lastObservedAt: now)
        tracker.observe([
            session(id: "away", provider: .codex, status: .completed,
                    finishedAt: now.addingTimeInterval(30)),
        ], at: now.addingTimeInterval(60))

        XCTAssertEqual(tracker.unreadTerminalSessionIDs, ["away"])
    }

    func testStoppedSessionNeverCreatesPetActivity() {
        let stopped = session(id: "stopped", provider: .claude, status: .stopped)
        XCTAssertNil(PetActivityTracker.terminalActivityState(for: stopped))
        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: [stopped],
            unreadTerminalSessionIDs: [stopped.id]).isEmpty)
    }

    func testFreshSessionWithoutConfirmedTurnStaysIdle() {
        let sessions = [
            session(id: "starting", provider: .codex, status: .starting),
            session(id: "prompt", provider: .claude, status: .running),
            session(id: "recovering", provider: .codex, status: .recovering),
        ]

        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: sessions,
            unreadTerminalSessionIDs: []).isEmpty)
    }

    func testConfirmedWorkingTurnUsesRunningActivity() {
        let session = session(
            id: "work", provider: .claude, status: .running, turn: .working)

        XCTAssertEqual(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalSessionIDs: []).map(\.state), [.running])
    }

    func testStaleWorkingTurnOnTerminalSessionDoesNotLookActive() {
        let session = session(
            id: "done", provider: .codex, status: .completed, turn: .working)

        XCTAssertTrue(PetActivityResolver.resolve(
            sessions: [session],
            unreadTerminalSessionIDs: []).isEmpty)
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
            unreadTerminalSessionIDs: Set(sessions.map(\.id))).map(\.sessionID),
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
            unreadTerminalSessionIDs: []).map(\.sessionID)
        let reversed = PetActivityResolver.resolve(
            sessions: Array(sessions.reversed()),
            unreadTerminalSessionIDs: []).map(\.sessionID)

        XCTAssertEqual(forward, ["a-session", "z-session"])
        XCTAssertEqual(reversed, forward)
    }

    private func session(
        id: String,
        provider: Provider,
        status: EffectiveStatus,
        turn: AgentTurnState? = nil,
        createdAt: Date? = nil,
        finishedAt: Date? = nil
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
            checkpointFresh: nil)
    }
}
