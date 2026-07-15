import XCTest
@testable import DetachKit

final class DetachStateCommandTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-state-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testEmitContextProducesCompactSchemaLessJSON() throws {
        let output = try DetachStateCommand.run(arguments: [
            "emit", "context", "detach-codex-project", "/tmp/project", "true",
        ])

        XCTAssertEqual(
            String(decoding: output, as: UTF8.self),
            #"{"live":true,"project_dir":"/tmp/project","session_name":"detach-codex-project"}"# + "\n")
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "emit", "context", "session", "/tmp/project", "yes",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidBoolean("yes"))
        }
    }

    func testEmitSessionProducesTheCompletePublicSchemaAndDerivesName() throws {
        let output = try DetachStateCommand.run(arguments: [
            "emit", "session", "claude", "detach-claude-my-project-abcd", "running",
            "--meta-status", "running",
            "--agent-session-id", "session-id",
            "--project-dir", "/tmp/project",
            "--created-at", "2026-07-15T10:00:00Z",
            "--last-checkpoint-at", "2026-07-15T10:05:00Z",
            "--exit-status", "7",
            "--finished-at", "2026-07-15T10:10:00Z",
            "--model", "claude-test",
            "--context-used", "0",
            "--context-window", "200000",
            "--agent-turn-state", "waiting",
            "--agent-turn-id", "turn-1",
            "--session-color", "#1aB2c3",
            "--power-state", "protected",
        ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set([
            "schema", "provider", "session_name", "name", "session_color",
            "effective_status", "meta_status", "agent_session_id", "project_dir",
            "created_at", "last_checkpoint_at", "exit_status", "finished_at", "model",
            "context_used_tokens", "context_window", "agent_turn_state", "agent_turn_id",
            "power_protection_state",
        ]))
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["provider"] as? String, "claude")
        XCTAssertEqual(object["session_name"] as? String, "detach-claude-my-project-abcd")
        XCTAssertEqual(object["name"] as? String, "my-project-abcd")
        XCTAssertEqual(object["effective_status"] as? String, "running")
        XCTAssertEqual(object["exit_status"] as? Int, 7)
        XCTAssertTrue(object["context_used_tokens"] is NSNull)
        XCTAssertEqual(object["context_window"] as? Int, 200_000)
        XCTAssertEqual(object["agent_turn_state"] as? String, "waiting")
        XCTAssertEqual(object["power_protection_state"] as? String, "protected")
        XCTAssertEqual(object["session_color"] as? String, "#1aB2c3")
    }

    func testEmitSessionEncodesAllAbsentOptionalFieldsAsNull() throws {
        let output = try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "legacy-name", "corrupt",
        ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "legacy-name")
        for key in [
            "session_color", "meta_status", "agent_session_id", "project_dir",
            "created_at", "last_checkpoint_at", "exit_status", "finished_at", "model",
            "context_used_tokens", "context_window", "agent_turn_state", "agent_turn_id",
            "power_protection_state",
        ] {
            XCTAssertTrue(object[key] is NSNull, "expected \(key) to be null")
        }
    }

    func testEmitSessionRejectsInvalidFixedDomainValues() throws {
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "emit", "session", "other", "session", "running",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidProvider("other"))
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "session", "running",
            "--agent-turn-state", "thinking",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidAgentTurnState("thinking"))
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "session", "running",
            "--power-state", "maybe",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidPowerState("maybe"))
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "session", "running",
            "--session-color", "blue",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidSessionColor("blue"))
        }
    }

    func testMetaGetUsesFallbackPaths() throws {
        let file = temporaryDirectory.appendingPathComponent("meta.json")
        try Data(#"{"agent_session_id":null,"codex_session_id":"legacy"}"#.utf8)
            .write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "meta", "get", file.path, "agent_session_id", "codex_session_id",
        ])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "legacy\n")
    }

    func testReadOnlyCommandsUseInjectedStandardInputForDeviceAndDashPaths() throws {
        let metadata = Data(#"{"state":"working"}"#.utf8)

        for path in ["/dev/stdin", "-"] {
            let output = try DetachStateCommand.run(
                arguments: ["meta", "get", path, "state"],
                standardInput: metadata)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "working\n")
        }

        let transcript = Data("""
        {"payload":{"id":"session-1"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        """.utf8)
        XCTAssertTrue(try DetachStateCommand.run(
            arguments: [
                "jsonl", "validate", "codex", "/dev/stdin", "session-1",
            ],
            standardInput: transcript).isEmpty)
    }

    func testMetaGetSupportsDottedNestedPaths() throws {
        let file = temporaryDirectory.appendingPathComponent("nested-meta.json")
        try Data(#"{"payload":{"id":"nested-id"}}"#.utf8).write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "meta", "get", file.path, "payload.id",
        ])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "nested-id\n")
    }

    func testMetaUsableSucceedsOnlyForUsableSchemaOneMetadata() throws {
        let valid = temporaryDirectory.appendingPathComponent("valid-meta.json")
        let invalid = temporaryDirectory.appendingPathComponent("invalid-meta.json")
        try Data(#"{"schema":1,"session_name":"session","project_dir":"/tmp/project"}"#.utf8)
            .write(to: valid)
        try Data(#"{"schema":2,"session_name":"session","project_dir":"/tmp/project"}"#.utf8)
            .write(to: invalid)

        XCTAssertTrue(try DetachStateCommand.run(arguments: [
            "meta", "usable", valid.path, "session",
        ]).isEmpty)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "usable", invalid.path, "session",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .unusableMetadata)
        }
    }

    func testMetaCreateWritesTypedObjectAndRefusesAnExistingFile() throws {
        let file = temporaryDirectory.appendingPathComponent("created-meta.json")

        XCTAssertTrue(try DetachStateCommand.run(arguments: [
            "meta", "create", file.path,
            "--integer", "schema", "1",
            "--string", "session_name", "session",
            "--number", "battery", "42.5",
            "--bool", "active", "false",
            "--null", "exit_status",
        ]).isEmpty)

        let created = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: created) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["session_name"] as? String, "session")
        XCTAssertEqual(object["battery"] as? Double, 42.5)
        XCTAssertEqual(object["active"] as? Bool, false)
        XCTAssertTrue(object["exit_status"] is NSNull)

        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "create", file.path,
            "--string", "session_name", "replacement",
        ]))
        XCTAssertEqual(try Data(contentsOf: file), created)
    }

    func testMetaMatchesUsesCodexDefaultAndCaseInsensitiveSessionIdentity() throws {
        let file = temporaryDirectory.appendingPathComponent("matching-meta.json")
        try Data(#"{"agent_session_id":null,"codex_session_id":"ABC-123"}"#.utf8)
            .write(to: file)

        XCTAssertTrue(try DetachStateCommand.run(arguments: [
            "meta", "matches", file.path, "codex", "abc-123",
        ]).isEmpty)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "matches", file.path, "claude", "abc-123",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .metadataMismatch)
        }
    }

    func testMetaPatchIsAtomicAndRejectsStaleWriter() throws {
        let file = temporaryDirectory.appendingPathComponent("meta.json")
        let original = Data(#"{"schema":1,"session_name":"s","project_dir":"/tmp/p","run_token":"current","future":42}"#.utf8)
        try original.write(to: file)

        _ = try DetachStateCommand.run(arguments: [
            "meta", "patch", file.path,
            "--run-token", "current",
            "--string", "status", "running",
            "--integer", "exit_status", "7",
        ])
        let afterValidPatch = try Data(contentsOf: file)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: afterValidPatch) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "running")
        XCTAssertEqual(object["exit_status"] as? Int, 7)
        XCTAssertEqual(object["future"] as? Int, 42)

        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "patch", file.path,
            "--run-token", "stale",
            "--string", "status", "failed",
        ]))
        XCTAssertEqual(try Data(contentsOf: file), afterValidPatch)
    }

    func testJSONLValidateReturnsNoPayloadForAValidTranscript() throws {
        let file = temporaryDirectory.appendingPathComponent("rollout.jsonl")
        try Data("""
        {"payload":{"id":"session-1"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        """.utf8).write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "jsonl", "validate", "codex", file.path, "session-1",
        ])

        XCTAssertTrue(output.isEmpty)
    }

    func testJSONLFirstReturnsTheFirstNonNullScalarFromAMatchingObject() throws {
        let file = temporaryDirectory.appendingPathComponent("first.jsonl")
        try Data("""
        partial-prefix
        {"payload":{"id":null}}
        {"other":true}
        {"payload":{"session_id":"session-1"}}
        {"payload":{"id":"session-2"}}
        """.utf8).write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "jsonl", "first", file.path, "payload.id", "payload.session_id",
        ])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "session-1\n")
    }

    func testJSONLSummaryUsesStableSnakeCaseJSON() throws {
        let file = temporaryDirectory.appendingPathComponent("rollout.jsonl")
        try Data("""
        {"payload":{"model":"gpt-test"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        """.utf8).write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "jsonl", "summary", "codex", file.path,
        ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gpt-test")
        XCTAssertEqual(object["agent_turn_state"] as? String, "working")
        XCTAssertEqual(object["agent_turn_id"] as? String, "t1")
        XCTAssertTrue(object["context_used"] is NSNull)
    }

    func testJSONLSummaryTSVUsesStableOrderAndOmitsNullValues() throws {
        let file = temporaryDirectory.appendingPathComponent("summary-tsv.jsonl")
        try Data("""
        {"payload":{"model":"gpt-test"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        """.utf8).write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "jsonl", "summary", "codex", file.path, "--tsv",
        ])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), """
        model\tgpt-test
        agent_turn_state\tworking
        agent_turn_id\tt1

        """)
    }
}
