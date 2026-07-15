import XCTest
@testable import DetachKit

final class SessionPresentationTests: XCTestCase {
    func make(
        _ status: EffectiveStatus,
        uuid: String? = "u",
        project: String? = "/tmp/proj",
        turnState: AgentTurnState? = nil,
        powerState: PowerProtectionState? = nil
    ) -> Session {
        let turnStateJSON = turnState.map { "\"\($0.rawValue)\"" } ?? "null"
        let powerStateJSON = powerState.map { "\"\($0.rawValue)\"" } ?? "null"
        let json = """
        {"schema":1,"provider":"claude","session_name":"detach-claude-proj-abcd1234","name":"proj-abcd1234","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":\(uuid.map { "\"\($0)\"" } ?? "null"),"project_dir":\(project.map { "\"\($0)\"" } ?? "null"),"created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null,"agent_turn_state":\(turnStateJSON),"agent_turn_id":"turn","power_protection_state":\(powerStateJSON)}
        """
        return SessionListParser.parse(json).sessions[0]
    }

    func testSections() {
        XCTAssertEqual(
            SessionSection.allCases,
            [.answerReady, .active, .finished, .problems])
        XCTAssertEqual(make(.running).section, .active)
        XCTAssertEqual(make(.starting).section, .active)
        XCTAssertEqual(make(.recovering).section, .active)
        XCTAssertEqual(make(.completed).section, .finished)
        XCTAssertEqual(make(.stopped).section, .finished)
        XCTAssertEqual(make(.failed).section, .finished)
        XCTAssertEqual(make(.recoverable).section, .problems)
        XCTAssertEqual(make(.collision).section, .problems)
    }

    func testActions() {
        XCTAssertEqual(make(.running).availableActions, [.attach, .stop])
        XCTAssertEqual(make(.completed).availableActions, [.resume, .delete])
        XCTAssertEqual(make(.completed, uuid: nil).availableActions, [.delete])
        XCTAssertEqual(make(.stopped).availableActions, [.resume, .delete])
        XCTAssertEqual(make(.recoverable).availableActions, [.recover, .delete])
        XCTAssertEqual(make(.orphaned, uuid: nil).availableActions, [.delete])
        XCTAssertEqual(make(.corrupt).availableActions, [.delete])
        XCTAssertEqual(make(.collision).availableActions, [])
    }

    func testDisplayTitle() {
        XCTAssertEqual(make(.running, project: "/Users/me/dev/harness").displayTitle, "harness")
        XCTAssertEqual(make(.corrupt, project: nil).displayTitle, "proj-abcd1234")
    }

    func testWaitingTurnHasAttentionStatusWhileRemainingActive() {
        let waiting = make(.running, turnState: .waiting)
        XCTAssertTrue(waiting.isWaitingForUser)
        XCTAssertTrue(waiting.isLive)
        XCTAssertEqual(waiting.displayStatus, L10n.string("answer ready"))
        XCTAssertEqual(waiting.section, .answerReady)
        XCTAssertEqual(waiting.availableActions, [.attach, .stop])
    }

    func testAnswerReadySectionDoesNotChangeSessionLifecycle() {
        XCTAssertEqual(make(.running, turnState: .working).section, .active)
        XCTAssertTrue(make(.starting, turnState: .waiting).isLive)
        XCTAssertEqual(make(.starting, turnState: .waiting).section, .active)
        XCTAssertFalse(make(.completed, turnState: .waiting).isLive)
        XCTAssertEqual(make(.completed, turnState: .waiting).section, .finished)
    }

    func testPowerStatusUsesExplicitReadableLabels() {
        XCTAssertEqual(
            make(.running, powerState: .protected).powerProtectionLabel,
            L10n.string("Mac stays awake"))
        XCTAssertEqual(
            make(.running, powerState: .allowed).powerProtectionLabel,
            L10n.string("Mac can sleep"))
        XCTAssertEqual(
            make(.running, powerState: .lowBattery).powerProtectionLabel,
            L10n.string("Mac can sleep: low battery"))
        XCTAssertEqual(
            make(.running, powerState: .unavailable).powerProtectionLabel,
            L10n.string("Sleep protection unavailable"))
        XCTAssertEqual(
            make(.running).powerProtectionLabel,
            L10n.string("Sleep status unknown"))
    }
}
