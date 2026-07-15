import Darwin
import DetachKit
import Foundation
import XCTest

final class PowerHelperSystemHandoffLockTests: XCTestCase {
    func testRootCreatesStableFileAndAppLocksAcrossProcesses() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let lock = PowerHelperSystemHandoffLock(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner)

        XCTAssertNil(try lock.acquire())
        try lock.ensureExists()
        do {
            let first = try XCTUnwrap(lock.acquire())
            XCTAssertThrowsError(try lock.acquire()) { error in
                XCTAssertEqual(
                    error as? PowerHelperPlatformError,
                    .systemHandoffLockBusy)
            }
            withExtendedLifetime(first) {}
        }
        XCTAssertNotNil(try lock.acquire())
    }

    func testAppProbeRejectsInsecureSystemLock() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try Data().write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: fixture.fileURL.path)

        XCTAssertThrowsError(try PowerHelperSystemHandoffLock(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner).acquire()) { error in
                XCTAssertEqual(
                    error as? PowerHelperPlatformError,
                    .insecureSystemHandoffLock)
            }
    }

    private func makeFixture() throws -> (
        root: URL,
        fileURL: URL,
        owner: UInt32,
        cleanup: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-power-system-handoff-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent("handoff.lock"),
            UInt32(geteuid()),
            { try? FileManager.default.removeItem(at: root) })
    }
}
