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
            "--display-name", "Rev (ai)",
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
            "schema", "provider", "session_name", "name", "display_name", "session_color",
            "effective_status", "meta_status", "agent_session_id", "project_dir",
            "created_at", "last_checkpoint_at", "exit_status", "finished_at", "model",
            "context_used_tokens", "context_window", "agent_turn_state", "agent_turn_id",
            "power_protection_state", "health_reason", "health_actions",
            "reconcile_action", "ownership_proven", "cleanup_eligible",
            "worker_pid", "provider_pid", "worker_heartbeat_at",
            "heartbeat_fresh", "checkpoint_fresh",
        ]))
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["provider"] as? String, "claude")
        XCTAssertEqual(object["session_name"] as? String, "detach-claude-my-project-abcd")
        XCTAssertEqual(object["name"] as? String, "my-project-abcd")
        XCTAssertEqual(object["display_name"] as? String, "Rev (ai)")
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
            "display_name", "session_color", "meta_status", "agent_session_id", "project_dir",
            "created_at", "last_checkpoint_at", "exit_status", "finished_at", "model",
            "context_used_tokens", "context_window", "agent_turn_state", "agent_turn_id",
            "power_protection_state", "health_reason", "health_actions",
            "reconcile_action", "ownership_proven", "cleanup_eligible",
            "worker_pid", "provider_pid", "worker_heartbeat_at",
            "heartbeat_fresh", "checkpoint_fresh",
        ] {
            XCTAssertTrue(object[key] is NSNull, "expected \(key) to be null")
        }
    }

    func testEmitSessionAcceptsStructuredInputState() throws {
        let output = try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "detach-codex-question", "running",
            "--agent-turn-state", "needs_input",
            "--agent-turn-id", "turn-1",
        ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(object["agent_turn_state"] as? String, "needs_input")
    }

    func testEmitSessionPreservesDisplayNamePlaceholderCharacters() throws {
        for displayName in ["-", "?"] {
            let output = try DetachStateCommand.run(arguments: [
                "emit", "session", "codex", "detach-codex-human", "running",
                "--display-name", displayName,
            ])
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: output) as? [String: Any])

            XCTAssertEqual(object["display_name"] as? String, displayName)
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

    func testEmitSessionAcceptsNullPlaceholdersAndTypedHealthPayload() throws {
        let health = SessionHealthAssessment(
            schema: 1,
            effectiveStatus: .running,
            reason: .heartbeatStale,
            actions: [.attach, .stop],
            reconcileAction: .none,
            ownershipProven: true,
            cleanupEligible: false,
            heartbeatFresh: false,
            checkpointFresh: true)
        let healthJSON = String(decoding: try JSONEncoder().encode(health), as: UTF8.self)

        let output = try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "detach-codex-project", "running",
            "--agent-turn-state", "-",
            "--session-color", "?",
            "--power-state", "",
            "--health-json", healthJSON,
            "--worker-pid", "-",
            "--provider-pid", "321",
            "--worker-heartbeat-at", "?",
        ])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any])

        XCTAssertTrue(object["agent_turn_state"] is NSNull)
        XCTAssertTrue(object["session_color"] is NSNull)
        XCTAssertTrue(object["power_protection_state"] is NSNull)
        XCTAssertEqual(object["health_reason"] as? String, "heartbeat_stale")
        XCTAssertEqual(object["health_actions"] as? [String], ["attach", "stop"])
        XCTAssertEqual(object["ownership_proven"] as? Bool, true)
        XCTAssertEqual(object["checkpoint_fresh"] as? Bool, true)
        XCTAssertTrue(object["worker_pid"] is NSNull)
        XCTAssertEqual(object["provider_pid"] as? Int, 321)
        XCTAssertTrue(object["worker_heartbeat_at"] is NSNull)
    }

    func testEmitSessionRejectsMalformedOrMismatchedHealthPayload() throws {
        for payload in ["not-json", #"{"schema":1,"effective_status":"stopped","reason":"finished","actions":[],"reconcile_action":"none","ownership_proven":false,"cleanup_eligible":true,"heartbeat_fresh":false,"checkpoint_fresh":false}"#] {
            XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
                "emit", "session", "codex", "session", "running",
                "--health-json", payload,
            ])) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
            }
        }
    }

    func testCommandDispatcherAndEmitSessionRejectMalformedArguments() {
        for arguments in [
            [String](),
            ["emit"],
            ["unknown", "command"],
            ["emit", "context", "too", "short"],
            ["emit", "session", "codex", "only-name"],
            ["emit", "session", "codex", "session", "running", "--model"],
            ["emit", "session", "codex", "session", "running", "--model", "a", "--model", "b"],
            ["emit", "session", "codex", "session", "running", "--unknown", "value"],
            ["meta", "get", "only-path"],
            ["meta", "snapshot", "only-path"],
            ["meta", "snapshots"],
            ["health", "session", "--"],
            ["health", "sessions"],
            ["meta", "usable", "only-path"],
            ["meta", "create"],
            ["meta", "patch"],
            ["meta", "matches", "only-path"],
            ["jsonl", "first", "only-path"],
        ] {
            XCTAssertThrowsError(try DetachStateCommand.run(arguments: arguments)) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
            }
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "emit", "session", "codex", "session", "running",
            "--worker-pid", "not-a-pid",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidInteger("not-a-pid"))
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

    func testMetaGetRendersEveryScalarAndReturnsEmptyForMissingValues() throws {
        let file = temporaryDirectory.appendingPathComponent("scalars.json")
        try Data(#"{"string":"value","integer":7,"number":1.5,"bool":true,"null":null}"#.utf8)
            .write(to: file)

        let expectations = [
            ("string", "value\n"),
            ("integer", "7\n"),
            ("number", "1.5\n"),
            ("bool", "true\n"),
        ]
        for (path, expected) in expectations {
            let output = try DetachStateCommand.run(arguments: [
                "meta", "get", file.path, path,
            ])
            XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
        }
        XCTAssertTrue(try DetachStateCommand.run(arguments: [
            "meta", "get", file.path, "absent",
        ]).isEmpty)
        XCTAssertTrue(try DetachStateCommand.run(arguments: [
            "meta", "get", file.path, "null",
        ]).isEmpty)
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

    func testMetaSnapshotReadsListFieldsOnceWithNULSafeFallbacks() throws {
        let file = temporaryDirectory.appendingPathComponent("snapshot-meta.json")
        let project = "/tmp/project\twith\ncontrols"
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1,
            "session_name": "detach-codex-project",
            "project_dir": project,
            "status": "stopped",
            "agent_session_id": NSNull(),
            "codex_session_id": "legacy-id",
            "transcript_path": NSNull(),
            "rollout_path": "/tmp/rollout.jsonl",
            "exit_status": 143,
            "health_schema": 1,
        ])
        try data.write(to: file)

        let output = try DetachStateCommand.run(arguments: [
            "meta", "snapshot", file.path, "detach-codex-project",
        ])
        let components = output.split(
            separator: 0,
            omittingEmptySubsequences: false)
        XCTAssertEqual(components.last, Data.SubSequence())
        let values = stride(from: 0, to: components.count - 1, by: 2).reduce(
            into: [String: String]()) { result, index in
                result[String(decoding: components[index], as: UTF8.self)] =
                    String(decoding: components[index + 1], as: UTF8.self)
            }

        XCTAssertEqual(values["status"], "stopped")
        XCTAssertEqual(values["project_dir"], project)
        XCTAssertEqual(values["agent_session_id"], "legacy-id")
        XCTAssertEqual(values["transcript_path"], "/tmp/rollout.jsonl")
        XCTAssertEqual(values["exit_status"], "143")
        XCTAssertEqual(values["health_schema"], "1")
        XCTAssertEqual(values["display_name"], "")
        XCTAssertEqual(values["snapshot_complete"], "true")

        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshot", file.path, "detach-codex-other",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .unusableMetadata)
        }
    }

    func testMetaSnapshotsBatchesFallbacksAndRejectsIncompleteInput() throws {
        let root = temporaryDirectory.appendingPathComponent("sessions", isDirectory: true)
        let first = root.appendingPathComponent("detach-codex-one", isDirectory: true)
        let second = root.appendingPathComponent("detach-codex-two", isDirectory: true)
        let third = root.appendingPathComponent("detach-claude-three", isDirectory: true)
        let checkpointDirectory = first.appendingPathComponent("checkpoint", isDirectory: true)
        let invalid = first.appendingPathComponent("meta.json")
        let checkpoint = checkpointDirectory.appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(
            at: checkpointDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: second, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: third, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: invalid)
        try Data(count: 1_048_577).write(to: second.appendingPathComponent("meta.json"))
        let project = "/tmp/project\twith\ncontrols"
        try JSONSerialization.data(withJSONObject: [
            "schema": 1,
            "session_name": "detach-codex-one",
            "project_dir": project,
            "status": "stopped",
        ]).write(to: checkpoint)
        try JSONSerialization.data(withJSONObject: [
            "schema": 1,
            "session_name": "detach-claude-three",
            "project_dir": "/tmp/primary",
            "status": "running",
        ]).write(to: third.appendingPathComponent("meta.json"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("regular-file"))

        let output = try DetachStateCommand.run(arguments: [
            "meta", "snapshots", root.path,
        ])
        let values = output.split(separator: 0, omittingEmptySubsequences: false)
            .dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
        let recordSize = 19
        XCTAssertEqual(values.count, recordSize * 3 + 2)
        XCTAssertEqual(values[0], "detach-claude-three")
        XCTAssertEqual(values[1], "true")
        XCTAssertEqual(values[2], "running")
        XCTAssertEqual(values[4], "/tmp/primary")
        XCTAssertEqual(values[recordSize], "detach-codex-one")
        XCTAssertEqual(values[recordSize + 1], "true")
        XCTAssertEqual(values[recordSize + 2], "stopped")
        XCTAssertEqual(values[recordSize + 4], project)
        XCTAssertEqual(values[recordSize * 2], "detach-codex-two")
        XCTAssertEqual(values[recordSize * 2 + 1], "false")
        XCTAssertTrue(values[(recordSize * 2 + 2)..<(recordSize * 3)].allSatisfy(\.isEmpty))
        XCTAssertEqual(Array(values.suffix(2)), ["", "true"])
        let repeatedSeparatorRoot = root.path.replacingOccurrences(
            of: "/sessions", with: "//sessions")
        XCTAssertEqual(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", repeatedSeparatorRoot,
        ]), output)

        for invalidRoot in [
            "relative/sessions", root.path + "/", root.path + "/../sessions",
            root.path + "\n",
        ] {
            XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
                "meta", "snapshots", invalidRoot,
            ])) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
            }
        }

        let invalidSession = root.appendingPathComponent("unsafe name", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidSession, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", root.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }
        try FileManager.default.removeItem(at: invalidSession)

        let unsafeRoot = temporaryDirectory.appendingPathComponent("unsafe-sessions")
        try FileManager.default.createSymbolicLink(at: unsafeRoot, withDestinationURL: root)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", unsafeRoot.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }

        let external = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let checkpointRoot = temporaryDirectory.appendingPathComponent(
            "checkpoint-sessions", isDirectory: true)
        let checkpointSession = checkpointRoot.appendingPathComponent(
            "detach-codex-checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(
            at: checkpointSession, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: checkpointSession.appendingPathComponent("meta.json"))
        try FileManager.default.createSymbolicLink(
            at: checkpointSession.appendingPathComponent("checkpoint"),
            withDestinationURL: external)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", checkpointRoot.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }

        let invalidCheckpointRoot = temporaryDirectory.appendingPathComponent(
            "invalid-checkpoint-sessions", isDirectory: true)
        let invalidCheckpointSession = invalidCheckpointRoot.appendingPathComponent(
            "detach-codex-invalid-checkpoint", isDirectory: true)
        let invalidCheckpointDirectory = invalidCheckpointSession.appendingPathComponent(
            "checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(
            at: invalidCheckpointDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: invalidCheckpointDirectory.appendingPathComponent("meta.json"))
        let invalidCheckpointOutput = try DetachStateCommand.run(arguments: [
            "meta", "snapshots", invalidCheckpointRoot.path,
        ])
        let invalidCheckpointValues = invalidCheckpointOutput.split(
            separator: 0, omittingEmptySubsequences: false)
        XCTAssertEqual(String(decoding: invalidCheckpointValues[0], as: UTF8.self),
                       "detach-codex-invalid-checkpoint")
        XCTAssertEqual(String(decoding: invalidCheckpointValues[1], as: UTF8.self), "false")

        let unreadableRoot = temporaryDirectory.appendingPathComponent(
            "unreadable-sessions", isDirectory: true)
        let unreadableSession = unreadableRoot.appendingPathComponent(
            "detach-codex-unreadable", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unreadableSession, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o100], ofItemAtPath: unreadableSession.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: unreadableSession.path)
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", unreadableRoot.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: unreadableSession.path)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", unreadableRoot.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }

        let unreadableCheckpointRoot = temporaryDirectory.appendingPathComponent(
            "unreadable-checkpoint-sessions", isDirectory: true)
        let unreadableCheckpointSession = unreadableCheckpointRoot.appendingPathComponent(
            "detach-codex-unreadable-checkpoint", isDirectory: true)
        let unreadableCheckpoint = unreadableCheckpointSession.appendingPathComponent(
            "checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unreadableCheckpoint, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o100], ofItemAtPath: unreadableCheckpoint.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: unreadableCheckpoint.path)
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", unreadableCheckpointRoot.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }

        let linked = root.appendingPathComponent("detach-codex-linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "snapshots", root.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
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

    func testMetadataMutationParserRejectsInvalidTypedChanges() throws {
        let file = temporaryDirectory.appendingPathComponent("invalid-meta.json")
        try Data(#"{"run_token":"current"}"#.utf8).write(to: file)
        let cases: [([String], DetachStateCommandError)] = [
            (["--integer", "count", "one"], .invalidInteger("one")),
            (["--number", "load", "nan"], .invalidNumber("nan")),
            (["--bool", "active", "yes"], .invalidBoolean("yes")),
            (["--null"], .invalidArguments),
            (["--string", "key"], .invalidArguments),
            (["--unknown", "key", "value"], .invalidArguments),
        ]
        for (arguments, expectedError) in cases {
            XCTAssertThrowsError(try DetachStateCommand.run(
                arguments: ["meta", "patch", file.path] + arguments
            )) { error in
                XCTAssertEqual(error as? DetachStateCommandError, expectedError)
            }
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "create", temporaryDirectory.appendingPathComponent("new.json").path,
            "--run-token", "forbidden", "--string", "key", "value",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "meta", "patch", file.path,
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }
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

    func testJSONLFirstSupportsInjectedInputAndAnAbsentScalar() throws {
        let input = Data("""
        {"payload":{"id":"stdin-session"}}
        """.utf8)
        let found = try DetachStateCommand.run(
            arguments: ["jsonl", "first", "-", "payload.id"],
            standardInput: input)
        let absent = try DetachStateCommand.run(
            arguments: ["jsonl", "first", "-", "payload.missing"],
            standardInput: input)

        XCTAssertEqual(String(decoding: found, as: UTF8.self), "stdin-session\n")
        XCTAssertTrue(absent.isEmpty)
    }

    func testJSONLValidationRejectsWrongIdentityAndMalformedArguments() throws {
        let transcript = Data(#"{"payload":{"id":"session-1"}}"#.utf8)
        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: ["jsonl", "validate", "codex", "-", "session-2"],
            standardInput: transcript
        )) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidTranscript)
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "jsonl", "validate", "codex", "only-path",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "jsonl", "validate", "other", "-", "session",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidProvider("other"))
        }
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

    func testJSONLSummaryUsesOnlyTheBoundedInjectedTail() throws {
        var input = Data(repeating: 0x20, count: 300_000)
        input.append(Data("""
        {"payload":{"model":"tail-model"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"tail-turn"}}
        """.utf8))

        let output = try DetachStateCommand.run(
            arguments: ["jsonl", "summary", "codex", "-"],
            standardInput: input)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "tail-model")
        XCTAssertEqual(object["agent_turn_id"] as? String, "tail-turn")
    }

    func testJSONLSummaryRejectsUnsupportedOptions() {
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "jsonl", "summary", "codex", "-", "--json",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }
    }

    func testHealthEvaluateRejectsIncompleteDuplicateAndInvalidEvidence() {
        let valid = [
            "health", "evaluate",
            "--metadata-valid", "true",
            "--runtime-identity-expected", "true",
            "--meta-status", "running",
            "--tmux", "live",
            "--run-token", "match",
            "--worker", "alive",
            "--provider-process", "alive",
            "--heartbeat", "fresh",
            "--checkpoint", "fresh",
            "--checkpoint-recoverable", "true",
            "--agent-session-known", "true",
        ]
        let malformed = [
            Array(valid.dropLast(2)),
            valid + ["--worker", "dead"],
            valid + ["--unsupported", "value"],
            replacing("running", with: "future", in: valid),
            replacing("live", with: "maybe", in: valid),
            replacing("match", with: "maybe", in: valid),
            replacing("alive", with: "maybe", in: valid),
            replacing("fresh", with: "maybe", in: valid),
        ]
        for arguments in malformed {
            XCTAssertThrowsError(try DetachStateCommand.run(arguments: arguments)) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
            }
        }

        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: replacing("true", with: "yes", in: valid)
        )) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidBoolean("yes"))
        }
    }

    func testHealthEvaluateEnvelopeCarriesStatusAndTypedJSONTogether() throws {
        let output = try DetachStateCommand.run(arguments: [
            "health", "evaluate",
            "--metadata-valid", "true",
            "--runtime-identity-expected", "true",
            "--meta-status", "running",
            "--tmux", "live",
            "--run-token", "match",
            "--worker", "alive",
            "--provider-process", "alive",
            "--heartbeat", "fresh",
            "--checkpoint", "fresh",
            "--checkpoint-recoverable", "true",
            "--agent-session-known", "true",
            "--envelope",
        ])
        let newline = try XCTUnwrap(output.firstIndex(of: 0x0A))
        XCTAssertEqual(String(decoding: output[..<newline], as: UTF8.self), "running")
        let assessment = try JSONDecoder().decode(
            SessionHealthAssessment.self,
            from: output[output.index(after: newline)...])
        XCTAssertEqual(assessment.effectiveStatus, .running)
        XCTAssertEqual(assessment.reason, .healthy)
    }

    func testHealthSessionEmitsTypedPublicJSONAndHidesCollisionIdentity() throws {
        let output = try DetachStateCommand.run(arguments: [
            "health", "session",
            "--metadata-valid", "true",
            "--runtime-identity-expected", "true",
            "--meta-status", "running",
            "--tmux", "foreign",
            "--run-token", "missing",
            "--worker", "unknown",
            "--provider-process", "unknown",
            "--heartbeat", "missing",
            "--checkpoint", "missing",
            "--checkpoint-recoverable", "false",
            "--agent-session-known", "true",
            "--", "codex", "detach-codex-session",
            "--project-dir", "/tmp/project",
            "--session-color", "#123456",
        ])
        let newline = try XCTUnwrap(output.firstIndex(of: 0x0A))
        XCTAssertEqual(
            String(decoding: output[..<newline], as: UTF8.self),
            "collision")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: output[output.index(after: newline)...]) as? [String: Any])
        XCTAssertEqual(object["effective_status"] as? String, "collision")
        XCTAssertEqual(object["health_reason"] as? String, "foreign_tmux")
        XCTAssertEqual(object["cleanup_eligible"] as? Bool, false)
        XCTAssertTrue(object["session_color"] is NSNull)
    }

    func testHealthSessionsBatchesNULSafeRequestsAndRequiresCompletion() throws {
        let evidence = [
            "--metadata-valid", "true",
            "--runtime-identity-expected", "false",
            "--meta-status", "stopped",
            "--tmux", "missing",
            "--run-token", "missing",
            "--worker", "unknown",
            "--provider-process", "unknown",
            "--heartbeat", "missing",
            "--checkpoint", "missing",
            "--checkpoint-recoverable", "false",
            "--agent-session-known", "false",
        ]
        let first = evidence + [
            "--", "codex", "detach-codex-one",
            "--project-dir", "/tmp/project\twith\ncontrols",
        ]
        let second = evidence + [
            "--", "codex", "detach-codex-two",
            "--project-dir", "/tmp/two",
        ]
        var input = Data()
        for record in [first, second] {
            input.append(Data("\(record.count)".utf8))
            input.append(0)
            for value in record {
                input.append(Data(value.utf8))
                input.append(0)
            }
        }
        let incomplete = input
        input.append(Data("0".utf8))
        input.append(0)

        let output = try DetachStateCommand.run(
            arguments: ["health", "sessions", "-"],
            standardInput: input)
        let objects = try output.split(separator: 0x0A).map {
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(
            objects.compactMap { $0["session_name"] as? String },
            ["detach-codex-one", "detach-codex-two"])
        XCTAssertEqual(
            objects.first?["project_dir"] as? String,
            "/tmp/project\twith\ncontrols")

        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: ["health", "sessions", "-"],
            standardInput: incomplete
        )) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }

        let malformed = [
            Data("1".utf8),
            Data("not-a-count\0".utf8),
            Data("0\0trailing\0".utf8),
            Data("2\0only-one\0".utf8),
            Data([0x31, 0x00, 0xFF, 0x00]),
        ]
        for payload in malformed {
            XCTAssertThrowsError(try DetachStateCommand.run(
                arguments: ["health", "sessions", "-"],
                standardInput: payload
            )) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
            }
        }
    }

    func testMaintenanceReconcileDispatchesAndRejectsInvalidInventory() throws {
        let actionable: [String: Any] = [
            "schema": 1,
            "provider": "codex",
            "session_name": "detach-codex-dead",
            "name": "dead",
            "effective_status": "recoverable",
            "health_reason": "recoverable_checkpoint",
            "reconcile_action": "mark_recoverable",
        ]
        let inventory = try JSONSerialization.data(withJSONObject: actionable)
        let output = try DetachStateCommand.run(
            arguments: ["maintenance", "reconcile", "-"],
            standardInput: inventory)
        let plan = try JSONDecoder().decode(SessionMaintenancePlan.self, from: output)

        XCTAssertEqual(plan.items.map(\.sessionName), ["detach-codex-dead"])
        XCTAssertEqual(plan.items.first?.action, .markRecoverable)

        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: ["maintenance", "reconcile", "-"],
            standardInput: Data("not-json\n".utf8)
        )) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidStorageInventory)
        }
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "maintenance", "reconcile", "-", "extra",
        ])) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
        }
    }

    func testStorageCommandsRejectMalformedArgumentsAndPayloads() throws {
        let state = temporaryDirectory.appendingPathComponent("invalid-storage")
        let reportPrefix = [
            "storage", "report",
            "--state-root", state.path,
            "--codex-root", state.appendingPathComponent("codex").path,
            "--claude-root", state.appendingPathComponent("claude").path,
            "--sessions", "-",
        ]
        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: reportPrefix,
            standardInput: Data("not-json\n".utf8)
        )) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidStorageInventory)
        }

        for arguments in [
            Array(reportPrefix.dropLast()),
            [
                "storage", "report",
                "--state-root", state.path,
                "--codex-root", state.appendingPathComponent("codex").path,
                "--claude-root", state.appendingPathComponent("claude").path,
            ],
            reportPrefix + ["--state-root", state.path],
            ["storage", "plan"],
            ["storage", "plan", "-"],
            ["storage", "plan", "-", "--all", "--session", "name"],
            ["storage", "plan", "-", "--session"],
        ] {
            XCTAssertThrowsError(try DetachStateCommand.run(
                arguments: arguments,
                standardInput: Data("{}".utf8)
            )) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidArguments)
            }
        }

        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: ["storage", "plan", "-", "--all"],
            standardInput: Data("{}".utf8)
        )) { error in
            XCTAssertEqual(error as? DetachStateCommandError, .invalidStorageReport)
        }
    }

    func testStorageReportUsesAllocatedBytesAndOnlyAllowsStoppedOrOrphanedCleanup() throws {
        let state = temporaryDirectory.appendingPathComponent("state", isDirectory: true)
        let stopped = try makeStorageSession(
            state: state, provider: .codex, name: "detach-codex-stopped", status: .stopped)
        let running = try makeStorageSession(
            state: state, provider: .claude, name: "detach-claude-running", status: .running)
        try Data(repeating: 0x61, count: 12_000).write(
            to: stopped.appendingPathComponent("checkpoint/rollout.jsonl"))
        try Data(repeating: 0x62, count: 3_000).write(
            to: stopped.appendingPathComponent("checkpoint/pane.txt"))
        try Data("log\n".utf8).write(to: stopped.appendingPathComponent("checkpoint.log"))
        try Data(repeating: 0x63, count: 1_000).write(
            to: running.appendingPathComponent("checkpoint/transcript.jsonl"))

        let report = try storageReport(
            state: state,
            sessions: [
                storageInventoryLine(.codex, "detach-codex-stopped", .stopped),
                storageInventoryLine(.claude, "detach-claude-running", .running),
            ])
        XCTAssertTrue(report.complete)
        XCTAssertGreaterThan(report.allocatedBytes, 0)
        XCTAssertGreaterThan(report.categories.checkpointBytes, 0)
        XCTAssertGreaterThan(report.categories.logBytes, 0)
        XCTAssertEqual(report.sessions.count, 2)
        XCTAssertTrue(try XCTUnwrap(report.sessions.first {
            $0.sessionName == "detach-codex-stopped"
        }).deletable)
        XCTAssertFalse(try XCTUnwrap(report.sessions.first {
            $0.sessionName == "detach-claude-running"
        }).deletable)

        let encoded = try JSONEncoder().encode(report)
        let planData = try DetachStateCommand.run(
            arguments: ["storage", "plan", "-", "--all"],
            standardInput: encoded)
        let plan = try JSONDecoder().decode(StorageCleanupPlan.self, from: planData)
        XCTAssertEqual(plan.sessions.map(\.sessionName), ["detach-codex-stopped"])
        XCTAssertThrowsError(try DetachStateCommand.run(
            arguments: [
                "storage", "plan", "-", "--session", "detach-claude-running",
            ],
            standardInput: encoded)) { error in
            XCTAssertEqual(
                error as? DetachStateCommandError,
                .unsafeStorageSelection("detach-claude-running"))
        }
    }

    func testStorageReportSupportsAnEmptyMissingStateRoot() throws {
        let state = temporaryDirectory.appendingPathComponent("missing-state", isDirectory: true)
        let report = try storageReport(state: state, sessions: [])

        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.allocatedBytes, 0)
        XCTAssertEqual(report.logicalBytes, 0)
        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testStorageReportDoesNotInflateSparseFiles() throws {
        let state = temporaryDirectory.appendingPathComponent("sparse-state", isDirectory: true)
        let session = try makeStorageSession(
            state: state, provider: .codex, name: "detach-codex-sparse", status: .stopped)
        let sparse = session.appendingPathComponent("checkpoint/codex-state.sqlite")
        FileManager.default.createFile(atPath: sparse.path, contents: Data())
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024)
        try handle.close()

        let report = try storageReport(
            state: state,
            sessions: [storageInventoryLine(.codex, "detach-codex-sparse", .stopped)])
        let measured = try XCTUnwrap(report.sessions.first)
        XCTAssertGreaterThanOrEqual(measured.logicalBytes, 128 * 1_024 * 1_024)
        XCTAssertLessThan(measured.allocatedBytes, measured.logicalBytes)
    }

    func testStorageReportNeverFollowsSymlinksOrScansProviderStorage() throws {
        let state = temporaryDirectory.appendingPathComponent("links-state", isDirectory: true)
        let session = try makeStorageSession(
            state: state, provider: .codex, name: "detach-codex-links", status: .orphaned)
        let external = temporaryDirectory.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 0x65, count: 2_000_000).write(
            to: external.appendingPathComponent("provider-transcript.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: session.appendingPathComponent("checkpoint/external"),
            withDestinationURL: external)

        let report = try storageReport(
            state: state,
            excluded: [external.path],
            sessions: [storageInventoryLine(.codex, "detach-codex-links", .orphaned)])
        let measured = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(measured.symlinkCount, 1)
        XCTAssertLessThan(measured.logicalBytes, 2_000_000)
        XCTAssertTrue(measured.deletable)

        let providerState = external.appendingPathComponent("detach-state", isDirectory: true)
        let providerSession = try makeStorageSession(
            state: providerState,
            provider: .codex,
            name: "detach-codex-provider-owned",
            status: .stopped)
        try Data(repeating: 0x66, count: 40_000).write(
            to: providerSession.appendingPathComponent("checkpoint/rollout.jsonl"))
        let refused = try storageReport(
            state: providerState,
            codexRoot: providerState.appendingPathComponent("codex").path,
            excluded: [providerState.path],
            sessions: [storageInventoryLine(.codex, "detach-codex-provider-owned", .stopped)])
        XCTAssertTrue(refused.sessions.isEmpty)
        XCTAssertFalse(refused.complete)
        XCTAssertTrue(refused.issues.contains { $0.code == "sessions_root_overlaps_excluded_storage" })

        let nestedProviderStorage = state.appendingPathComponent(
            "codex/sessions/detach-codex-links/checkpoint/provider-store",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedProviderStorage, withIntermediateDirectories: true)
        let nestedRefused = try storageReport(
            state: state,
            excluded: [nestedProviderStorage.path],
            sessions: [storageInventoryLine(.codex, "detach-codex-links", .orphaned)])
        XCTAssertTrue(nestedRefused.sessions.isEmpty)
        XCTAssertFalse(nestedRefused.complete)
        XCTAssertTrue(nestedRefused.issues.contains {
            $0.code == "sessions_root_overlaps_excluded_storage"
        })

        let providerParent = temporaryDirectory.appendingPathComponent(
            "provider-parent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerParent, withIntermediateDirectories: true)
        let stateInsideProvider = providerParent.appendingPathComponent("state", isDirectory: true)
        let stateRefused = try storageReport(
            state: stateInsideProvider,
            excluded: [providerParent.path],
            sessions: [])
        XCTAssertFalse(stateRefused.complete)
        XCTAssertTrue(stateRefused.issues.contains {
            $0.code == "state_root_overlaps_excluded_storage"
        })
    }

    func testStorageReportRefusesASymlinkedProviderStateRoot() throws {
        let state = temporaryDirectory.appendingPathComponent("provider-link-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let external = temporaryDirectory.appendingPathComponent(
            "provider-link-target", isDirectory: true)
        _ = try makeStorageSession(
            state: external,
            provider: .codex,
            name: "detach-codex-provider-link",
            status: .stopped)
        let providerLink = state.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: providerLink,
            withDestinationURL: external.appendingPathComponent("codex", isDirectory: true))

        let report = try storageReport(
            state: state,
            sessions: [storageInventoryLine(.codex, "detach-codex-provider-link", .stopped)])

        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertFalse(report.complete)
        XCTAssertTrue(report.issues.contains { $0.code == "provider_state_root_unsafe" })
    }

    func testStorageReportHandlesUnreadableAndHardLinkedEntriesWithoutCrashing() throws {
        let state = temporaryDirectory.appendingPathComponent("edge-state", isDirectory: true)
        let session = try makeStorageSession(
            state: state, provider: .codex, name: "detach-codex-edge", status: .stopped)
        let original = session.appendingPathComponent("checkpoint/rollout.jsonl")
        let linked = session.appendingPathComponent("checkpoint/rollout-copy.jsonl")
        try Data(repeating: 0x67, count: 8_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)
        let unreadable = session.appendingPathComponent("checkpoint/unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        }

        let report = try storageReport(
            state: state,
            sessions: [storageInventoryLine(.codex, "detach-codex-edge", .stopped)])
        let measured = try XCTUnwrap(report.sessions.first)
        XCTAssertGreaterThanOrEqual(measured.hardLinkCount, 2)
        XCTAssertFalse(measured.deletable)
        XCTAssertEqual(
            measured.blockedReason,
            measured.scanComplete ? "hard_links" : "incomplete_scan")
        if !measured.scanComplete {
            XCTAssertTrue(report.issues.contains { $0.code == "directory_unreadable" })
        }
    }

    func testStorageReportHandlesLargeDirectoriesDeterministically() throws {
        let state = temporaryDirectory.appendingPathComponent("large-state", isDirectory: true)
        let session = try makeStorageSession(
            state: state, provider: .claude, name: "detach-claude-large", status: .stopped)
        let directory = session.appendingPathComponent("checkpoint/many", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for index in 0..<512 {
            try Data([UInt8(index % 251)]).write(
                to: directory.appendingPathComponent(String(format: "%04d", index)))
        }

        let first = try storageReport(
            state: state,
            sessions: [storageInventoryLine(.claude, "detach-claude-large", .stopped)])
        let second = try storageReport(
            state: state,
            sessions: [storageInventoryLine(.claude, "detach-claude-large", .stopped)])

        XCTAssertEqual(first, second)
        XCTAssertTrue(try XCTUnwrap(first.sessions.first).deletable)
        XCTAssertGreaterThan(first.allocatedBytes, 0)
    }

    private func makeStorageSession(
        state: URL,
        provider: Provider,
        name: String,
        status: EffectiveStatus
    ) throws -> URL {
        let root = state.appendingPathComponent(provider.rawValue)
            .appendingPathComponent("sessions", isDirectory: true)
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: session.appendingPathComponent("checkpoint", isDirectory: true),
            withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "schema": 1,
            "provider": provider.rawValue,
            "session_name": name,
            "project_dir": "/tmp/project",
            "status": status.rawValue,
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: session.appendingPathComponent("meta.json"))
        return session
    }

    private func storageInventoryLine(
        _ provider: Provider,
        _ name: String,
        _ status: EffectiveStatus
    ) -> String {
        let object: [String: Any] = [
            "schema": 1,
            "provider": provider.rawValue,
            "session_name": name,
            "name": name,
            "effective_status": status.rawValue,
            "cleanup_eligible": status == .stopped || status == .orphaned,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func replacing(
        _ oldValue: String,
        with newValue: String,
        in arguments: [String]
    ) -> [String] {
        var result = arguments
        if let index = result.firstIndex(of: oldValue) {
            result[index] = newValue
        }
        return result
    }

    private func storageReport(
        state: URL,
        codexRoot: String? = nil,
        excluded: [String] = [],
        sessions: [String]
    ) throws -> StorageReport {
        var arguments = [
            "storage", "report",
            "--state-root", state.path,
            "--codex-root", codexRoot ?? state.appendingPathComponent("codex").path,
            "--claude-root", state.appendingPathComponent("claude").path,
        ]
        for path in excluded {
            arguments += ["--exclude-root", path]
        }
        arguments += ["--sessions", "-"]
        let output = try DetachStateCommand.run(
            arguments: arguments,
            standardInput: Data((sessions.joined(separator: "\n") + "\n").utf8))
        return try JSONDecoder().decode(StorageReport.self, from: output)
    }
}
