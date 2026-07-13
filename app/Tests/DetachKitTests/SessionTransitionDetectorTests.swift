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
        createdAt: String? = "2026-07-13T10:00:00Z"
    ) -> Session {
        let createdAtJSON = createdAt.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"provider":"codex","session_name":"\(name)","name":"\(name)","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":"uuid","project_dir":"/tmp/\(name)","created_at":\(createdAtJSON),"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """
        return SessionListParser.parse(json).sessions[0]
    }
}
