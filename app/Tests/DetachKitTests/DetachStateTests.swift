import XCTest
@testable import DetachKit

final class DetachStateTests: XCTestCase {
    func testCodexInputReasonRequiresMatchingResultAndClearsOnTurnTransition() {
        let request = Data(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"ask-1","arguments":"{}"}}"#.utf8)
        let waiting = TranscriptDocument.summary(ofTail: request, provider: .codex)
        XCTAssertEqual(waiting.agentTurnState, .waiting)
        XCTAssertEqual(waiting.agentWaitingReason, .inputRequired)
        let unrelated = Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"other","output":"ok"}}"#.utf8)
        XCTAssertEqual(TranscriptDocument.summary(ofTail: unrelated, provider: .codex, startingFrom: waiting), waiting)
        let answer = Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"ask-1","output":"ok"}}"#.utf8)
        let resumed = TranscriptDocument.summary(ofTail: answer, provider: .codex, startingFrom: waiting)
        XCTAssertEqual(resumed.agentTurnState, .working)
        XCTAssertNil(resumed.agentWaitingReason)
        XCTAssertNil(resumed.pendingToolUseID)
        for event in ["task_started", "turn_aborted", "task_complete"] {
            let record = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\",\"turn_id\":\"turn\"}}".utf8)
            let next = TranscriptDocument.summary(ofTail: record, provider: .codex, startingFrom: waiting)
            XCTAssertEqual(next.agentWaitingReason, event == "task_complete" ? .answerReady : nil)
            XCTAssertNil(next.pendingToolUseID)
        }
        let async = Data(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","call_id":"async"}}"#.utf8)
        XCTAssertNil(TranscriptDocument.summary(ofTail: async, provider: .codex).agentWaitingReason)
    }

    func testCodexColdTailInfersAnUnfinishedTurnOnlyFromTurnScopedRecords() {
        func summary(_ lines: String...) -> TranscriptSummary {
            TranscriptDocument.summary(
                ofTail: Data(lines.joined(separator: "\n").utf8), provider: .codex)
        }
        let usage = #"{"type":"token_usage_record","payload":{"turn_id":"turn-a"}}"#
        let context = #"{"type":"turn_context","payload":{"turn_id":"turn-a","model":"m"}}"#
        let completed = #"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn-a"}}"#
        let finished = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#
        for record in [usage, context] {
            let active = summary(completed, record)
            XCTAssertEqual(active.agentTurnState, .working)
            XCTAssertEqual(active.agentTurnID, "turn-a")
            XCTAssertNil(active.agentWaitingReason)
        }
        XCTAssertEqual(summary(context).model, "m")
        XCTAssertNil(summary(completed).agentTurnState, "Command completions can follow their turn")
        XCTAssertNil(summary(#"{"type":"token_usage_record","payload":{"turn_id":""}}"#).agentTurnState)
        XCTAssertNil(summary(#"{"type":"response_item","payload":{"type":"message","turn_id":"turn-a"}}"#)
            .agentTurnState)
        let done = summary(usage, finished, usage)
        XCTAssertEqual(done.agentTurnState, .waiting)
        XCTAssertEqual(done.agentWaitingReason, .answerReady)
        let next = summary(finished, #"{"type":"token_usage_record","payload":{"turn_id":"turn-b"}}"#)
        XCTAssertEqual(next.agentTurnID, "turn-a", "A known turn state is never overridden")
    }

    func testClaudeSuccessorFollowsOnlyTheLatestUnreusedContinuation() {
        let old = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
        let next = "5f6e7d8c-9b0a-4c1d-8e2f-3a4b5c6d7e8f"
        let later = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        func successor(_ lines: String...) -> String? {
            TranscriptDocument.claudeSuccessorID(
                ofTail: Data(lines.joined(separator: "\n").utf8), expectedSessionID: old)
        }
        func marker(_ from: String, _ to: String) -> String {
            "{\"type\":\"continued-in\",\"sessionId\":\"\(from)\",\"continuedInSessionId\":\"\(to)\"}"
        }
        func record(_ type: String) -> String {
            "{\"type\":\"\(type)\",\"sessionId\":\"\(old)\",\"message\":{\"role\":\"\(type)\",\"content\":\"go\"}}"
        }
        XCTAssertEqual(successor(record("user"), marker(old, next)), next)
        XCTAssertEqual(successor(marker(old, next), #"{"type":"ai-title","aiTitle":"t"}"#), next,
                       "Metadata after the marker keeps the continuation")
        XCTAssertEqual(successor(marker(old, next), marker(old, later)), later)
        for type in ["user", "assistant"] {
            XCTAssertNil(successor(marker(old, next), record(type)),
                         "A later \(type) record makes the old session current again")
        }
        XCTAssertNil(successor(marker(later, next)), "Another session's marker does not count")
        XCTAssertNil(successor(marker(old, old)))
        XCTAssertNil(successor(marker(old, "not-a-uuid")))
        XCTAssertNil(successor(marker(old, next.uppercased())))
        XCTAssertNil(successor(#"{"type":"continued-in","sessionId":"\#(old)"}"#))
        XCTAssertNil(successor(record("user")))
    }

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
                agentTurnID: "turn-1",
                agentWaitingReason: .answerReady))
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
                agentTurnID: "real-user",
                agentWaitingReason: .answerReady))
    }

    func testClaudeSidechainAndMetadataOnlyRecordsKeepMainConversationFields() {
        let tail = Data("""
        {"type":"user","uuid":"request","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","model":"main-model","stop_reason":"end_turn","usage":{"input_tokens":10000},"content":[{"type":"text","text":"Done."}]}}
        {"type":"assistant","uuid":"side","isSidechain":true,"message":{"role":"assistant","model":"side-model","usage":{"input_tokens":25}}}
        {"type":"assistant","uuid":"bare","isSidechain":true,"message":{"role":"assistant"}}
        {"type":"assistant","uuid":"notice","message":{"role":"assistant","model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"API Error"}]}}
        """.utf8)
        let summary = TranscriptDocument.summary(ofTail: tail, provider: .claude)
        XCTAssertEqual(summary.model, "main-model")
        XCTAssertEqual(summary.contextUsed, 10000)
        XCTAssertEqual(summary.agentTurnState, .waiting)
    }

    func testCodexTokenEventWithoutUsageKeepsEstablishedContext() {
        let tail = Data("""
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":150,"output_tokens":50},"model_context_window":1000}}}
        {"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":1000}}}
        """.utf8)
        let summary = TranscriptDocument.summary(ofTail: tail, provider: .codex)
        XCTAssertEqual(summary.contextUsed, 200)
        XCTAssertEqual(summary.contextWindow, 1000)
    }

    func testClaudeSummaryCompletesFinalTextWithoutTurnDuration() {
        let thinking = Data("""
        {"type":"user","uuid":"request","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"thinking","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"done"}]}}
        """.utf8)
        let working = TranscriptDocument.summary(ofTail: thinking, provider: .claude)
        XCTAssertEqual(working.agentTurnState, .working)

        let answer = Data("""
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
        """.utf8)
        let waiting = TranscriptDocument.summary(
            ofTail: answer, provider: .claude, startingFrom: working)
        XCTAssertEqual(waiting.agentTurnState, .waiting)
        XCTAssertEqual(waiting.agentTurnID, "answer")
        // A cold bounded tail can contain only the final answer.
        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: answer, provider: .claude), waiting)

        let trailing = Data("""
        {"type":"assistant","uuid":"answer-fragment","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"More detail."}]}}
        {"type":"system","subtype":"turn_duration","uuid":"duration"}
        """.utf8)
        XCTAssertEqual(
            TranscriptDocument.summary(
                ofTail: trailing, provider: .claude, startingFrom: waiting), waiting)
    }

    func testClaudeSummaryStaysWorkingWhileBackgroundTasksRun() {
        // Claude ends its turn after starting a background shell and a
        // workflow, then waits for their completion notifications.
        let launched = Data("""
        {"type":"user","uuid":"request","message":{"role":"user","content":"run the pipeline"}}
        {"type":"assistant","uuid":"launch-shell","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_shell","name":"Bash","input":{"command":"make","run_in_background":true}}]}}
        {"type":"user","uuid":"shell-result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_shell","content":"Command running in background with ID: bshell1."}]}}
        {"type":"assistant","uuid":"launch-flow","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_flow","name":"Workflow","input":{"script":"x"}}]}}
        {"type":"user","uuid":"flow-result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_flow","content":"Workflow started: wf_1"}]}}
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Waiting for results."}]}}
        {"type":"system","subtype":"turn_duration","uuid":"duration"}
        """.utf8)
        let running = TranscriptDocument.summary(ofTail: launched, provider: .claude)
        XCTAssertEqual(running.agentTurnState, .working)

        // One notification is not enough; both must complete.
        let shellDone = Data("""
        {"type":"queue-operation","operation":"enqueue","content":"<task-notification>\\n<task-id>bshell1</task-id>\\n<tool-use-id>toolu_shell</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}
        """.utf8)
        let halfway = TranscriptDocument.summary(
            ofTail: shellDone, provider: .claude, startingFrom: running)
        XCTAssertEqual(halfway.agentTurnState, .working)

        // The last notification wakes Claude; its answer is a normal wait.
        let flowDone = Data("""
        {"type":"attachment","uuid":"notice","attachment":{"type":"queued_command","prompt":"<task-notification><task-id>w1</task-id><tool-use-id>toolu_flow</tool-use-id><status>completed</status></task-notification>"}}
        {"type":"assistant","uuid":"summary","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All done."}]}}
        {"type":"system","subtype":"turn_duration","uuid":"duration-2"}
        """.utf8)
        let finished = TranscriptDocument.summary(
            ofTail: flowDone, provider: .claude, startingFrom: halfway)
        XCTAssertEqual(finished.agentTurnState, .waiting)
        XCTAssertEqual(finished.agentTurnID, "summary")
    }

    func testColdTailFindsBackgroundWorkLaunchedAboveIt() {
        // Large records can push a workflow launch above the summary tail.
        let deep = Data("""
        {"type":"assistant","uuid":"launch","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_flow","name":"Workflow","input":{"script":"x"}}]}}
        {"type":"assistant","uuid":"old-shell","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_done","name":"Bash","input":{"command":"x","run_in_background":true}}]}}
        {"type":"queue-operation","operation":"enqueue","content":"<task-notification><tool-use-id>toolu_done</tool-use-id><status>completed</status></task-notification>"}
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Waiting."}]}}
        """.utf8)
        let tail = Data("""
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Waiting."}]}}
        """.utf8)
        let cold = TranscriptDocument.summary(ofTail: tail, provider: .claude)
        XCTAssertEqual(cold.agentTurnState, .waiting)

        let resolved = TranscriptDocument.resolvingBackgroundWork(
            cold, provider: .claude, deepTail: { deep })
        XCTAssertEqual(resolved.agentTurnState, .working)

        // Finished background work, or none, leaves a real wait alone.
        let finished = Data("""
        {"type":"assistant","uuid":"old-shell","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_done","name":"Bash","input":{"command":"x","run_in_background":true}}]}}
        {"type":"queue-operation","operation":"enqueue","content":"<task-notification><tool-use-id>toolu_done</tool-use-id><status>completed</status></task-notification>"}
        """.utf8)
        XCTAssertEqual(
            TranscriptDocument.resolvingBackgroundWork(
                cold, provider: .claude, deepTail: { finished }).agentTurnState,
            .waiting)
        XCTAssertEqual(
            TranscriptDocument.resolvingBackgroundWork(
                cold, provider: .codex, deepTail: { deep }).agentTurnState,
            .waiting)
    }

    func testClaudeBackgroundReplayPreservesFailedLaunches() {
        let history = Data("""
        {"type":"assistant","uuid":"launch","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_job","name":"Bash","input":{"run_in_background":true}}]}}
        {"type":"user","uuid":"result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_job","is_error":true,"content":"Permission denied"}]}}
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Could not start."}]}}
        """.utf8)
        let summary = TranscriptDocument.summary(ofTail: history, provider: .claude)
        XCTAssertEqual(summary.agentTurnState, .waiting)
        XCTAssertEqual(summary.pendingBackground, [])
        XCTAssertEqual(TranscriptDocument.resolvingBackgroundWork(
            summary, provider: .claude, deepTail: { history }), summary)
    }

    func testClaudeBackgroundStopRequiresSuccessfulMatchingResult() {
        for (tool, argument) in [("TaskStop", "task_id"), ("KillShell", "shell_id")] {
            let launch = """
            {"type":"assistant","uuid":"launch","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_job","name":"Bash","input":{"run_in_background":true}}]}}
            {"type":"user","uuid":"launched","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_job","content":"Command running in background with ID: bjob."}]}}
            {"type":"assistant","uuid":"stop","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_stop","name":"\(tool)","input":{"\(argument)":"bjob"}}]}}

            """
            let stopping = TranscriptDocument.summary(ofTail: Data(launch.utf8), provider: .claude)
            XCTAssertEqual(stopping.pendingBackground.count, 1, tool)
            for (id, error) in [("toolu_stop", true), ("other", false)] {
                let failed = """
                {"type":"user","uuid":"result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(id)","is_error":\(error),"content":"Not stopped."}]}}
                {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Still running."}]}}
                """
                let running = TranscriptDocument.summary(
                    ofTail: Data(failed.utf8), provider: .claude, startingFrom: stopping)
                XCTAssertEqual(running.agentTurnState, .working, tool)
                XCTAssertEqual(running.pendingBackground.count, 1, tool)
                var cold = TranscriptSummary(agentTurnState: .waiting)
                cold = TranscriptDocument.resolvingBackgroundWork(
                    cold, provider: .claude, deepTail: { Data((launch + failed).utf8) })
                XCTAssertEqual(cold.agentTurnState, .working, tool)
                XCTAssertEqual(cold.pendingBackground, running.pendingBackground, tool)
            }
            let success = Data("""
            {"type":"user","uuid":"result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_stop","content":"Stopped."}]}}
            {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Stopped."}]}}
            """.utf8)
            let finished = TranscriptDocument.summary(
                ofTail: success, provider: .claude, startingFrom: stopping)
            XCTAssertEqual(finished.agentTurnState, .waiting, tool)
            XCTAssertEqual(finished.pendingBackground, [], tool)
        }
    }

    func testClaudeBackgroundCompletionRequiresTaskNotification() throws {
        var running = TranscriptSummary(agentTurnState: .working)
        running.pendingBackground = [PendingBackgroundTask(toolUseID: "toolu_job")]
        let tag = "<tool-use-id>toolu_job</tool-use-id>"
        let notice = "<task-notification>\(tag)<status>completed</status></task-notification>"
        let ignored: [[String: Any]] = [
            ["type": "queue-operation", "operation": "enqueue", "content": "Find \(tag)"],
            ["type": "queue-operation", "operation": "enqueue", "content": notice,
             "isSidechain": true],
            ["type": "queue-operation", "operation": "enqueue", "content": notice,
             "isMeta": true],
            ["type": "queue-operation", "operation": "enqueue",
             "content": "<task-notification>\(tag)<status>running</status></task-notification>"],
            ["type": "attachment", "attachment": ["type": "file", "content": notice]],
            ["type": "queue-operation", "operation": "enqueue", "content": "other",
             "description": notice],
        ]
        for record in ignored {
            XCTAssertEqual(TranscriptDocument.summary(
                ofTail: try JSONSerialization.data(withJSONObject: record),
                provider: .claude, startingFrom: running).pendingBackground,
                running.pendingBackground)
        }
        for status in ["completed", "failed", "killed"] {
            let record = ["type": "queue-operation", "operation": "enqueue",
                          "content": notice.replacingOccurrences(of: "completed", with: status)]
            XCTAssertEqual(TranscriptDocument.summary(
                ofTail: try JSONSerialization.data(withJSONObject: record),
                provider: .claude, startingFrom: running).pendingBackground, [])
        }
    }

    func testClaudeTaskEventsIgnoreNonConversationRecords() throws {
        let waiting = TranscriptSummary(
            agentTurnState: .waiting, agentTurnID: "answer", agentWaitingReason: .answerReady)
        for name in ["Bash", "AskUserQuestion"] {
            let message: [String: Any] = [
                "role": "assistant", "model": "claude", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": name, "id": "toolu_job",
                             "input": ["run_in_background": true]]],
            ]
            for excluded: [String: Any] in [
                ["isMeta": true], ["isSidechain": true], ["uuid": ""],
                ["message": message.merging(["model": "<synthetic>"]) { _, new in new }],
                ["message": message.merging(["role": "user"]) { _, new in new }],
            ] {
                var record: [String: Any] = [
                    "type": "assistant", "uuid": "launch", "message": message,
                ]
                record.merge(excluded) { _, new in new }
                let data = try JSONSerialization.data(withJSONObject: record)
                XCTAssertEqual(TranscriptDocument.summary(
                    ofTail: data, provider: .claude, startingFrom: waiting).agentTurnState,
                    waiting.agentTurnState)
                XCTAssertEqual(TranscriptDocument.summary(
                    ofTail: data, provider: .claude, startingFrom: waiting).pendingBackground, [])
                XCTAssertEqual(TranscriptDocument.summary(
                    ofTail: data, provider: .claude, startingFrom: waiting).pendingToolUseID, nil)
                XCTAssertEqual(TranscriptDocument.resolvingBackgroundWork(
                    waiting, provider: .claude, deepTail: { data }), waiting)
            }
        }
    }

    func testClaudeSummaryStopsTrackingABackgroundTaskStoppedByTheAgent() {
        let transcript = Data("""
        {"type":"user","uuid":"request","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"launch","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_shell","name":"Bash","input":{"command":"sleep 99","run_in_background":true}}]}}
        {"type":"user","uuid":"launch-result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_shell","content":"Command running in background with ID: bslow."}]}}
        {"type":"assistant","uuid":"stop","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_stop","name":"TaskStop","input":{"task_id":"bslow"}}]}}
        {"type":"user","uuid":"stop-result","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_stop","content":"stopped"}]}}
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Stopped it."}]}}
        """.utf8)
        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: transcript, provider: .claude).agentTurnState,
            .waiting)
    }

    func testClaudeSummaryBoundsAndClearsBackgroundTasks() {
        // A failed launch never runs, and a block-array result still names
        // the task that a later TaskStop ends.
        let transcript = Data("""
        {"type":"assistant","uuid":"launch","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_bad","name":"Bash","input":{"command":"x","run_in_background":true}},{"type":"tool_use","id":"toolu_ok","name":"Bash","input":{"command":"y","run_in_background":true}}]}}
        {"type":"user","uuid":"results","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_bad","is_error":true,"content":"denied"},{"type":"tool_result","tool_use_id":"toolu_ok","content":[{"type":"text","text":"Command running in background with ID: bblock."}]}]}}
        """.utf8)
        let launched = TranscriptDocument.summary(ofTail: transcript, provider: .claude)
        XCTAssertEqual(
            launched.pendingBackground,
            [PendingBackgroundTask(toolUseID: "toolu_ok", taskID: "bblock")])

        let stop = Data("""
        {"type":"assistant","uuid":"stop","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_stop","name":"TaskStop","input":{"task_id":"bblock"}}]}}
        {"type":"user","uuid":"stopped","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_stop","content":"Stopped."}]}}
        """.utf8)
        XCTAssertEqual(
            TranscriptDocument.summary(
                ofTail: stop, provider: .claude, startingFrom: launched).pendingBackground,
            [])

        // The pending list keeps only the newest launches.
        let many = (0...PendingBackgroundTask.limit).map { index in
            #"{"type":"assistant","uuid":"l\#(index)","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_\#(index)","name":"Bash","input":{"command":"x","run_in_background":true}}]}}"#
        }.joined(separator: "\n")
        let bounded = TranscriptDocument.summary(ofTail: Data(many.utf8), provider: .claude)
        XCTAssertEqual(bounded.pendingBackground.count, PendingBackgroundTask.limit)
        XCTAssertEqual(bounded.pendingBackground.first?.toolUseID, "toolu_1")

        // A carried-forward task turns a final answer into working.
        var carried = TranscriptSummary()
        carried.pendingBackground = [PendingBackgroundTask(toolUseID: "toolu_ok")]
        let answer = Data("""
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Waiting."}]}}
        """.utf8)
        let resumed = TranscriptDocument.summary(
            ofTail: answer, provider: .claude, startingFrom: carried)
        XCTAssertEqual(resumed.agentTurnState, .working)
        XCTAssertEqual(resumed.agentTurnID, "answer")
    }

    func testClaudeSummaryStartsATurnForBlockArrayUserInput() {
        let waiting = TranscriptDocument.summary(ofTail: Data("""
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
        """.utf8), provider: .claude)
        XCTAssertEqual(waiting.agentTurnState, .waiting)

        // Pasted images arrive as block arrays without any tool result.
        let input = Data("""
        {"type":"user","uuid":"next","message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","source":{}}]}}
        """.utf8)
        let next = TranscriptDocument.summary(
            ofTail: input, provider: .claude, startingFrom: waiting)
        XCTAssertEqual(next.agentTurnState, .working)
        XCTAssertEqual(next.agentTurnID, "next")
    }

    func testClaudeSummaryIgnoresForegroundToolsAndBackgroundAgents() {
        // Background agents record no completion notification, so they
        // cannot hold the turn open; foreground tools finish in their turn.
        let transcript = Data("""
        {"type":"user","uuid":"request","message":{"role":"user","content":"go"}}
        {"type":"assistant","uuid":"tools","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_fg","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"prompt":"x","run_in_background":true}}]}}
        {"type":"user","uuid":"results","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fg","content":"a"},{"type":"tool_result","tool_use_id":"toolu_agent","content":"Spawned successfully"}]}}
        {"type":"assistant","uuid":"answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
        """.utf8)
        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: transcript, provider: .claude).agentTurnState,
            .waiting)
    }

    func testClaudeSummaryRejectsUnprovenFinalAnswers() throws {
        let unsupported: [[String: Any]] = [
            ["isSidechain": true], ["isMeta": true], ["uuid": ""],
            ["message": ["role": "user"]],
            ["message": ["stop_reason": "max_tokens"]],
            ["message": ["stop_reason": NSNull()]],
            ["message": ["content": NSNull()]],
            ["message": ["content": [["type": "text", "text": ""]]]],
            ["message": ["content": [["type": "text", "text": "Done"],
                                      ["type": "tool_use", "name": "Bash"]]]],
        ]
        for overrides in unsupported {
            var message: [String: Any] = [
                "role": "assistant", "stop_reason": "end_turn",
                "content": [["type": "text", "text": "Done"]],
            ]
            message.merge(overrides["message"] as? [String: Any] ?? [:]) { _, new in new }
            var record: [String: Any] = ["type": "assistant", "uuid": "answer"]
            record.merge(overrides) { _, new in new }
            record["message"] = message
            let summary = TranscriptDocument.summary(
                ofTail: try JSONSerialization.data(withJSONObject: record),
                provider: .claude,
                startingFrom: TranscriptSummary(
                    agentTurnState: .working, agentTurnID: "request"))
            XCTAssertEqual(summary.agentTurnState, .working, "\(overrides)")
            XCTAssertEqual(summary.agentTurnID, "request", "\(overrides)")
        }
    }

    func testClaudeSummaryResumesAfterFinalAnswer() {
        let waiting = TranscriptSummary(
            agentTurnState: .waiting, agentTurnID: "answer", agentWaitingReason: .answerReady)
        let continuations = [
            """
            {"type":"assistant","uuid":"next","message":{"role":"assistant","stop_reason":null,"content":[{"type":"thinking","thinking":"Checking the result."}]}}
            """,
            """
            {"type":"assistant","uuid":"next","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"I will check that."}]}}
            """,
            """
            {"type":"assistant","uuid":"next","message":{"role":"assistant","stop_reason":null,"content":[{"type":"tool_use","name":"Bash","id":"tool"}]}}
            """,
            """
            {"type":"user","uuid":"next","message":{"role":"user","content":"continue"}}
            """,
            """
            {"type":"assistant","uuid":"next","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"tool"}]}}
            """,
        ]
        for continuation in continuations {
            let working = TranscriptDocument.summary(
                ofTail: Data(continuation.utf8), provider: .claude, startingFrom: waiting)
            XCTAssertEqual(working.agentTurnState, .working)
            XCTAssertEqual(working.agentTurnID, "next")
            XCTAssertNil(working.agentWaitingReason)
            let cold = TranscriptDocument.summary(ofTail: Data(continuation.utf8), provider: .claude)
            XCTAssertEqual(cold.agentTurnState, .working)
            let answer = Data("""
            {"type":"assistant","uuid":"next-answer","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done again."}]}}
            """.utf8)
            let completed = TranscriptDocument.summary(
                ofTail: answer, provider: .claude, startingFrom: working)
            XCTAssertEqual(completed.agentTurnState, .waiting)
            XCTAssertEqual(completed.agentTurnID, "next-answer")
        }
    }

    func testClaudeStreamedActivityDoesNotReplaceExplicitInputOrUseSidechains() throws {
        let answer = TranscriptSummary(
            agentTurnState: .waiting, agentTurnID: "answer", agentWaitingReason: .answerReady)
        let activity: [String: Any] = [
            "type": "assistant", "uuid": "next",
            "message": ["role": "assistant", "stop_reason": NSNull(),
                        "content": [["type": "thinking", "thinking": "Checking."]]],
        ]
        for excluded in [["isSidechain": true], ["isMeta": true]] {
            let record = activity.merging(excluded) { _, new in new }
            XCTAssertEqual(TranscriptDocument.summary(
                ofTail: try JSONSerialization.data(withJSONObject: record),
                provider: .claude, startingFrom: answer), answer)
        }
        var synthetic = activity
        var message = try XCTUnwrap(synthetic["message"] as? [String: Any])
        message["model"] = "<synthetic>"
        synthetic["message"] = message
        XCTAssertEqual(TranscriptDocument.summary(
            ofTail: try JSONSerialization.data(withJSONObject: synthetic),
            provider: .claude, startingFrom: answer), answer)

        var input = TranscriptSummary(
            agentTurnState: .waiting, agentTurnID: "question", agentWaitingReason: .inputRequired)
        input.pendingToolUseID = "question"
        XCTAssertEqual(TranscriptDocument.summary(
            ofTail: try JSONSerialization.data(withJSONObject: activity),
            provider: .claude, startingFrom: input), input)

        for content in [[], [["type": "text", "text": ""]], [["type": "unknown"]]] {
            var empty = activity
            empty["message"] = ["role": "assistant", "content": content]
            XCTAssertEqual(TranscriptDocument.summary(
                ofTail: try JSONSerialization.data(withJSONObject: empty),
                provider: .claude, startingFrom: answer), answer)
        }
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
        {"type":"assistant","uuid":"final-text","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Choose an option."}]}}
        {"type":"system","subtype":"turn_duration","uuid":"duration"}
        {"type":"assistant","uuid":"other-tool","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"bash-2"}]}}
        """.utf8)

        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: waitingTail, provider: .claude),
            TranscriptSummary(
                agentTurnState: .waiting,
                agentTurnID: "ask-1",
                agentWaitingReason: .inputRequired))

        var answeredTail = waitingTail
        answeredTail.append(Data("""

        {"type":"user","uuid":"answer-record","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ask-1"}]}}
        """.utf8))
        XCTAssertEqual(
            TranscriptDocument.summary(ofTail: answeredTail, provider: .claude),
            TranscriptSummary(
                agentTurnState: .working,
                agentTurnID: "answer-record"))
    }
}
