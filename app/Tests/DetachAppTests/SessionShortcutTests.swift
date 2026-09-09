import XCTest
@testable import DetachApp
@testable import DetachKit

@MainActor
final class SessionShortcutTests: XCTestCase {
    func testAssignsOnlyWorkingAndAnswerReadySessions() {
        let registry = SessionShortcutRegistry()

        registry.reconcile([
            session(id: "starting", status: "starting"),
            session(id: "waiting", status: "running", turnState: "waiting"),
            session(id: "hung", status: "hung"),
            session(id: "done", status: "completed"),
        ])

        XCTAssertEqual(registry.slot(for: "starting"), 1)
        XCTAssertEqual(registry.slot(for: "waiting"), 2)
        XCTAssertNil(registry.slot(for: "hung"))
        XCTAssertNil(registry.slot(for: "done"))
    }

    func testKeepsSlotsAcrossOrderAndSectionChanges() {
        let registry = SessionShortcutRegistry()
        registry.reconcile([
            session(id: "first", status: "running"),
            session(id: "second", status: "running", turnState: "waiting"),
        ])

        registry.reconcile([
            session(id: "second", status: "running"),
            session(id: "first", status: "running", turnState: "waiting"),
        ])

        XCTAssertEqual(registry.slot(for: "first"), 1)
        XCTAssertEqual(registry.slot(for: "second"), 2)
        XCTAssertEqual(registry.sessionID(for: 1), "first")
        XCTAssertEqual(registry.sessionID(for: 2), "second")
    }

    func testWaitingSessionReceivesTheFirstFreedSlot() {
        let registry = SessionShortcutRegistry()
        registry.reconcile((1...10).map {
            session(id: "session-\($0)", status: "running")
        })

        XCTAssertEqual(registry.assignments.count, 9)
        XCTAssertNil(registry.slot(for: "session-10"))

        registry.reconcile((1...10).map {
            session(
                id: "session-\($0)",
                status: $0 == 3 ? "stopped" : "running")
        })

        XCTAssertNil(registry.slot(for: "session-3"))
        XCTAssertEqual(registry.slot(for: "session-10"), 3)
        XCTAssertEqual(registry.sessionID(for: 3), "session-10")
    }

    func testRefreshesMenuTitleWithoutChangingTheSlot() {
        let registry = SessionShortcutRegistry()
        registry.reconcile([
            session(id: "work", status: "running", displayName: "First title"),
        ])

        registry.reconcile([
            session(id: "work", status: "running", displayName: "New title"),
        ])

        XCTAssertEqual(registry.assignments, [
            SessionShortcutAssignment(
                sessionID: "work",
                displayTitle: "New title",
                slot: 1),
        ])
    }

    func testFormatsBadgeAndAccessibleRowLabel() {
        XCTAssertEqual(SessionShortcutPresentation.badge(slot: 7), "⌘7")
        XCTAssertEqual(
            SessionShortcutPresentation.accessibilityLabel(
                title: "Deploy",
                slot: 7),
            L10n.format("%@, Command-%d", "Deploy", 7))
        XCTAssertEqual(
            SessionShortcutPresentation.accessibilityLabel(
                title: "Deploy",
                slot: nil),
            "Deploy")
    }
}

private func session(
    id: String,
    status: String,
    turnState: String? = nil,
    displayName: String? = nil
) -> Session {
    let turnStateField = turnState.map {
        #","agent_turn_state":"\#($0)""#
    } ?? ""
    let displayNameField = displayName.map {
        #","display_name":"\#($0)""#
    } ?? ""
    let json = #"{"schema":1,"provider":"codex","session_name":"\#(id)","name":"\#(id)","effective_status":"\#(status)","meta_status":null,"agent_session_id":"agent","project_dir":"/tmp/\#(id)","created_at":"2026-09-01T10:00:00Z","last_checkpoint_at":null,"exit_status":null,"finished_at":null\#(turnStateField)\#(displayNameField)}"#
    return SessionListParser.parse(json).sessions[0]
}
