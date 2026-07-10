import XCTest
@testable import DetachKit

final class SessionDecodingTests: XCTestCase {
    let running = """
    {"schema":1,"provider":"claude","session_name":"claude-detached-harness-a1b2c3d4","name":"harness-a1b2c3d4","effective_status":"running","meta_status":"running","agent_session_id":"11111111-2222-4333-8444-555555555555","project_dir":"/Users/me/dev/harness","created_at":"2026-07-10T18:20:00Z","last_checkpoint_at":"2026-07-10T18:25:00Z","exit_status":null,"finished_at":null}
    """
    let corrupt = """
    {"schema":1,"provider":"codex","session_name":"codex-detached-x-ffffffff","name":"x-ffffffff","effective_status":"corrupt","meta_status":null,"agent_session_id":null,"project_dir":null,"created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
    """

    func testDecodesRunningSession() throws {
        let result = SessionListParser.parse(running)
        XCTAssertFalse(result.hadInvalidLines)
        XCTAssertEqual(result.sessions.count, 1)
        let s = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(s.provider, .claude)
        XCTAssertEqual(s.effectiveStatus, .running)
        XCTAssertEqual(s.name, "harness-a1b2c3d4")
        XCTAssertEqual(s.exitStatus, nil)
        XCTAssertNotNil(s.createdAt)
        XCTAssertEqual(s.id, "claude-detached-harness-a1b2c3d4")
    }

    func testNullFieldsDecode() {
        let result = SessionListParser.parse(corrupt)
        XCTAssertEqual(result.sessions.first?.projectDir, nil)
        XCTAssertEqual(result.sessions.first?.effectiveStatus, .corrupt)
    }

    func testUnknownStatusFallsBack() {
        let line = running.replacingOccurrences(of: "\"running\"", with: "\"weird-new-status\"")
        XCTAssertEqual(SessionListParser.parse(line).sessions.first?.effectiveStatus, .unknown)
    }

    func testInvalidLinesAreSkippedAndFlagged() {
        let result = SessionListParser.parse(running + "\nnot json\n" + corrupt)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertTrue(result.hadInvalidLines)
    }

    func testWrongSchemaIsFlagged() {
        let line = running.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2")
        let result = SessionListParser.parse(line)
        XCTAssertEqual(result.sessions.count, 0)
        XCTAssertTrue(result.hadInvalidLines)
    }
}
