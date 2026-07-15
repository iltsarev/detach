import Darwin
import Foundation
import XCTest
@testable import DetachApp

@_silgen_name("flock")
private func watchdogTestFileLock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

final class WatchdogHandoffStoreTests: XCTestCase {
    func testRoundTripsDurableTransactionAcrossStoreInstances() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let transaction = WatchdogHandoffTransaction(
            phase: .unregisterSubmitted,
            targetDigest: "digest-current")

        try fixture.store.save(transaction)

        let relaunchedStore = FileWatchdogHandoffStore(
            fileURL: fixture.fileURL,
            expectedOwner: geteuid())
        XCTAssertEqual(try relaunchedStore.load(), transaction)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)

        try relaunchedStore.clear()
        XCTAssertNil(try fixture.store.load())
    }

    func testRejectsInvalidRegisteringTransaction() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let invalid = WatchdogHandoffTransaction(
            phase: .registering,
            targetDigest: nil)

        XCTAssertThrowsError(try fixture.store.save(invalid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.fileURL.path))
    }

    func testExclusiveTransactionLockRejectsOverlap() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let otherStore = FileWatchdogHandoffStore(
            fileURL: fixture.fileURL,
            expectedOwner: geteuid())
        var firstLock: (any WatchdogHandoffLocking)? = try fixture.store
            .acquireTransactionLock()

        XCTAssertThrowsError(try otherStore.acquireTransactionLock()) { error in
            guard case WatchdogHandoffStoreError.transactionBusy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        withExtendedLifetime(firstLock) {}
        firstLock = nil
        let laterLock = try otherStore.acquireTransactionLock()
        withExtendedLifetime(laterLock) {}
    }

    func testLifetimeBarrierReportsBusyThenReleased() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let lifetimeURL = fixture.root.appendingPathComponent("lifetime.lock")
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(
            lifetimeURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(watchdogTestFileLock(descriptor, LOCK_EX | LOCK_NB), 0)
        let barrier = WatchdogLifetimeBarrier(
            fileURL: lifetimeURL,
            expectedOwner: geteuid())

        XCTAssertEqual(try barrier.status(), .busy)

        XCTAssertEqual(watchdogTestFileLock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(try barrier.status(), .released)
    }

    func testLifetimePathMatchesWatchdogStateRootPrecedence() {
        let fallbackHome = URL(fileURLWithPath: "/fallback-home", isDirectory: true)

        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["DETACH_POWER_STATE_ROOT": "/power-override"],
                homeDirectory: fallbackHome).path,
            "/power-override/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["DETACH_STATE_ROOT": "/state-override"],
                homeDirectory: fallbackHome).path,
            "/state-override/power/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["XDG_STATE_HOME": "/xdg-state"],
                homeDirectory: fallbackHome).path,
            "/xdg-state/detach/power/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: ["HOME": "/environment-home"],
                homeDirectory: fallbackHome).path,
            "/environment-home/.local/state/detach/power/watchdog-lifetime.lock")
        XCTAssertEqual(
            WatchdogLifetimeBarrier.fileURL(
                environment: [:],
                homeDirectory: fallbackHome).path,
            "/fallback-home/.local/state/detach/power/watchdog-lifetime.lock")
    }

    private func makeFixture() -> WatchdogStoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WatchdogHandoffStoreTests.\(UUID().uuidString)",
                isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Detach", isDirectory: true)
            .appendingPathComponent("watchdog-handoff.json")
        return WatchdogStoreFixture(
            root: root,
            fileURL: fileURL,
            store: FileWatchdogHandoffStore(
                fileURL: fileURL,
                expectedOwner: geteuid()))
    }
}

private struct WatchdogStoreFixture {
    let root: URL
    let fileURL: URL
    let store: FileWatchdogHandoffStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
