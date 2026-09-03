import XCTest
@testable import DetachKit

@MainActor
final class SessionSnapshotCacheTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var cache: UserDefaultsSessionSnapshotCache!

    override func setUp() {
        suiteName = "SessionSnapshotCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cache = UserDefaultsSessionSnapshotCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        cache = nil
        defaults = nil
        suiteName = nil
    }

    func testCachePreservesPresentationAndRemovesMutationEvidence() throws {
        var source = session(name: "one")
        source.healthActions = [.attach, .stop]
        source.healthReason = .healthy
        source.reconcileAction = .removeDeadTmux
        source.ownershipProven = true
        source.cleanupEligible = true
        source.workerPID = 100
        source.providerPID = 101
        source.workerHeartbeatAt = Date(timeIntervalSince1970: 100)
        source.heartbeatFresh = true
        source.checkpointFresh = true
        source.powerProtectionState = .protected

        cache.store([source])
        let loaded = try XCTUnwrap(cache.load().first)

        XCTAssertEqual(loaded.id, source.id)
        XCTAssertEqual(loaded.displayTitle, source.displayTitle)
        XCTAssertEqual(loaded.effectiveStatus, .running)
        XCTAssertEqual(loaded.healthActions, [])
        XCTAssertTrue(loaded.availableActions.isEmpty)
        XCTAssertNil(loaded.healthReason)
        XCTAssertEqual(loaded.reconcileAction, SessionReconcileAction.none)
        XCTAssertEqual(loaded.ownershipProven, false)
        XCTAssertEqual(loaded.cleanupEligible, false)
        XCTAssertNil(loaded.workerPID)
        XCTAssertNil(loaded.providerPID)
        XCTAssertNil(loaded.workerHeartbeatAt)
        XCTAssertEqual(loaded.heartbeatFresh, false)
        XCTAssertEqual(loaded.checkpointFresh, false)
        XCTAssertEqual(loaded.powerProtectionState, .unknown)
    }

    func testCacheRejectsCorruptDuplicateAndOversizedDocuments() {
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsSessionSnapshotCache.defaultKey)
        XCTAssertTrue(cache.load().isEmpty)

        defaults.removeObject(forKey: UserDefaultsSessionSnapshotCache.defaultKey)
        let duplicates = Array(repeating: session(name: "duplicate"), count: 2)
        cache.store(duplicates)
        XCTAssertNil(defaults.data(forKey: UserDefaultsSessionSnapshotCache.defaultKey))
        XCTAssertTrue(cache.load().isEmpty)

        defaults.set(
            Data(repeating: 0x20, count: UserDefaultsSessionSnapshotCache.maximumByteCount + 1),
            forKey: UserDefaultsSessionSnapshotCache.defaultKey)
        XCTAssertTrue(cache.load().isEmpty)
    }

    func testCacheWritesOnlyWhenThePresentationChanges() {
        let key = UserDefaultsSessionSnapshotCache.defaultKey
        var source = session(name: "one")
        cache.store([source])
        XCTAssertNotNil(defaults.data(forKey: key))

        // Volatile runtime fields change on nearly every snapshot and are not
        // part of the stored presentation, so they must not rewrite defaults.
        defaults.removeObject(forKey: key)
        source.workerHeartbeatAt = Date(timeIntervalSince1970: 200)
        source.heartbeatFresh = true
        source.powerProtectionState = .protected
        cache.store([source])
        XCTAssertNil(defaults.data(forKey: key))

        source.effectiveStatus = .stopped
        cache.store([source])
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertEqual(cache.load().first?.effectiveStatus, .stopped)
    }

    func testCacheRejectsMoreThanTheBoundedSessionCount() {
        let sessions = (0...UserDefaultsSessionSnapshotCache.maximumSessionCount).map {
            session(name: "session-\($0)")
        }

        cache.store(sessions)

        XCTAssertTrue(cache.load().isEmpty)
    }

    private func session(name: String) -> Session {
        Session(
            schema: 1,
            provider: .codex,
            sessionName: "detach-codex-\(name)",
            name: name,
            displayName: "Session \(name)",
            effectiveStatus: .running,
            metaStatus: "running",
            agentSessionId: "agent-\(name)",
            projectDir: "/tmp/\(name)",
            createdAt: Date(timeIntervalSince1970: 50))
    }
}
