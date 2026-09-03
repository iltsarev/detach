import CoreServices
import Darwin
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

    func testNativeDeliveryDecodesAndForwardsTheTypedBatch() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let queue = DispatchQueue(label: "detach-session-callback-test")
        let watcher = SessionFileEventWatcher(
            configuration: configuration,
            queue: queue,
            output: pipe.fileHandleForWriting)
        let paths = [configuration.signalPath] as CFArray
        var flag: FSEventStreamEventFlags = 0

        let delivery = withUnsafePointer(to: &flag) { flags in
            XCTAssertNil(sessionFSEventsDelivery(
                info: nil,
                count: 1,
                pathsPointer: Unmanaged.passUnretained(paths).toOpaque(),
                flagsPointer: flags))
            return sessionFSEventsDelivery(
                info: Unmanaged.passUnretained(watcher).toOpaque(),
                count: 1,
                pathsPointer: Unmanaged.passUnretained(paths).toOpaque(),
                flagsPointer: flags)
        }
        XCTAssertTrue(delivery?.watcher === watcher)
        XCTAssertEqual(
            delivery?.batch,
            SessionFileEventBatch(paths: [configuration.signalPath], flags: [0]))
        queue.sync {
            if let delivery {
                delivery.watcher.receive(delivery.batch)
            }
        }

        var buffer = Data()
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .changed))
    }

    func testWatcherForwardsTranscriptMonitorChanges() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let queue = DispatchQueue(label: "detach-session-transcript-callback-test")
        let watcher = SessionFileEventWatcher(
            configuration: configuration,
            quietWindow: 10,
            queue: queue,
            output: pipe.fileHandleForWriting)

        queue.sync { watcher.receiveTranscriptChange() }

        var buffer = Data()
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .changed))
    }

    func testTypedPublisherAtomicallyReplacesItsHint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-session-events-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let signal = root.appendingPathComponent("session-change")

        _ = try DetachStateCommand.run(arguments: [
            "events", "publish", root.path,
        ])
        let first = try Data(contentsOf: signal)
        _ = try DetachStateCommand.run(arguments: [
            "events", "publish", root.path,
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
            "events", "publish", root.path + "//",
        ])
        let third = try Data(contentsOf: signal)
        XCTAssertNotEqual(second, third)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "events", "publish", "relative/state",
        ]))

        let unrelated = root.appendingPathComponent("unrelated")
        let sentinel = Data("keep me".utf8)
        try sentinel.write(to: unrelated)
        XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
            "events", "publish", unrelated.path,
        ]))
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
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
            .init(key: "status", value: .string("running")),
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
        let registry = DetachStateCommand.managedTranscriptRegistry(
            sessionsRoots: [sessionsRoot.path],
            allowedRoots: [canonicalTranscriptRoot])
        XCTAssertEqual(registry.all, [canonicalTranscript])
        XCTAssertEqual(registry.live, [canonicalTranscript])
    }

    func testLiveTranscriptVnodeSourceReportsAnAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-session-vnode-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("managed.jsonl")
        try Data().write(to: transcript)

        let changed = expectation(description: "live transcript append")
        changed.assertForOverFulfill = false
        let queue = DispatchQueue(label: "detach-session-vnode-test")
        let monitor = SessionTranscriptFileMonitor(queue: queue) {
            changed.fulfill()
        }
        monitor.update(paths: [transcript.path])

        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("turn\n".utf8))
        try handle.synchronize()

        wait(for: [changed], timeout: 1)
        monitor.stop()
    }

    func testWatcherStreamsReadyLifecycleTranscriptAndResyncEvents() throws {
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "detach-session-watcher-\(UUID().uuidString)",
            isDirectory: true)
        let root = URL(
            fileURLWithPath: SessionEventWatchConfiguration.canonicalPath(
                temporaryRoot.path),
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let sessionsRoot = stateRoot
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let sessionRoot = sessionsRoot.appendingPathComponent(
            "detach-codex-watcher", isDirectory: true)
        let invalidSessionRoot = sessionsRoot.appendingPathComponent(
            "detach-codex-invalid", isDirectory: true)
        let transcriptRoot = root.appendingPathComponent(
            "provider/sessions", isDirectory: true)
        let lateTranscriptRoot = root.appendingPathComponent(
            "provider/late-sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: invalidSessionRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: invalidSessionRoot.appendingPathComponent("meta.json"))
        try FileManager.default.createDirectory(
            at: transcriptRoot, withIntermediateDirectories: true)
        let transcript = transcriptRoot.appendingPathComponent("managed.jsonl")
        try Data().write(to: transcript)
        let canonicalStateRoot = SessionEventWatchConfiguration.canonicalPath(
            stateRoot.path)
        let canonicalSessionsRoot = SessionEventWatchConfiguration.canonicalPath(
            sessionsRoot.path)
        let canonicalTranscriptRoot = SessionEventWatchConfiguration.canonicalPath(
            transcriptRoot.path)
        let canonicalLateTranscriptRoot = SessionEventWatchConfiguration.canonicalPath(
            lateTranscriptRoot.path)
        let canonicalTranscript = SessionEventWatchConfiguration.canonicalPath(
            transcript.path)
        let metadata = try SessionMetadataDocument.create(changes: [
            .init(key: "schema", value: .integer(1)),
            .init(key: "session_name", value: .string("detach-codex-watcher")),
            .init(key: "project_dir", value: .string("/private/tmp/project")),
            .init(key: "status", value: .string("running")),
            .init(key: "transcript_path", value: .string(canonicalTranscript)),
        ])
        try metadata.write(to: sessionRoot.appendingPathComponent("meta.json"))

        let signalPath = canonicalStateRoot + "/session-change"
        let configuration = SessionEventWatchConfiguration(
            stateRoot: canonicalStateRoot,
            signalPath: signalPath,
            transcriptRoots: [canonicalTranscriptRoot, canonicalLateTranscriptRoot],
            sessionsRoots: [canonicalSessionsRoot])
        let managedTranscript = try XCTUnwrap(
            DetachStateCommand.managedTranscriptRegistry(
                sessionsRoots: [canonicalSessionsRoot],
                allowedRoots: [canonicalTranscriptRoot, canonicalLateTranscriptRoot])
                .all.first)
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let queue = DispatchQueue(label: "detach-session-watcher-test")
        var buffer = Data()
        let watcher = SessionFileEventWatcher(
            configuration: configuration,
            quietWindow: 0.02,
            queue: queue,
            output: pipe.fileHandleForWriting)
        defer { watcher.stop() }

        try watcher.start()
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .ready))

        // The native stream is installed above; feed its typed callback path
        // directly so the assertion does not depend on host FSEvents latency.
        queue.sync {
            watcher.receive(SessionFileEventBatch(
                paths: [signalPath], flags: [0]))
        }
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .changed))

        // Exact transcript writes emit one leading and one bounded trailing
        // hint even when callbacks arrive as a burst.
        queue.sync {
            watcher.receive(SessionFileEventBatch(
                paths: [managedTranscript], flags: [0]))
            watcher.receive(SessionFileEventBatch(
                paths: [managedTranscript], flags: [0]))
        }
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .changed))
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .changed))

        queue.sync {
            watcher.receive(SessionFileEventBatch(
                paths: [canonicalStateRoot],
                flags: [UInt32(kFSEventStreamEventFlagRootChanged)]))
        }
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .resync))

        // A provider root can appear after startup. A lifecycle hint must add
        // it to the native stream without replacing the working state stream.
        try FileManager.default.createDirectory(
            at: lateTranscriptRoot, withIntermediateDirectories: true)
        queue.sync {
            watcher.receive(SessionFileEventBatch(
                paths: [signalPath], flags: [0]))
        }
        XCTAssertEqual(
            try readEvent(from: pipe.fileHandleForReading, buffer: &buffer),
            SessionEvent(event: .changed))
        queue.sync {}

    }

    func testTranscriptMonitorRejectsUnsafeFilesAndRearmsAReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-session-vnode-rearm-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("managed.jsonl")
        try Data().write(to: transcript)

        let first = expectation(description: "replacement observed")
        let second = expectation(description: "replacement rearmed")
        let lock = NSLock()
        nonisolated(unsafe) var deliveryCount = 0
        let queue = DispatchQueue(label: "detach-session-vnode-rearm-test")
        let monitor = SessionTranscriptFileMonitor(queue: queue) {
            let count = lock.withLock {
                deliveryCount += 1
                return deliveryCount
            }
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }
        monitor.update(paths: [
            "relative/transcript.jsonl",
            root.path,
            transcript.path,
        ])
        queue.sync { monitor.update(paths: [transcript.path]) }

        try Data("replacement\n".utf8).write(to: transcript, options: .atomic)
        wait(for: [first], timeout: 1)
        Thread.sleep(forTimeInterval: 0.1)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("append\n".utf8))
        try handle.synchronize()
        try handle.close()

        wait(for: [second], timeout: 1)
        monitor.update(paths: [])
        monitor.stop()
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

    private func readEvent(
        from handle: FileHandle,
        buffer: inout Data,
        timeoutMilliseconds: Int32 = 2_000
    ) throws -> SessionEvent? {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return SessionEventParser.parse(String(decoding: line, as: UTF8.self))
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remaining = Int32(min(
                UInt64(Int32.max),
                (deadline - now + 999_999) / 1_000_000))
            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0)
            let polled = Darwin.poll(&descriptor, 1, remaining)
            if polled < 0, errno == EINTR { continue }
            guard polled > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}
