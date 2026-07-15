import XCTest
@testable import DetachKit

final class SessionDecodingTests: XCTestCase {
    func testPowerProtectionStateDecodesAndRemainsBackwardCompatible() throws {
        let protectedLine = #"{"schema":1,"provider":"codex","session_name":"s1","name":"s1","effective_status":"running","power_protection_state":"protected"}"#
        let legacyLine = #"{"schema":1,"provider":"codex","session_name":"s2","name":"s2","effective_status":"running"}"#

        let result = SessionListParser.parse(protectedLine + "\n" + legacyLine)

        XCTAssertFalse(result.hadInvalidLines)
        XCTAssertEqual(result.sessions[0].powerProtectionState, .protected)
        XCTAssertNil(result.sessions[1].powerProtectionState)
    }

    let running = """
    {"schema":1,"provider":"claude","session_name":"detach-claude-harness-a1b2c3d4","name":"harness-a1b2c3d4","effective_status":"running","meta_status":"running","agent_session_id":"11111111-2222-4333-8444-555555555555","project_dir":"/Users/me/dev/harness","created_at":"2026-07-10T18:20:00Z","last_checkpoint_at":"2026-07-10T18:25:00Z","exit_status":null,"finished_at":null}
    """
    let corrupt = """
    {"schema":1,"provider":"codex","session_name":"detach-codex-x-ffffffff","name":"x-ffffffff","effective_status":"corrupt","meta_status":null,"agent_session_id":null,"project_dir":null,"created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
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
        XCTAssertEqual(s.id, "detach-claude-harness-a1b2c3d4")
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

    func testModelAndContextFieldsDecode() throws {
        let line = running.replacingOccurrences(
            of: "\"finished_at\":null",
            with: "\"finished_at\":null,\"model\":\"claude-fable-5\",\"context_used_tokens\":90000,\"context_window\":200000")
        let s = try XCTUnwrap(SessionListParser.parse(line).sessions.first)
        XCTAssertEqual(s.model, "claude-fable-5")
        XCTAssertEqual(s.contextUsedTokens, 90000)
        XCTAssertEqual(s.contextWindow, 200000)
        XCTAssertEqual(s.contextFraction.map { ($0 * 100).rounded() }, 45)
        XCTAssertEqual(s.contextSummary, L10n.format("%@ · %@%% available", "90k", "55"))
    }

    func testContextSummaryWithoutWindow() throws {
        let line = running.replacingOccurrences(
            of: "\"finished_at\":null",
            with: "\"finished_at\":null,\"model\":\"claude-fable-5\",\"context_used_tokens\":361000,\"context_window\":null")
        let s = try XCTUnwrap(SessionListParser.parse(line).sessions.first)
        XCTAssertNil(s.contextFraction)
        XCTAssertEqual(s.contextSummary, L10n.format("%@ tokens", "361k"))
    }

    func testMissingModelFieldsDecodeAsNil() throws {
        let s = try XCTUnwrap(SessionListParser.parse(running).sessions.first)
        XCTAssertNil(s.model)
        XCTAssertNil(s.contextUsedTokens)
        XCTAssertNil(s.contextSummary)
    }

    func testAgentTurnFieldsDecodeAndRemainBackwardCompatible() throws {
        let line = running.replacingOccurrences(
            of: "\"finished_at\":null",
            with: "\"finished_at\":null,\"agent_turn_state\":\"waiting\",\"agent_turn_id\":\"opaque-turn-id\"")
        let waiting = try XCTUnwrap(SessionListParser.parse(line).sessions.first)
        XCTAssertEqual(waiting.agentTurnState, .waiting)
        XCTAssertEqual(waiting.agentTurnID, "opaque-turn-id")

        let legacy = try XCTUnwrap(SessionListParser.parse(running).sessions.first)
        XCTAssertNil(legacy.agentTurnState)
        XCTAssertNil(legacy.agentTurnID)
    }

    func testSessionColorDecodesAndNormalizesHex() throws {
        let line = running.replacingOccurrences(
            of: "\"finished_at\":null",
            with: "\"finished_at\":null,\"session_color\":\"#1aB2c3\"")
        let session = try XCTUnwrap(SessionListParser.parse(line).sessions.first)
        let color = try XCTUnwrap(session.sessionColor)
        XCTAssertEqual(color.hex, "#1AB2C3")
        XCTAssertEqual(color.red, 0x1a)
        XCTAssertEqual(color.green, 0xb2)
        XCTAssertEqual(color.blue, 0xc3)

        let legacy = try XCTUnwrap(SessionListParser.parse(running).sessions.first)
        XCTAssertNil(legacy.sessionColor)
    }

    func testInvalidSessionColorRejectsOnlyThatLine() {
        let invalidColor = running.replacingOccurrences(
            of: "\"finished_at\":null",
            with: "\"finished_at\":null,\"session_color\":\"blue\"")
        let result = SessionListParser.parse(invalidColor + "\n" + corrupt)
        XCTAssertTrue(result.hadInvalidLines)
        XCTAssertEqual(result.sessions, SessionListParser.parse(corrupt).sessions)
        XCTAssertNil(SessionColor(hex: "blue"))
        XCTAssertNil(SessionColor(hex: "#+12345"))
    }

    func testUnknownAgentTurnStateFallsBack() throws {
        let line = running.replacingOccurrences(
            of: "\"finished_at\":null",
            with: "\"finished_at\":null,\"agent_turn_state\":\"new-state\",\"agent_turn_id\":\"turn\"")
        let session = try XCTUnwrap(SessionListParser.parse(line).sessions.first)
        XCTAssertEqual(session.agentTurnState, .unknown)
    }

    func testWrongSchemaIsFlagged() {
        let line = running.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2")
        let result = SessionListParser.parse(line)
        XCTAssertEqual(result.sessions.count, 0)
        XCTAssertTrue(result.hadInvalidLines)
    }
}
