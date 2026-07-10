import XCTest
@testable import DetachKit

final class SessionPresentationTests: XCTestCase {
    func make(_ status: EffectiveStatus, uuid: String? = "u", project: String? = "/tmp/proj") -> Session {
        let json = """
        {"schema":1,"provider":"claude","session_name":"claude-detached-proj-abcd1234","name":"proj-abcd1234","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":\(uuid.map { "\"\($0)\"" } ?? "null"),"project_dir":\(project.map { "\"\($0)\"" } ?? "null"),"created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """
        return SessionListParser.parse(json).sessions[0]
    }

    func testSections() {
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
}
