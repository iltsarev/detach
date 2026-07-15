import Darwin
import Foundation
import XCTest
@testable import DetachApp

final class PowerHelperHandoffStoreTests: XCTestCase {
    func testRoundTripsFsyncedTransactionAndClearsIt() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transaction = PowerHelperHandoffTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            targetDigest: "digest-current",
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001",
            lifetimeBarrierExpected: true)

        try fixture.store.save(transaction)

        XCTAssertEqual(try fixture.store.load(), transaction)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.fileURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)

        try fixture.store.clear()

        XCTAssertNil(try fixture.store.load())
    }

    func testRejectsSymlinkJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL, withDestinationURL: target)

        XCTAssertThrowsError(try fixture.store.load())
    }

    func testRejectsInvalidTransactionBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let invalid = PowerHelperHandoffTransaction(
            phase: .registering,
            goal: .install,
            targetDigest: nil,
            bootSessionIdentifier:
                "00000000-0000-0000-0000-000000000001")

        XCTAssertThrowsError(try fixture.store.save(invalid))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.fileURL.path))
    }

    func testExclusiveTransactionLockRejectsOverlappingStoreUser() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let otherStore = FilePowerHelperHandoffStore(
            fileURL: fixture.fileURL,
            expectedOwner: geteuid())
        var firstLock: (any PowerHelperHandoffLocking)? = try fixture.store
            .acquireTransactionLock()

        XCTAssertThrowsError(try otherStore.acquireTransactionLock()) { error in
            guard case PowerHelperHandoffStoreError.transactionBusy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        withExtendedLifetime(firstLock) {}
        firstLock = nil
        let laterLock = try otherStore.acquireTransactionLock()
        withExtendedLifetime(laterLock) {}
    }

    private func makeFixture() throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PowerHelperHandoffStoreTests.\(UUID().uuidString)",
                isDirectory: true)
        let fileURL = root
            .appendingPathComponent("Detach", isDirectory: true)
            .appendingPathComponent("power-helper-handoff.json")
        return StoreFixture(
            root: root,
            fileURL: fileURL,
            store: FilePowerHelperHandoffStore(
                fileURL: fileURL,
                expectedOwner: geteuid()))
    }
}

private struct StoreFixture {
    let root: URL
    let fileURL: URL
    let store: FilePowerHelperHandoffStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
