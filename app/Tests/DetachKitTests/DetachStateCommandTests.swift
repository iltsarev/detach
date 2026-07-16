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
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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
