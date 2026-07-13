import XCTest
@testable import DetachKit

final class SessionTransitionDetectorTests: XCTestCase {
    func testInitialObservationOnlyEstablishesBaseline() {
        var detector = SessionTransitionDetector()

        let transitions = detector.observe([
            makeSession(name: "running", status: .running),
            makeSession(name: "completed", status: .completed),
            makeSession(name: "failed", status: .failed),
            makeSession(name: "recoverable", status: .recoverable),
            makeSession(
                name: "waiting", status: .running,
                turnState: .waiting, turnID: "historical-turn"),
        ])

        XCTAssertTrue(transitions.isEmpty)
    }

    func testEmitsCompletionFailureAndRecoverableTransitions() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(name: "completed", status: .running),
            makeSession(name: "failed", status: .running),
            makeSession(name: "recoverable", status: .running),
            makeSession(name: "stopped", status: .running),
        ])

        let transitions = detector.observe([
            makeSession(name: "completed", status: .completed),
            makeSession(name: "failed", status: .failed),
            makeSession(name: "recoverable", status: .recoverable),
            makeSession(name: "stopped", status: .stopped),
        ])

        XCTAssertEqual(transitions.map(\.kind), [.completed, .failed, .recoverable])
    }

    func testRepeatedPollOfSameStateIsDeduplicated() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([makeSession(name: "work", status: .running)])
        XCTAssertEqual(
            detector.observe([makeSession(name: "work", status: .failed)]).map(\.kind),
            [.failed])

        XCTAssertTrue(detector.observe([makeSession(name: "work", status: .failed)]).isEmpty)
        XCTAssertTrue(detector.observe([makeSession(name: "work", status: .failed)]).isEmpty)
    }

    func testEmitsWhenRunningAgentFinishesATurn() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .working, turnID: "turn-1")
        ])

        let transitions = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1")
        ])

        XCTAssertEqual(transitions.map(\.kind), [.waitingForUser])
    }

    func testRepeatedWaitingPollIsDeduplicated() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .working, turnID: "turn-1")
        ])
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1")
        ])

        XCTAssertTrue(detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1")
        ]).isEmpty)
    }

    func testTransientMissingTurnDataDoesNotReplayWaitingNotification() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .working, turnID: "turn-1")
        ])
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1")
        ])
        _ = detector.observe([makeSession(name: "work", status: .running)])

        XCTAssertTrue(detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1")
        ]).isEmpty)
    }

    func testAgentSessionIDDiscoveryDoesNotReplayWaitingNotification() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .working, turnID: "turn-1", agentSessionID: nil)
        ])
        XCTAssertEqual(detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1", agentSessionID: nil)
        ]).map(\.kind), [.waitingForUser])

        XCTAssertTrue(detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1", agentSessionID: "discovered-id")
        ]).isEmpty)
    }

    func testNewCompletedTurnNotifiesWhenWorkingPollWasMissed() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-1")
        ])

        let transitions = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .waiting, turnID: "turn-2")
        ])

        XCTAssertEqual(transitions.map(\.kind), [.waitingForUser])
    }

    func testResumeWithHistoricalWaitingTurnDoesNotNotifyAgain() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                createdAt: "2026-07-13T10:00:00Z",
                turnState: .waiting, turnID: "historical-turn")
        ])

        XCTAssertTrue(detector.observe([
            makeSession(
                name: "work", status: .running,
                createdAt: "2026-07-13T11:00:00Z",
                turnState: .waiting, turnID: "historical-turn")
        ]).isEmpty)

        XCTAssertEqual(detector.observe([
            makeSession(
                name: "work", status: .running,
                createdAt: "2026-07-13T11:00:00Z",
                turnState: .waiting, turnID: "new-turn")
        ]).map(\.kind), [.waitingForUser])
    }

    func testRenamedResumeAfterListGapDoesNotReplayConversationTurn() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "old-name", status: .running,
                createdAt: "2026-07-13T10:00:00Z",
                turnState: .waiting, turnID: "historical-turn",
                agentSessionID: "conversation-id")
        ])
        _ = detector.observe([])

        XCTAssertTrue(detector.observe([
            makeSession(
                name: "new-name", status: .running,
                createdAt: "2026-07-13T11:00:00Z",
                turnState: .waiting, turnID: "historical-turn",
                agentSessionID: "conversation-id")
        ]).isEmpty)

        XCTAssertEqual(detector.observe([
            makeSession(
                name: "new-name", status: .running,
                createdAt: "2026-07-13T11:00:00Z",
                turnState: .waiting, turnID: "new-turn",
                agentSessionID: "conversation-id")
        ]).map(\.kind), [.waitingForUser])
    }

    func testInterruptedAgentTurnDoesNotNotify() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .working, turnID: "turn-1")
        ])

        XCTAssertTrue(detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .interrupted, turnID: "turn-1")
        ]).isEmpty)
    }

    func testTerminalSessionTransitionTakesPriorityOverWaitingTurn() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(
                name: "work", status: .running,
                turnState: .working, turnID: "turn-1")
        ])

        let transitions = detector.observe([
            makeSession(
                name: "work", status: .completed,
                turnState: .waiting, turnID: "turn-1")
        ])

        XCTAssertEqual(transitions.map(\.kind), [.completed])
    }

    func testNewTerminalSessionAfterBaselineEmitsTransition() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([makeSession(name: "existing", status: .running)])

        let transitions = detector.observe([
            makeSession(name: "existing", status: .running),
            makeSession(name: "quick", status: .completed),
        ])

        XCTAssertEqual(transitions.map(\.kind), [.completed])
        XCTAssertEqual(transitions.first?.session.sessionName, "quick")
    }

    func testReusedNameWithNewCreationDateIsANewLifecycle() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(name: "work", status: .completed, createdAt: "2026-07-13T10:00:00Z")
        ])

        let transitions = detector.observe([
            makeSession(name: "work", status: .completed, createdAt: "2026-07-13T11:00:00Z")
        ])

        XCTAssertEqual(transitions.map(\.kind), [.completed])
    }

    func testDeletedLifecycleDoesNotSuppressReusedNameWithoutCreationDate() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([
            makeSession(name: "work", status: .completed, createdAt: nil)
        ])
        _ = detector.observe([])

        let transitions = detector.observe([
            makeSession(name: "work", status: .completed, createdAt: nil)
        ])

        XCTAssertEqual(transitions.map(\.kind), [.completed])
    }

    func testReturningToRecoverableAfterRecoveryAttemptNotifiesAgain() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([makeSession(name: "work", status: .recoverable)])
        _ = detector.observe([makeSession(name: "work", status: .recovering)])

        XCTAssertEqual(
            detector.observe([makeSession(name: "work", status: .recoverable)]).map(\.kind),
            [.recoverable])
    }

    func testPersistentInterruptedActiveSessionIsReportedAsFailureAfterGracePoll() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([makeSession(name: "work", status: .running)])

        XCTAssertTrue(detector.observe([
            makeSession(name: "work", status: .interrupted)
        ]).isEmpty)
        XCTAssertEqual(detector.observe([
            makeSession(name: "work", status: .interrupted)
        ]).map(\.kind), [.failed])
        XCTAssertTrue(detector.observe([
            makeSession(name: "work", status: .interrupted)
        ]).isEmpty)
    }

    func testNewInterruptedSessionIsReportedAfterGracePoll() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([])

        XCTAssertTrue(detector.observe([
            makeSession(name: "quick-crash", status: .interrupted)
        ]).isEmpty)
        XCTAssertEqual(detector.observe([
            makeSession(name: "quick-crash", status: .interrupted)
        ]).map(\.kind), [.failed])
    }

    func testInterruptedThenStoppedIsTreatedAsUserRequestedStop() {
        var detector = SessionTransitionDetector()
        _ = detector.observe([makeSession(name: "work", status: .running)])
        _ = detector.observe([makeSession(name: "work", status: .interrupted)])

        XCTAssertTrue(detector.observe([
            makeSession(name: "work", status: .stopped)
        ]).isEmpty)
    }

    private func makeSession(
        name: String,
        status: EffectiveStatus,
        createdAt: String? = "2026-07-13T10:00:00Z",
        turnState: AgentTurnState? = nil,
        turnID: String? = nil,
        agentSessionID: String? = "uuid"
    ) -> Session {
        let createdAtJSON = createdAt.map { "\"\($0)\"" } ?? "null"
        let turnStateJSON = turnState.map { "\"\($0.rawValue)\"" } ?? "null"
        let turnIDJSON = turnID.map { "\"\($0)\"" } ?? "null"
        let agentSessionIDJSON = agentSessionID.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"provider":"codex","session_name":"\(name)","name":"\(name)","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":\(agentSessionIDJSON),"project_dir":"/tmp/\(name)","created_at":\(createdAtJSON),"last_checkpoint_at":null,"exit_status":null,"finished_at":null,"agent_turn_state":\(turnStateJSON),"agent_turn_id":\(turnIDJSON)}
        """
        return SessionListParser.parse(json).sessions[0]
    }
}
