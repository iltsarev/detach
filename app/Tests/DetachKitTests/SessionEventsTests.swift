import CoreServices
import XCTest
@testable import DetachKit

final class SessionEventsTests: XCTestCase {
    private let configuration = SessionEventWatchConfiguration(
        stateRoot: "/private/tmp/detach-state",
        signalPath: "/private/tmp/detach-state/session-change",
        transcriptRoots: [
            "/private/tmp/codex/sessions",
            "/private/tmp/claude/projects",
        ])
    private let managedTranscriptPaths: Set<String> = [
        "/private/tmp/codex/sessions/2026/managed.jsonl",
        "/private/tmp/claude/projects/p/managed.jsonl",
    ]

    func testEventJSONRequiresSchemaOne() throws {
        let encoded = try JSONEncoder().encode(SessionEvent(event: .changed))
        XCTAssertEqual(
            SessionEventParser.parse(String(decoding: encoded, as: UTF8.self)),
            SessionEvent(event: .changed))
        XCTAssertNil(SessionEventParser.parse(#"{"schema":2,"event":"changed"}"#))
        XCTAssertNil(SessionEventParser.parse("not json"))
    }

    func testWatchArgumentsRequireTypedRootsAndJSON() throws {
        let parsed = try SessionEventWatchConfiguration.parse(arguments: [
                "--json",
                "--state-root", "/tmp/detach-state",
                "--signal", "/tmp/detach-state/session-change",
                "--transcript-root", "/tmp/codex/sessions",
                "--transcript-root", "/tmp/claude/projects",
            ])
        XCTAssertEqual(parsed, configuration)
        XCTAssertEqual(parsed.sessionsRoots, [
            "/private/tmp/detach-state/codex/sessions",
            "/private/tmp/detach-state/claude/sessions",
        ])
        // A relocated provider state root names its own sessions directory.
        let relocated = try SessionEventWatchConfiguration.parse(arguments: [
            "--json",
            "--state-root", "/tmp/detach-state",
            "--signal", "/tmp/detach-state/session-change",
            "--sessions-root", "/tmp/elsewhere/codex/sessions",
            "--sessions-root", "/tmp/detach-state/claude/sessions",
            "--transcript-root", "/tmp/codex/sessions",
        ])
        XCTAssertEqual(relocated.sessionsRoots, [
            "/private/tmp/elsewhere/codex/sessions",
            "/private/tmp/detach-state/claude/sessions",
        ])
        XCTAssertThrowsError(try SessionEventWatchConfiguration.parse(arguments: [
            "--state-root", "/tmp/detach-state",
            "--signal", "/tmp/detach-state/session-change",
            "--transcript-root", "/tmp/codex/sessions",
        ]))
        XCTAssertThrowsError(try SessionEventWatchConfiguration.parse(arguments: [
            "--json",
            "--state-root", "/tmp/detach-state",
            "--signal", "/tmp/outside",
            "--transcript-root", "/tmp/codex/sessions",
        ]))
    }

    func testClassifierIgnoresNoiseAndRecognizesLifecycleAndManagedTranscripts() {
        XCTAssertEqual(classify(paths: ["/private/tmp/detach-state/heartbeat"]), .ignored)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/detach-state/session-change"]),
            .lifecycle)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/codex/sessions/2026/managed.jsonl"]),
            .transcript)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/claude/projects/p/managed.jsonl"]),
            .transcript)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/claude/projects/p/turn.txt"]),
            .ignored)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/codex/sessions/2026/foreign.jsonl"]),
            .ignored)
    }

    func testDroppedOrRootChangedEventsForceResync() {
        for flag in [
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagRootChanged,
        ] {
            XCTAssertEqual(
                classify(paths: [], flags: [UInt32(flag)]),
                .resync)
        }
    }

    func testTranscriptBurstEmitsLeadingAndOneTrailingHint() {
        var reducer = SessionEventCoalescer()
        XCTAssertEqual(
            reducer.consume(.transcript),
            .emitAndScheduleTrailing(.changed))
        XCTAssertEqual(reducer.consume(.transcript), .scheduleTrailing)
        XCTAssertEqual(reducer.consume(.transcript), .scheduleTrailing)
        XCTAssertEqual(reducer.quietWindowElapsed(), .emit(.changed))
        XCTAssertEqual(reducer.quietWindowElapsed(), .none)
        XCTAssertEqual(reducer.consume(.lifecycle), .emit(.changed))
        XCTAssertEqual(reducer.consume(.resync), .emit(.resync))
    }

    func testTypedPublisherAtomicallyReplacesItsHint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-session-events-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let signal = root.appendingPathComponent("session-change")

        _ = try DetachStateCommand.run(arguments: [
            "events", "publish", signal.path,
        ])
        let first = try Data(contentsOf: signal)
        _ = try DetachStateCommand.run(arguments: [
            "events", "publish", signal.path,
        ])
        let second = try Data(contentsOf: signal)

        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(first, second)
        let attributes = try FileManager.default.attributesOfItem(atPath: signal.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)

        // Environment roots with a trailing slash produce `//`. The publisher
        // must standardize that path rather than silently disable every hint.
        _ = try DetachStateCommand.run(arguments: [
            "events", "publish", root.path + "//session-change",
        ])
        let third = try Data(contentsOf: signal)
        XCTAssertNotEqual(second, third)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "events", "publish", "relative/session-change",
        ]))
    }

    func testManagedTranscriptRegistryUsesOnlyUsableInRootMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-session-registry-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let sessionsRoot = stateRoot
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let sessionName = "detach-codex-managed"
        let sessionRoot = sessionsRoot.appendingPathComponent(
            sessionName, isDirectory: true)
        let transcriptRoot = root.appendingPathComponent(
            "provider/sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: transcriptRoot, withIntermediateDirectories: true)
        let transcript = transcriptRoot.appendingPathComponent("managed.jsonl")
        try Data().write(to: transcript)
        let metadata = try SessionMetadataDocument.create(changes: [
            .init(key: "schema", value: .integer(1)),
            .init(key: "session_name", value: .string(sessionName)),
            .init(key: "project_dir", value: .string("/private/tmp/project")),
            .init(key: "transcript_path", value: .string(transcript.path)),
        ])
        try metadata.write(to: sessionRoot.appendingPathComponent("meta.json"))

        let canonicalTranscriptRoot = SessionEventWatchConfiguration
            .canonicalPath(transcriptRoot.path)
        let canonicalTranscript = SessionEventWatchConfiguration
            .canonicalPath(transcript.path)
        let snapshots = try DetachStateCommand.metadataSnapshots(
            at: sessionsRoot.path)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNotNil(snapshots.first?.1)
        XCTAssertEqual(
            URL(fileURLWithPath: canonicalTranscript)
                .deletingLastPathComponent().path,
            canonicalTranscriptRoot)
        XCTAssertEqual(
            DetachStateCommand.managedTranscriptPaths(
                atStateRoot: stateRoot.path,
                allowedRoots: [canonicalTranscriptRoot]),
            [canonicalTranscript])
        XCTAssertTrue(DetachStateCommand.managedTranscriptPaths(
            atStateRoot: stateRoot.path,
            allowedRoots: [root.appendingPathComponent("other").path]
        ).isEmpty)
    }

    func testParentMonitorObservesProcessExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let exited = expectation(description: "parent exit")
        let monitor = SessionEventParentMonitor(
            processID: process.processIdentifier,
            queue: DispatchQueue(label: "session-event-parent-test"),
            onExit: { exited.fulfill() })
        monitor.start()
        process.terminate()

        wait(for: [exited], timeout: 1)
        withExtendedLifetime(monitor) {}
    }

    private func classify(
        paths: [String],
        flags: [UInt32] = [0]
    ) -> SessionFileEventClassification {
        SessionFileEventClassifier.classify(
            SessionFileEventBatch(paths: paths, flags: flags),
            configuration: configuration,
            managedTranscriptPaths: managedTranscriptPaths)
    }
}
