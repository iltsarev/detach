import XCTest
@testable import DetachKit

final class DetachStateTests: XCTestCase {
    func testMetadataValidationKeepsTheExistingSchemaContract() throws {
        let data = Data(#"{"schema":1,"session_name":"detach-codex-project","project_dir":"/tmp/project"}"#.utf8)

        XCTAssertTrue(SessionMetadataDocument.isUsable(
            data, expectedSessionName: "detach-codex-project"))
        XCTAssertFalse(SessionMetadataDocument.isUsable(
            data, expectedSessionName: "detach-codex-other"))
        XCTAssertFalse(SessionMetadataDocument.isUsable(
            Data(#"{"schema":2,"session_name":"detach-codex-project","project_dir":"/tmp/project"}"#.utf8),
            expectedSessionName: "detach-codex-project"))
    }

    func testMetadataPatchPreservesUnknownFieldsAndNullSemantics() throws {
        let original = Data(#"{"schema":1,"session_name":"s","project_dir":"/tmp/p","run_token":"current","future":{"nested":true},"exit_status":null}"#.utf8)

        let updated = try SessionMetadataDocument.patch(
            original,
            expectedRunToken: "current",
            changes: [
                .init(key: "status", value: .string("running")),
                .init(key: "worker_started_at", value: .string("2026-07-15T10:00:00Z")),
            ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updated) as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "running")
        XCTAssertEqual(object["worker_started_at"] as? String, "2026-07-15T10:00:00Z")
        XCTAssertTrue(object["exit_status"] is NSNull)
        XCTAssertEqual((object["future"] as? [String: Bool])?["nested"], true)
    }

    func testMetadataPatchRejectsAStaleRunTokenWithoutProducingOutput() throws {
        let original = Data(#"{"schema":1,"session_name":"s","project_dir":"/tmp/p","run_token":"current","status":"running"}"#.utf8)

        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            original,
            expectedRunToken: "stale",
            changes: [.init(key: "status", value: .string("failed"))])) { error in
                XCTAssertEqual(error as? DetachStateError, .staleRunToken)
            }
    }

    func testMetadataReadUsesOrderedFallbacksAndPreservesFalseAndZero() throws {
        let data = Data(#"{"primary":null,"legacy":"value","flag":false,"count":0}"#.utf8)

        XCTAssertEqual(
            try SessionMetadataDocument.scalar(in: data, paths: ["primary", "legacy"]),
            .string("value"))
        XCTAssertEqual(try SessionMetadataDocument.scalar(in: data, paths: ["flag"]), .bool(false))
        XCTAssertEqual(try SessionMetadataDocument.scalar(in: data, paths: ["count"]), .integer(0))
        XCTAssertNil(try SessionMetadataDocument.scalar(in: data, paths: ["missing"]))
    }

    func testMetadataReadSupportsDottedNestedPaths() throws {
        let data = Data(#"{"payload":{"id":null,"session_id":"nested"},"fallback":"root"}"#.utf8)

        XCTAssertEqual(
            try SessionMetadataDocument.scalar(
                in: data,
                paths: ["payload.id", "payload.session_id", "fallback"]),
            .string("nested"))
    }

    func testMetadataSessionMatchDefaultsProviderAndComparesSessionIgnoringCase() throws {
        let legacyCodex = Data(#"{"codex_session_id":"ABC-123"}"#.utf8)
        let claude = Data(#"{"provider":"claude","agent_session_id":"Claude-ID"}"#.utf8)

        XCTAssertTrue(SessionMetadataDocument.matchesSession(
            legacyCodex,
            provider: .codex,
            expectedSessionID: "abc-123"))
        XCTAssertFalse(SessionMetadataDocument.matchesSession(
            legacyCodex,
            provider: .claude,
            expectedSessionID: "abc-123"))
        XCTAssertTrue(SessionMetadataDocument.matchesSession(
            claude,
            provider: .claude,
            expectedSessionID: "claude-id"))
    }

    func testCodexJSONLValidationChecksEveryRecordAndRootIdentity() throws {
        let valid = Data("""
        {"payload":{"id":"session-1"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """.utf8)
        let foreign = Data("""
        {"payload":{"id":"session-2"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """.utf8)
        let malformed = Data("""
        {"payload":{"id":"session-1"}}
        not-json
        """.utf8)

        XCTAssertTrue(TranscriptDocument.isValid(
            valid, provider: .codex, expectedSessionID: "session-1"))
        XCTAssertFalse(TranscriptDocument.isValid(
            foreign, provider: .codex, expectedSessionID: "session-1"))
        XCTAssertFalse(TranscriptDocument.isValid(
            malformed, provider: .codex, expectedSessionID: "session-1"))
    }

    func testClaudeJSONLValidationRejectsForeignSessionRecords() throws {
        let valid = Data("""
        {"sessionId":"session-1","type":"user"}
        {"sessionId":"session-1","type":"assistant"}
        """.utf8)
        let foreign = Data("""
        {"sessionId":"session-1","type":"user"}
        {"sessionId":"session-2","type":"assistant"}
        """.utf8)

        XCTAssertTrue(TranscriptDocument.isValid(
            valid, provider: .claude, expectedSessionID: "session-1"))
        XCTAssertFalse(TranscriptDocument.isValid(
            foreign, provider: .claude, expectedSessionID: "session-1"))
    }

    func testJSONLValidationStreamsGeneratedChunksWithoutRetainingTheTranscript() throws {
        let root = Data(#"{"payload":{"id":"session-1"}}"#.utf8)
        let event = Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8)
        var chunkIndex = 0
        let eventCount = 100_000

        let valid = try TranscriptDocument.isValid(
            provider: .codex,
            expectedSessionID: "session-1"
        ) {
            defer { chunkIndex += 1 }
            switch chunkIndex {
            case 0:
                return root + Data("\n".utf8)
            case 1...eventCount:
                return event + Data("\n".utf8)
            default:
                return nil
            }
        }

        XCTAssertTrue(valid)
        XCTAssertEqual(chunkIndex, eventCount + 2)
    }

    func testJSONLStreamingValidationHandlesChunkBoundariesCRLFAndNoFinalNewline() throws {
        let chunks = [
            Data("  \r\n{\"sessionId\":\"sess".utf8),
            Data("ion-1\",\"type\":\"user\"}\r".utf8),
            Data("\n{\"sessionId\":\"session-1\",\"type\":\"assistant\"}".utf8),
        ]
        var index = 0

        let valid = try TranscriptDocument.isValid(
            provider: .claude,
            expectedSessionID: "session-1"
        ) {
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            return chunks[index]
        }

        XCTAssertTrue(valid)
        XCTAssertEqual(index, chunks.count)
    }

    func testJSONLStreamingValidationRejectsALateForeignClaudeRecord() throws {
        let chunks = [
            Data("{\"sessionId\":\"session-1\"}\n".utf8),
            Data("{\"sessionId\":\"session-1\"}\n".utf8),
            Data("{\"sessionId\":\"session-2\"}\n".utf8),
        ]
        var index = 0

        let valid = try TranscriptDocument.isValid(
            provider: .claude,
            expectedSessionID: "session-1"
        ) {
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            return chunks[index]
        }

        XCTAssertFalse(valid)
    }

    func testJSONLFirstScalarSkipsInvalidAndNonMatchingRecords() throws {
        let data = Data("""
        not-json
        {"payload":{"id":null}}
        ["not", "an", "object"]
        {"payload":{"session_id":"session-1"}}
        {"payload":{"id":"session-2"}}
        """.utf8)

        XCTAssertEqual(
            try TranscriptDocument.firstScalar(
                in: data,
                paths: ["payload.id", "payload.session_id"]),
            .string("session-1"))
    }

    func testCodexSummaryToleratesPartialTailAndTracksLatestTurn() throws {
        let tail = Data("""
        partial-prefix}
        {"payload":{"model":"gpt-test"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"output_tokens":30},"model_context_window":1000}}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        partial-suffix
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: tail, provider: .codex),
            TranscriptSummary(
                model: "gpt-test",
                contextUsed: 150,
                contextWindow: 1000,
                agentTurnState: .waiting,
                agentTurnID: "turn-1"))
    }

    func testClaudeSummaryIgnoresSidechainsAndToolResultUsers() throws {
        let tail = Data("""
        {"type":"user","uuid":"real-user","message":{"role":"user","content":"go"}}
        {"type":"user","uuid":"tool-result","message":{"role":"user","content":[{"type":"tool_result"}]}}
        {"type":"system","subtype":"turn_duration","uuid":"sidechain","isSidechain":true}
        {"type":"assistant","message":{"model":"claude-test","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}}
        {"type":"system","subtype":"turn_duration","uuid":"real-user"}
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: tail, provider: .claude),
            TranscriptSummary(
                model: "claude-test",
                contextUsed: 60,
                contextWindow: nil,
                agentTurnState: .waiting,
                agentTurnID: "real-user"))
    }
}
