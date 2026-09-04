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
        XCTAssertFalse(SessionMetadataDocument.isUsable(
            Data(#"{"schema":1,"session_name":"detach-codex-project","project_dir":null}"#.utf8),
            expectedSessionName: "detach-codex-project"))
        XCTAssertFalse(SessionMetadataDocument.isUsable(
            Data(#"{"schema":true,"session_name":"detach-codex-project","project_dir":"/tmp/project"}"#.utf8),
            expectedSessionName: "detach-codex-project"))
        XCTAssertFalse(SessionMetadataDocument.isUsable(
            Data("not-json".utf8),
            expectedSessionName: "detach-codex-project"))
    }

    func testRecoveryHandoffMetadataFieldsKeepTheirJSONTypes() throws {
        let base: [String: Any] = [
            "schema": 1,
            "session_name": "detach-codex-project",
            "project_dir": "/tmp/project",
        ]
        let validFields: [[String: Any]] = [
            [:],
            [
                "preserve_recovery_until_ready": NSNull(),
                "runtime_ready_at": NSNull(),
                "runtime_shutdown_observed_at": NSNull(),
            ],
            [
                "preserve_recovery_until_ready": true,
                "runtime_ready_at": "2026-09-04T12:00:00Z",
                "runtime_shutdown_observed_at": "2026-09-04T13:00:00Z",
            ],
        ]
        for fields in validFields {
            let data = try JSONSerialization.data(
                withJSONObject: base.merging(fields) { _, new in new })
            XCTAssertTrue(SessionMetadataDocument.isUsable(
                data, expectedSessionName: "detach-codex-project"))
        }

        let invalidFields: [(String, Any)] = [
            ("preserve_recovery_until_ready", "false"),
            ("preserve_recovery_until_ready", 0),
            ("runtime_ready_at", false),
            ("runtime_ready_at", ["timestamp"]),
            ("runtime_shutdown_observed_at", 0),
            ("runtime_shutdown_observed_at", ["value": "timestamp"]),
        ]
        for (field, value) in invalidFields {
            let data = try JSONSerialization.data(
                withJSONObject: base.merging([field: value]) { _, new in new })
            XCTAssertFalse(SessionMetadataDocument.isUsable(
                data, expectedSessionName: "detach-codex-project"))
        }

        XCTAssertThrowsError(try SessionMetadataDocument.create(changes: [
            .init(
                key: "preserve_recovery_until_ready",
                value: .string("false")),
        ])) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidMetadata)
        }
        let corrupt = try JSONSerialization.data(withJSONObject: base.merging([
            "runtime_ready_at": false,
        ]) { _, new in new })
        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            corrupt,
            changes: [.init(key: "status", value: .string("running"))]
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidMetadata)
        }
        XCTAssertNoThrow(try SessionMetadataDocument.patch(
            corrupt,
            changes: [.init(key: "runtime_ready_at", value: .null)]))
    }

    func testMetadataCreateRoundTripsEverySupportedScalar() throws {
        let data = try SessionMetadataDocument.create(changes: [
            .init(key: "text", value: .string("value")),
            .init(key: "integer", value: .integer(-7)),
            .init(key: "number", value: .number(1.5)),
            .init(key: "flag", value: .bool(true)),
            .init(key: "nothing", value: .null),
        ])

        XCTAssertEqual(try SessionMetadataDocument.scalar(in: data, paths: ["text"]), .string("value"))
        XCTAssertEqual(try SessionMetadataDocument.scalar(in: data, paths: ["integer"]), .integer(-7))
        XCTAssertEqual(try SessionMetadataDocument.scalar(in: data, paths: ["number"]), .number(1.5))
        XCTAssertEqual(try SessionMetadataDocument.scalar(in: data, paths: ["flag"]), .bool(true))
        XCTAssertNil(try SessionMetadataDocument.scalar(in: data, paths: ["nothing"]))
    }

    func testMetadataCreateAcceptsNullAndRejectsUnknownLifecyclePhase() throws {
        let legacy = try SessionMetadataDocument.create(changes: [
            .init(key: "lifecycle_phase", value: .null),
        ])
        XCTAssertNil(try SessionMetadataDocument.scalar(
            in: legacy, paths: ["lifecycle_phase"]))

        XCTAssertThrowsError(try SessionMetadataDocument.create(changes: [
            .init(key: "lifecycle_phase", value: .string("unknown")),
        ])) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidLifecyclePhase)
        }
    }

    func testLifecycleValidationRejectsInvalidCurrentPhaseAndStopInvariants() throws {
        let invalidCurrent = Data(#"{"status":"running","lifecycle_phase":"unknown"}"#.utf8)
        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            invalidCurrent,
            changes: [.init(key: "lifecycle_phase", value: .string("terminal"))]
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidLifecyclePhase)
        }

        let legacyRunning = Data(#"{"status":"running"}"#.utf8)
        XCTAssertNoThrow(try SessionMetadataDocument.patch(
            legacyRunning,
            changes: [
                .init(key: "stop_requested_at", value: .string("now")),
                .init(key: "status", value: .string("stopped")),
                .init(key: "lifecycle_phase", value: .string("stopping")),
            ]))
        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            legacyRunning,
            changes: [.init(key: "lifecycle_phase", value: .string("stopping"))]
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidLifecycleTransition)
        }
        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            legacyRunning,
            changes: [
                .init(key: "stop_requested_at", value: .string("now")),
                .init(key: "lifecycle_phase", value: .string("finalizing")),
            ]
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidLifecycleTransition)
        }
    }

    func testMetadataOperationsDistinguishMalformedJSONFromNonObjectJSON() {
        XCTAssertThrowsError(try SessionMetadataDocument.scalar(
            in: Data("not-json".utf8), paths: ["value"]
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidJSON)
        }
        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            Data("[]".utf8), changes: []
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidMetadata)
        }
    }

    func testMetadataOperationsRejectNonFiniteNumbers() {
        let change = SessionMetadataDocument.Change(key: "number", value: .number(.nan))

        XCTAssertThrowsError(try SessionMetadataDocument.create(changes: [change])) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidMetadata)
        }
        XCTAssertThrowsError(try SessionMetadataDocument.patch(
            Data(#"{"schema":1}"#.utf8),
            changes: [change]
        )) { error in
            XCTAssertEqual(error as? DetachStateError, .invalidMetadata)
        }
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

        XCTAssertNil(try SessionMetadataDocument.scalar(
            in: data, paths: ["", ".payload", "payload.", "payload.id.value"]))
    }

    func testMetadataReadRejectsContainersAndPreservesFractionalNumbers() throws {
        let data = Data(#"{"object":{"nested":true},"array":[1],"fraction":2.5}"#.utf8)

        XCTAssertEqual(
            try SessionMetadataDocument.scalar(in: data, paths: ["fraction"]),
            .number(2.5))
        XCTAssertThrowsError(try SessionMetadataDocument.scalar(in: data, paths: ["object"])) { error in
            XCTAssertEqual(error as? DetachStateError, .unsupportedScalar)
        }
        XCTAssertThrowsError(try SessionMetadataDocument.scalar(in: data, paths: ["array"])) { error in
            XCTAssertEqual(error as? DetachStateError, .unsupportedScalar)
        }
    }

    func testMetadataReadDoesNotTrapAtIntegerBoundaries() throws {
        let data = Data(#"{"minimum":-9223372036854775808,"maximum":9223372036854775807,"whole":1e16,"above":9223372036854775808,"below":-9223372036854775809}"#.utf8)

        XCTAssertEqual(
            try SessionMetadataDocument.scalar(in: data, paths: ["minimum"]),
            .integer(.min))
        XCTAssertEqual(
            try SessionMetadataDocument.scalar(in: data, paths: ["maximum"]),
            .integer(.max))
        XCTAssertEqual(
            try SessionMetadataDocument.scalar(in: data, paths: ["whole"]),
            .integer(10_000_000_000_000_000))
        guard case .number(let above)? = try SessionMetadataDocument.scalar(
            in: data, paths: ["above"]) else {
            return XCTFail("Int.max + 1 must remain a non-trapping JSON number")
        }
        guard case .number(let below)? = try SessionMetadataDocument.scalar(
            in: data, paths: ["below"]) else {
            return XCTFail("Int.min - 1 must remain a non-trapping JSON number")
        }
        XCTAssertTrue(above.isFinite)
        XCTAssertTrue(below.isFinite)
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

        XCTAssertFalse(SessionMetadataDocument.matchesSession(
            Data("not-json".utf8), provider: .codex, expectedSessionID: "id"))
        XCTAssertFalse(SessionMetadataDocument.matchesSession(
            Data(#"{"provider":1,"agent_session_id":"id"}"#.utf8),
            provider: .codex, expectedSessionID: "id"))
        XCTAssertFalse(SessionMetadataDocument.matchesSession(
            Data(#"{"provider":"codex","agent_session_id":1}"#.utf8),
            provider: .codex, expectedSessionID: "id"))
        XCTAssertFalse(SessionMetadataDocument.matchesSession(
            Data(#"{"provider":"codex","agent_session_id":null,"codex_session_id":null}"#.utf8),
            provider: .codex, expectedSessionID: "id"))
    }

    func testFileAndHandleTranscriptAPIsPreserveStreamingContracts() throws {
        let data = Data("""
        {"payload":{"id":"session-1"}}
        {"payload":{"session_id":"fallback"}}
        """.utf8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        try data.write(to: transcript)

        XCTAssertEqual(
            try TranscriptDocument.firstScalar(inFileAt: transcript, paths: ["payload.id"]),
            .string("session-1"))
        XCTAssertTrue(try TranscriptDocument.isValid(
            fileAt: transcript, provider: .codex, expectedSessionID: "session-1"))

        let scalarPipe = Pipe()
        scalarPipe.fileHandleForWriting.write(data)
        try scalarPipe.fileHandleForWriting.close()
        XCTAssertEqual(
            try TranscriptDocument.firstScalar(
                reading: scalarPipe.fileHandleForReading, paths: ["payload.session_id"]),
            .string("fallback"))

        let validationPipe = Pipe()
        validationPipe.fileHandleForWriting.write(data)
        try validationPipe.fileHandleForWriting.close()
        XCTAssertTrue(try TranscriptDocument.isValid(
            reading: validationPipe.fileHandleForReading,
            provider: .codex,
            expectedSessionID: "session-1"))
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
        XCTAssertFalse(TranscriptDocument.isValid(
            Data(#"{"type":"assistant"}"#.utf8),
            provider: .claude,
            expectedSessionID: "session-1"))
        XCTAssertFalse(TranscriptDocument.isValid(
            Data(#"{"sessionId":1}"#.utf8),
            provider: .claude,
            expectedSessionID: "session-1"))
        XCTAssertFalse(TranscriptDocument.isValid(
            Data(), provider: .claude, expectedSessionID: "session-1"))
    }

    func testCodexJSONLValidationRequiresRootPayloadAndIdentifier() {
        XCTAssertFalse(TranscriptDocument.isValid(
            Data(#"{"type":"event_msg"}"#.utf8),
            provider: .codex,
            expectedSessionID: "session-1"))
        XCTAssertFalse(TranscriptDocument.isValid(
            Data(#"{"payload":{}}"#.utf8),
            provider: .codex,
            expectedSessionID: "session-1"))
    }

    func testJSONLValidationStreamsGeneratedChunksWithoutRetainingTheTranscript() throws {
        let root = Data(#"{"payload":{"id":"session-1"}}"#.utf8)
        let event = Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8)
        var chunkIndex = 0
        // Twenty thousand independently supplied records are large enough to
        // distinguish streaming from a one-shot parser without dominating the
        // full coverage run on every change.
        let eventCount = 20_000

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

    func testCodexSummaryCoversInterruptedUnknownAndInvalidNumericEvents() {
        let tail = Data("""
        {"payload":{"model":"","type":"token_count","info":{"last_token_usage":{"input_tokens":true,"output_tokens":1.5},"model_context_window":"large"}}}
        {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1"}}
        {"type":"event_msg","payload":{"type":"future_event","turn_id":"turn-2"}}
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: tail, provider: .codex),
            TranscriptSummary(
                model: nil,
                contextUsed: 0,
                contextWindow: 0,
                agentTurnState: .interrupted,
                agentTurnID: "turn-1"))
    }

    func testSummaryClearsTurnStateWhenNoUsableIdentifierExists() {
        let tail = Data("""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":""}}
        {"type":"user","uuid":"","message":{"role":"user","content":"go"}}
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: tail, provider: .codex),
            TranscriptSummary())
        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: tail, provider: .claude),
            TranscriptSummary())
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

    func testClaudeSummaryTracksAskUserQuestionUntilItsMatchingResult() {
        let contradictoryTail = Data("""
        {"type":"user","uuid":"real-user","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"missing-stop","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","id":"ask-without-stop"}]}}
        {"type":"assistant","uuid":"wrong-stop","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"tool_use","name":"AskUserQuestion","id":"ask-after-end"}]}}
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: contradictoryTail, provider: .claude),
            TranscriptSummary(
                contextUsed: 0,
                agentTurnState: .working,
                agentTurnID: "real-user"))

        let waitingTail = Data("""
        {"type":"user","uuid":"real-user","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"ordinary-tool","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"bash-1"}]}}
        {"type":"assistant","uuid":"sidechain-ask","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion","id":"sidechain-1"}]}}
        {"type":"assistant","uuid":"malformed-ask","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}
        {"type":"assistant","uuid":"ask-record","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion","id":"ask-1"}]}}
        {"type":"user","uuid":"unrelated-result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"bash-1"}]}}
        {"type":"user","uuid":"plain-user","message":{"role":"user","content":"this must not clear a pending tool result"}}
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: waitingTail, provider: .claude),
            TranscriptSummary(
                contextUsed: 0,
                agentTurnState: .waiting,
                agentTurnID: "ask-1"))

        var answeredTail = waitingTail
        answeredTail.append(Data("""

        {"type":"user","uuid":"answer-record","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ask-1"}]}}
        """.utf8))
        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: answeredTail, provider: .claude),
            TranscriptSummary(
                contextUsed: 0,
                agentTurnState: .working,
                agentTurnID: "answer-record"))
    }
}
