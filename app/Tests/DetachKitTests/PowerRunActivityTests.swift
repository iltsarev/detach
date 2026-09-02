import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class PowerRunActivityTests: XCTestCase {
    private final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting = false

        func markWaiting() {
            lock.lock()
            waiting = true
            lock.unlock()
        }

        func followsWaiting() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return waiting
        }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false

        func arm() {
            lock.lock()
            set = true
            lock.unlock()
        }

        var isArmed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return set
        }
    }

    func testReaderPermitsSleepOnlyForExactOwnedRegularWaitingRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let symlink = directory.appendingPathComponent("activity-link")
        let reader = FilePowerRunActivityReader()

        XCTAssertEqual(reader.state(atPath: activity.path), .working)
        try Data("waiting\n".utf8).write(to: activity)
        XCTAssertEqual(reader.state(atPath: activity.path), .waiting)

        for malformed in ["waiting", "waiting\nextra", "idle\n", "\n"] {
            try Data(malformed.utf8).write(to: activity)
            XCTAssertEqual(reader.state(atPath: activity.path), .working)
        }

        try Data("waiting\n".utf8).write(to: activity)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: activity)
        XCTAssertEqual(reader.state(atPath: symlink.path), .working)
    }

    func testWatcherReacquiresOnTranscriptWriteWithoutActivityPolling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let activitySource = directory.appendingPathComponent("activity-source")
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data("working\n".utf8).write(to: activity)
        try Data("initial\n".utf8).write(to: transcript)
        var information = stat()
        XCTAssertEqual(Darwin.lstat(transcript.path, &information), 0)
        let signature = "\(information.st_ino):\(information.st_mtimespec.tv_sec):\(information.st_size)"
        try Data("\(signature)\n\(transcript.path)".utf8).write(
            to: activitySource)
        let observedWaiting = DispatchSemaphore(value: 0)
        let observedWorking = DispatchSemaphore(value: 0)
        let watcher = FilePowerRunActivityWatcher()
        let observation = ObservationBox()

        let result = try watcher.run(
            activityFile: activity.path,
            activitySourceFile: activitySource.path,
            onStateChange: { state in
                if state == .waiting {
                    observation.markWaiting()
                    observedWaiting.signal()
                } else if observation.followsWaiting() {
                    observedWorking.signal()
                }
            },
            operation: {
                let handle = try FileHandle(forWritingTo: activity)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("waiting\n".utf8))
                try handle.synchronize()
                try handle.close()
                XCTAssertEqual(
                    observedWaiting.wait(timeout: .now() + 2),
                    .success)
                let transcriptHandle = try FileHandle(forWritingTo: transcript)
                try transcriptHandle.seekToEnd()
                try transcriptHandle.write(contentsOf: Data("next turn\n".utf8))
                try transcriptHandle.synchronize()
                try transcriptHandle.close()
                XCTAssertEqual(
                    observedWorking.wait(timeout: .now() + 2),
                    .success)
                return ChildCommandResult(exitCode: 17)
            })

        XCTAssertEqual(result.exitCode, 17)
    }

    func testStaleTranscriptEventDoesNotConsumeReplacementWatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-box-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data("initial\n".utf8).write(to: transcript)
        let queue = DispatchQueue(
            label: "dev.tsarev.detach.test.power-activity-box")

        func makeSource() -> (any DispatchSourceFileSystemObject)? {
            let descriptor = Darwin.open(
                transcript.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write],
                queue: queue)
            source.setCancelHandler { Darwin.close(descriptor) }
            return source
        }

        guard let stale = makeSource(), let current = makeSource() else {
            XCTFail("could not open transcript descriptors")
            return
        }
        let box = PowerRunActivitySourceWatchBox()
        box.source = current
        box.waiting = true

        // An event from a cancelled previous generation must not consume
        // the replacement watch.
        XCTAssertFalse(box.consumeEvent(from: stale))
        XCTAssertTrue(box.waiting)
        XCTAssertTrue(box.source === current)

        // The current generation consumes its own event exactly once.
        XCTAssertTrue(box.consumeEvent(from: current))
        XCTAssertFalse(box.waiting)
        XCTAssertNil(box.source)
        XCTAssertFalse(box.consumeEvent(from: current))

        stale.cancel()
        current.cancel()
        stale.resume()
        current.resume()
        queue.sync {}
    }

    func testReplacementWatchSurvivesQueuedTranscriptEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let activitySource = directory.appendingPathComponent("activity-source")
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data("waiting\n".utf8).write(to: activity)
        try Data("initial\n".utf8).write(to: transcript)

        @Sendable func writeHandoff() throws {
            var information = stat()
            XCTAssertEqual(Darwin.lstat(transcript.path, &information), 0)
            let signature = "\(information.st_ino):\(information.st_mtimespec.tv_sec):\(information.st_size)"
            try Data("\(signature)\n\(transcript.path)".utf8).write(
                to: activitySource)
        }

        // A same-size in-place rewrite fires a transcript event while the
        // recorded inode/mtime-second/size snapshot can still match.
        @Sendable func overwriteTranscript() throws {
            let handle = try FileHandle(forWritingTo: transcript)
            try handle.write(contentsOf: Data("initial\n".utf8))
            try handle.synchronize()
            try handle.close()
        }

        try writeHandoff()

        let queue = DispatchQueue(
            label: "dev.tsarev.detach.test.power-activity")
        let watcher = FilePowerRunActivityWatcher(queue: queue)
        let observedWaiting = DispatchSemaphore(value: 0)
        let observedWorking = DispatchSemaphore(value: 0)
        let workingArmed = FlagBox()
        let gate = DispatchSemaphore(value: 0)
        let gateEntered = DispatchSemaphore(value: 0)

        let result = try watcher.run(
            activityFile: activity.path,
            activitySourceFile: activitySource.path,
            onStateChange: { state in
                switch state {
                case .waiting:
                    observedWaiting.signal()
                case .working:
                    if workingArmed.isArmed { observedWorking.signal() }
                }
            },
            operation: {
                // The initial watch reports waiting before the operation.
                XCTAssertEqual(
                    observedWaiting.wait(timeout: .now() + 2),
                    .success)

                // Occupy the watch queue so file events pile up behind the
                // gate instead of running immediately.
                queue.async {
                    gateEntered.signal()
                    _ = gate.wait(timeout: .now() + 10)
                }
                XCTAssertEqual(
                    gateEntered.wait(timeout: .now() + 2),
                    .success)

                // Queue the activity rewrite first so its re-watch runs
                // before the stale transcript event queued after it.
                let activityHandle = try FileHandle(forWritingTo: activity)
                try activityHandle.truncate(atOffset: 0)
                try activityHandle.write(contentsOf: Data("waiting\n".utf8))
                try activityHandle.synchronize()
                try activityHandle.close()
                Thread.sleep(forTimeInterval: 0.1)

                // Queue a transcript event against the current watch, then
                // refresh the handoff so the re-watch accepts the transcript.
                try overwriteTranscript()
                try writeHandoff()
                Thread.sleep(forTimeInterval: 0.1)

                // Release the queue: the re-watch installs a new transcript
                // watch, then the stale event from the cancelled watch runs.
                gate.signal()
                XCTAssertEqual(
                    observedWaiting.wait(timeout: .now() + 2),
                    .success)
                queue.sync {}

                // The stale event must not have cancelled the replacement
                // watch: a new transcript write still reports working.
                workingArmed.arm()
                try overwriteTranscript()
                XCTAssertEqual(
                    observedWorking.wait(timeout: .now() + 2),
                    .success)
                return ChildCommandResult(exitCode: 31)
            })

        XCTAssertEqual(result.exitCode, 31)
    }

    func testWatcherRejectsWaitingWithMismatchedTranscriptSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = directory.appendingPathComponent("activity")
        let activitySource = directory.appendingPathComponent("activity-source")
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data("waiting\n".utf8).write(to: activity)
        try Data("initial\n".utf8).write(to: transcript)
        try Data("0:0:0\n\(transcript.path)".utf8).write(to: activitySource)
        let observedWorking = DispatchSemaphore(value: 0)
        let watcher = FilePowerRunActivityWatcher()

        let result = try watcher.run(
            activityFile: activity.path,
            activitySourceFile: activitySource.path,
            onStateChange: { state in
                if state == .working { observedWorking.signal() }
            },
            operation: {
                XCTAssertEqual(
                    observedWorking.wait(timeout: .now() + 2),
                    .success)
                return ChildCommandResult(exitCode: 23)
            })

        XCTAssertEqual(result.exitCode, 23)
    }
}
