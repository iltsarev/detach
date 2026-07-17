import Foundation
import XCTest
@testable import DetachApp
@testable import DetachKit

final class MenuBarPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter()
        .date(from: "2026-07-15T12:00:00Z")!

    func testProtectedStateShowsActiveIconWithSessionCount() {
        let presentation = makePresentation(
            powerState: "protected",
            sessions: [runningSession(id: "a"), runningSession(id: "b")])

        XCTAssertEqual(presentation.icon, .active(sessionCount: 2))
        XCTAssertEqual(presentation.power.reason, .activeSessions(2))
        XCTAssertEqual(presentation.ageSeconds, 30)
        XCTAssertNil(presentation.problem)
    }

    func testSessionCountCanBeHidden() {
        let presentation = makePresentation(
            powerState: "protected",
            sessions: [runningSession(id: "a")],
            showsSessionCount: false)

        XCTAssertEqual(presentation.icon, .active(sessionCount: nil))
    }

    func testStaleHeartbeatIsUnknownRegardlessOfSessions() {
        let presentation = makePresentation(
            powerState: "protected",
            heartbeatFresh: false,
            sessions: [runningSession(id: "a")])

        XCTAssertEqual(presentation.icon, .unknown)
        XCTAssertEqual(presentation.power.reason, .noFreshReport)
        XCTAssertNil(presentation.ageSeconds)
    }

    func testApprovalProblemShowsAttentionAndSystemSettingsAction() {
        let presentation = makePresentation(
            powerState: "allowed",
            helperStatus: .requiresApproval)

        XCTAssertEqual(presentation.icon, .attention)
        XCTAssertEqual(presentation.problem, .openSystemSettings)
    }

    func testActiveProtectionOutranksPendingApprovalIcon() {
        // Protection is genuinely held; the icon stays truthful while the
        // problem row still offers the approval action.
        let presentation = makePresentation(
            powerState: "protected",
            watchdogStatus: .requiresApproval,
            sessions: [runningSession(id: "a")])

        XCTAssertEqual(presentation.icon, .active(sessionCount: 1))
        XCTAssertEqual(presentation.problem, .openSystemSettings)
    }

    func testUnreachableHelperOffersOpeningDetach() {
        let presentation = makePresentation(
            powerState: "unavailable",
            helperStatus: .unavailable)

        XCTAssertEqual(presentation.icon, .attention)
        XCTAssertEqual(presentation.problem, .openDetach)
    }

    func testAllActionRequiredStatesOfferTheEquivalentMenuAction() {
        XCTAssertEqual(
            makePresentation(
                powerState: "allowed",
                watchdogStatus: .notRegistered).problem,
            .openDetach)
        XCTAssertEqual(
            makePresentation(
                powerState: "allowed",
                distributionMatchesBundle: false).problem,
            .openDetach)
        XCTAssertEqual(
            makePresentation(
                powerState: "protected",
                heartbeatFresh: false).problem,
            .openDetach)
    }

    func testLowBatteryIcon() {
        let presentation = makePresentation(powerState: "low_battery")

        XCTAssertEqual(presentation.icon, .lowBattery)
        XCTAssertEqual(presentation.power.reason, .lowBattery)
    }

    func testAllowedStateWithRunningSessionsNamesTheMismatch() {
        // Heartbeat lag right after a session starts: the menu must not say
        // "No active agent sessions" above a listed running session.
        let presentation = makePresentation(
            powerState: "allowed",
            sessions: [runningSession(id: "a")])

        XCTAssertEqual(presentation.power.reason, .sessionsNotHolding(1))
        XCTAssertEqual(presentation.sessions.count, 1)
    }

    func testHeaderTextJoinsStateReasonAndFreshness() {
        let presentation = makePresentation(
            powerState: "protected",
            sessions: [runningSession(id: "a"), runningSession(id: "b")])

        XCTAssertEqual(
            presentation.headerText,
            "Mac stays awake · Held awake by active sessions: 2 · checked 30 s ago")
    }

    func testHeaderTextOmitsFreshnessWhenHeartbeatIsStale() {
        let presentation = makePresentation(
            powerState: "protected",
            heartbeatFresh: false)

        XCTAssertEqual(
            presentation.headerText,
            "Sleep status unknown · No fresh report from the background monitor")
    }

    func testAnswerReadySessionsComeFirstAndListCapsAtSix() {
        var sessions = (0..<7).map {
            runningSession(
                id: "s\($0)",
                createdAt: "2026-07-15T0\($0):00:00Z")
        }
        sessions.append(runningSession(
            id: "waiting",
            createdAt: "2026-07-15T00:30:00Z",
            waiting: true))

        let presentation = makePresentation(
            powerState: "protected", sessions: sessions)

        XCTAssertEqual(presentation.sessions.count, 6)
        XCTAssertEqual(presentation.sessions.first?.id, "detach-codex-waiting")
        XCTAssertTrue(presentation.sessions.first?.answerReady == true)
        XCTAssertEqual(presentation.hiddenSessionCount, 2)
    }

    func testFinishedSessionsAreNotListed() {
        let presentation = makePresentation(
            powerState: "allowed",
            sessions: [finishedSession(id: "old")])

        XCTAssertTrue(presentation.sessions.isEmpty)
        XCTAssertEqual(presentation.power.reason, .noActiveSessions)
    }

    // MARK: - Session dot

    func testRunningSessionsColorTheDotGreen() {
        let presentation = makePresentation(
            powerState: "protected",
            sessions: [runningSession(id: "a")])

        XCTAssertEqual(presentation.sessionDot, .working)
    }

    func testWaitingSessionOutranksWorkingOnes() {
        let presentation = makePresentation(
            powerState: "protected",
            sessions: [
                runningSession(id: "a"),
                runningSession(id: "b", waiting: true),
            ])

        XCTAssertEqual(presentation.sessionDot, .answerReady)
    }

    func testNoRunningSessionsMeansNoSessionDot() {
        XCTAssertEqual(
            makePresentation(powerState: "protected").sessionDot, .none)
        XCTAssertEqual(
            makePresentation(
                powerState: "allowed",
                sessions: [finishedSession(id: "old")]).sessionDot,
            .none)
    }

    func testSessionDotSurvivesUnprotectedAndUnknownPowerStates() {
        // The dot reports sessions, not protection: it stays on the dimmed
        // and outline shapes.
        XCTAssertEqual(
            makePresentation(
                powerState: "allowed",
                sessions: [runningSession(id: "a")]).sessionDot,
            .working)
        XCTAssertEqual(
            makePresentation(
                powerState: "protected",
                heartbeatFresh: false,
                sessions: [runningSession(id: "a", waiting: true)]).sessionDot,
            .answerReady)
    }

    func testBadgeStatesSuppressTheSessionDot() {
        // "!" and the dot share the glyph's corner; the warning wins.
        let attention = makePresentation(
            powerState: "unavailable",
            helperStatus: .unavailable,
            sessions: [runningSession(id: "a", waiting: true)])
        XCTAssertEqual(attention.icon, .attention)
        XCTAssertEqual(attention.sessionDot, .none)

        let lowBattery = makePresentation(
            powerState: "low_battery",
            sessions: [runningSession(id: "a")])
        XCTAssertEqual(lowBattery.icon, .lowBattery)
        XCTAssertEqual(lowBattery.sessionDot, .none)
    }

    // MARK: - Fixtures

    private func makePresentation(
        powerState: String,
        heartbeatFresh: Bool = true,
        helperStatus: PowerHelperRegistrationStatus = .enabled,
        watchdogStatus: WatchdogStatus = .enabled,
        sessions: [Session] = [],
        showsSessionCount: Bool = true,
        distributionMatchesBundle: Bool = true
    ) -> MenuBarPresentation {
        let heartbeat = PowerHeartbeatSnapshot(
            statusURL: URL(fileURLWithPath: "/tmp/watchdog-status.json"),
            state: "ok",
            powerState: PowerProtectionState(rawValue: powerState) ?? .unknown,
            checkedAt: heartbeatFresh
                ? now.addingTimeInterval(-30)
                : now.addingTimeInterval(-600),
            isFresh: heartbeatFresh)
        return MenuBarPresentation(
            heartbeat: heartbeat,
            sessions: sessions,
            helperStatus: helperStatus,
            watchdogStatus: watchdogStatus,
            distributionMatchesBundle: distributionMatchesBundle,
            showsSessionCount: showsSessionCount,
            now: now)
    }

    private func runningSession(
        id: String,
        createdAt: String = "2026-07-15T10:00:00Z",
        waiting: Bool = false
    ) -> Session {
        session(id: id, status: "running", createdAt: createdAt,
                turnState: waiting ? "waiting" : nil)
    }

    private func finishedSession(id: String) -> Session {
        session(id: id, status: "completed",
                createdAt: "2026-07-15T09:00:00Z", turnState: nil)
    }

    private func session(
        id: String,
        status: String,
        createdAt: String,
        turnState: String?
    ) -> Session {
        let turnField = turnState.map {
            #","agent_turn_state":"\#($0)""#
        } ?? ""
        let line = """
        {"schema":1,"provider":"codex","session_name":"detach-codex-\(id)",\
        "name":"\(id)","effective_status":"\(status)","meta_status":"\(status)",\
        "agent_session_id":"\(id)","project_dir":"/tmp/p",\
        "created_at":"\(createdAt)","last_checkpoint_at":null,\
        "exit_status":null,"finished_at":null\(turnField)}
        """
        let parsed = SessionListParser.parse(line)
        precondition(!parsed.sessions.isEmpty, "fixture must parse")
        return parsed.sessions[0]
    }
}
