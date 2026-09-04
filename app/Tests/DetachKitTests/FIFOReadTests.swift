import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class FIFOReadTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-fifo-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testStorageRejectsFIFOMetadataWithoutWaitingForAWriter() throws {
        let name = "detach-codex-fifo"
        let providerRoot = root.appendingPathComponent("codex")
        let sessionRoot = providerRoot.appendingPathComponent("sessions/\(name)")
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let fifo = sessionRoot.appendingPathComponent("meta.json")
        let stateRoot = root.path
        let inventory = Data("""
        {"schema":1,"provider":"codex","session_name":"\(name)","name":"fifo","effective_status":"orphaned","cleanup_eligible":false}
        """.utf8)

        try checkWithoutWriter(fifo) {
            let report = try StorageInspector.report(
                stateRoot: stateRoot,
                providerRoots: [.codex: providerRoot.path],
                excludedRoots: [],
                inventory: inventory)
            XCTAssertFalse(report.complete)
            XCTAssertEqual(report.sessions.first?.blockedReason, "invalid_metadata")
            XCTAssertEqual(report.sessions.first?.deletable, false)
        }
    }

    func testMetadataSnapshotsRejectFIFOCheckpointWithoutWaitingForAWriter() throws {
        let sessions = root.appendingPathComponent("sessions")
        let checkpoint = sessions.appendingPathComponent("detach-codex-fifo/checkpoint")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

        try checkWithoutWriter(checkpoint.appendingPathComponent("meta.json")) {
            let result = try DetachStateCommand.run(arguments: [
                "meta", "snapshots", sessions.path,
            ])
            let fields = result.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(fields.prefix(2), ["detach-codex-fifo", "false"])
        }
    }

    func testCachedValidationRejectsFIFOTranscriptWithoutWaitingForAWriter() throws {
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try checkWithoutWriter(transcript) {
            XCTAssertThrowsError(try DetachStateCommand.run(arguments: [
                "jsonl", "validate-cached", "codex", transcript.path, "session-1",
            ])) { error in
                XCTAssertEqual(error as? DetachStateCommandError, .invalidTranscript)
            }
        }
    }

    func testCachedValidationIgnoresFIFOReceiptWithoutWaitingForAWriter() throws {
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try Data(#"{"type":"session_meta","payload":{"id":"session-1"}}"#.utf8)
            .write(to: transcript)
        try checkWithoutWriter(root.appendingPathComponent(".detach-jsonl-validation.json")) {
            XCTAssertNoThrow(try DetachStateCommand.run(arguments: [
                "jsonl", "validate-cached", "codex", transcript.path, "session-1",
            ]))
        }
    }

    func testLifetimeProbeRejectsFIFOWithoutWaitingForAWriter() throws {
        let fifo = root.appendingPathComponent("lifetime.lock")
        let barrier = PowerHelperLifetimeBarrier(fileURL: fifo, expectedOwner: geteuid())
        try checkWithoutWriter(fifo) {
            XCTAssertThrowsError(try barrier.status()) { error in
                XCTAssertEqual(error as? PowerHelperPlatformError, .insecureLifetimeLock)
            }
        }
    }

    func testSystemHandoffProbeRejectsFIFOWithoutWaitingForAWriter() throws {
        let fifo = root.appendingPathComponent("handoff.lock")
        let lock = PowerHelperSystemHandoffLock(fileURL: fifo, expectedOwner: geteuid())
        try checkWithoutWriter(fifo) {
            XCTAssertThrowsError(try lock.acquire()) { error in
                XCTAssertEqual(error as? PowerHelperPlatformError, .insecureSystemHandoffLock)
            }
        }
    }

    /// A regression must fail within a bound and leave no blocked test thread.
    /// The rescue writer opens only after that failure and never supplies data.
    private func checkWithoutWriter(
        _ fifo: URL,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: @escaping @Sendable () throws -> Void
    ) throws {
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, file: file, line: line)
        let completed = DispatchGroup()
        completed.enter()
        DispatchQueue.global().async {
            defer { completed.leave() }
            do { try operation() }
            catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
        }
        let result = completed.wait(timeout: .now() + 1)
        XCTAssertEqual(result, .success, "File validation waited for a FIFO writer", file: file, line: line)
        if result == .timedOut {
            let rescue = open(fifo.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            defer { if rescue >= 0 { close(rescue) } }
            XCTAssertGreaterThanOrEqual(rescue, 0, file: file, line: line)
            XCTAssertEqual(completed.wait(timeout: .now() + 1), .success, file: file, line: line)
        }
    }
}
