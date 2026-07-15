import Darwin
import Foundation
import XCTest
@testable import DetachKit

final class PowerHelperLifetimeBarrierTests: XCTestCase {
    func testDefaultPathIsStableAndRootScoped() {
        XCTAssertEqual(
            PowerHelperLifetimeBarrier.defaultFileURL.path,
            "/var/run/dev.tsarev.detach.power-helper.lock")
    }

    func testHolderCreatesSecureReadableFileAndProbeTracksLifetime() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let barrier = PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner)
        var holder: PowerHelperLifetimeBarrierLease? = try barrier.acquire()

        XCTAssertEqual(try barrier.status(), .busy)
        XCTAssertFalse(try barrier.isReleased())
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path)
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(
            permissions.intValue & 0o777,
            0o644)
        XCTAssertEqual(
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            fixture.owner)
        let descriptorFlags = Darwin.fcntl(
            try XCTUnwrap(holder).fileDescriptor, F_GETFD)
        XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)

        holder = nil
        XCTAssertEqual(try barrier.status(), .released)
        XCTAssertTrue(try barrier.isReleased())
    }

    func testMissingFileIsDistinctAndProbeDoesNotCreateIt() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let barrier = PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner)

        XCTAssertEqual(try barrier.status(), .missing)
        XCTAssertFalse(try barrier.isReleased())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.fileURL.path))
    }

    func testSecondHolderFailsWhileFirstProcessLifetimeLockIsHeld() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let barrier = PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner)
        let holder = try barrier.acquire()

        XCTAssertThrowsError(try barrier.acquire()) { error in
            XCTAssertEqual(
                error as? PowerHelperPlatformError,
                .lifetimeLockBusy)
        }
        withExtendedLifetime(holder) {}
    }

    func testProbeRejectsSymlinkWrongOwnerModeAndMultipleLinks() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner).status())

        try FileManager.default.removeItem(at: fixture.fileURL)
        try Data().write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: fixture.fileURL.path)
        XCTAssertThrowsError(try PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner).status())

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.fileURL.path)
        XCTAssertThrowsError(try PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner &+ 1).status())

        let secondLink = fixture.root.appendingPathComponent("second-link")
        try FileManager.default.linkItem(
            at: fixture.fileURL, to: secondLink)
        XCTAssertThrowsError(try PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner).status())
    }

    func testHolderRejectsPreexistingSymlinkAndInsecureMode() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("holder-target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL, withDestinationURL: target)
        let barrier = PowerHelperLifetimeBarrier(
            fileURL: fixture.fileURL,
            expectedOwner: fixture.owner)

        XCTAssertThrowsError(try barrier.acquire())

        try FileManager.default.removeItem(at: fixture.fileURL)
        try Data().write(to: fixture.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: fixture.fileURL.path)
        XCTAssertThrowsError(try barrier.acquire())
    }

    private func makeFixture() throws -> (
        root: URL,
        fileURL: URL,
        owner: UInt32,
        cleanup: () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-power-lifetime-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent("power-helper.lock"),
            UInt32(geteuid()),
            { try? FileManager.default.removeItem(at: root) })
    }
}
