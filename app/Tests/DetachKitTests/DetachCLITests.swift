import XCTest
@testable import DetachKit

final class DetachCLITests: XCTestCase {
    func fixture(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-detach")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testCapturesStdoutAndExitCode() async throws {
        let cli = ProcessDetachCLI(executable: try fixture(#"printf '%s\n' "$@"; echo err >&2; exit 3"#))
        let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "list\n--json\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let cli = ProcessDetachCLI(executable: try fixture("dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\\0' 'x'"))
        let result = try await cli.run(arguments: [], timeout: 10)
        XCTAssertEqual(result.stdout.count, 512 * 1024)
    }

    func testTimeoutTerminatesProcess() async throws {
        let cli = ProcessDetachCLI(executable: try fixture("sleep 30"))
        let start = Date()
        let result = try await cli.run(arguments: [], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingBinaryThrows() async {
        let cli = ProcessDetachCLI(executable: URL(fileURLWithPath: "/nonexistent/detach"))
        do {
            _ = try await cli.run(arguments: [], timeout: 1)
            XCTFail("expected throw")
        } catch {}
    }
}
