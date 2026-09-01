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

    func testClassifierIgnoresNoiseAndRecognizesLifecycleAndTranscripts() {
        XCTAssertEqual(classify(paths: ["/private/tmp/detach-state/heartbeat"]), .ignored)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/detach-state/session-change"]),
            .lifecycle)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/codex/sessions/2026/turn.jsonl"]),
            .transcript)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/claude/projects/p/turn.jsonl"]),
            .transcript)
        XCTAssertEqual(
            classify(paths: ["/private/tmp/claude/projects/p/turn.txt"]),
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
    }

    private func classify(
        paths: [String],
        flags: [UInt32] = [0]
    ) -> SessionFileEventClassification {
        SessionFileEventClassifier.classify(
            SessionFileEventBatch(paths: paths, flags: flags),
            configuration: configuration)
    }
}
