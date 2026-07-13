import Foundation
import XCTest
@testable import DetachApp

@MainActor
final class WatchdogServiceTests: XCTestCase {
    func testInitialRegistrationIsAutomatic() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(fixture.defaults.string(forKey: "watchdogDefinitionDigest.v2"), "digest-v2")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending.v2"))
    }

    func testChangedDefinitionRetriesTransientRegisterFailure() async throws {
        let transient = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.failure(transient), .success(.enabled)])
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }
        fixture.defaults.set("digest-v1", forKey: "watchdogDefinitionDigest.v2")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 2)
        XCTAssertEqual(delays, [250_000_000])
        XCTAssertEqual(fixture.defaults.string(forKey: "watchdogDefinitionDigest.v2"), "digest-v2")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending.v2"))
    }

    func testPendingUnavailableStateRecoversInsteadOfDeadEnding() async throws {
        let backend = FakeWatchdogBackend(
            status: .unavailable,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "watchdogDefinitionReconcilePending.v2")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending.v2"))
    }

    func testApprovalStateCompletesRegistrationWithoutRetryLoop() async throws {
        let denied = NSError(
            domain: "SMAppServiceErrorDomain", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Approval required"])
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.approvalRequired(denied)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .requiresApproval)
        XCTAssertEqual(fixture.defaults.string(forKey: "watchdogDefinitionDigest.v2"), "digest-v2")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending.v2"))
    }

    func testNonTransientFailureKeepsRecoveryPending() async {
        let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.failure(failure)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected registration to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }

        XCTAssertTrue(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending.v2"))
        XCTAssertNil(fixture.defaults.string(forKey: "watchdogDefinitionDigest.v2"))
    }

    func testEnabledReplacementUnregistersOldBundledServiceWithoutUserPlist() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            legacyBackend: legacy,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(
            launchctlCalls.first,
            ["bootout", "gui/\(getuid())/dev.tsarev.codex-detached-watchdog"])
    }

    func testApprovalRequiredKeepsOldServiceRunning() async throws {
        let denied = NSError(domain: "SMAppServiceErrorDomain", code: 2)
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.approvalRequired(denied)])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            legacyBackend: legacy,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(legacy.unregisterCalls, 0)
        XCTAssertTrue(launchctlCalls.isEmpty)
    }

    func testLegacyUnregisterFailureDoesNotBreakEnabledReplacement() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        legacy.unregisterError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            legacyBackend: legacy,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(launchctlCalls.count, 1)
    }

    func testDisableUnregistersNewAndOldServices() async throws {
        let backend = FakeWatchdogBackend(status: .enabled, registrations: [])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        let fixture = makeFixture(
            backend: backend,
            legacyBackend: legacy,
            launchctl: { _ in 0 })
        defer { fixture.cleanup() }

        try await fixture.service.disable()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(fixture.service.status, .notRegistered)
    }

    private func makeFixture(
        backend: FakeWatchdogBackend,
        legacyBackend: FakeWatchdogBackend? = nil,
        sleep: @escaping (UInt64) async throws -> Void = { _ in },
        launchctl: @escaping ([String]) -> Int32 = { _ in 0 }
    ) -> Fixture {
        let suite = "WatchdogServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-tests-\(UUID().uuidString)", isDirectory: true)
        let service = WatchdogService(
            backend: backend,
            legacyBackend: legacyBackend,
            defaults: defaults,
            homeDirectory: home,
            digestProvider: { "digest-v2" },
            sleep: sleep,
            launchctl: launchctl)
        return Fixture(service: service, defaults: defaults, suite: suite)
    }
}

@MainActor
private final class FakeWatchdogBackend: WatchdogRegistrationBackend {
    enum Registration {
        case success(WatchdogStatus)
        case approvalRequired(Error)
        case failure(Error)
    }

    var status: WatchdogStatus
    var registrations: [Registration]
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    var unregisterError: Error?

    init(status: WatchdogStatus, registrations: [Registration]) {
        self.status = status
        self.registrations = registrations
    }

    func register() throws {
        registerCalls += 1
        guard !registrations.isEmpty else {
            throw WatchdogServiceError.registrationDidNotComplete
        }
        switch registrations.removeFirst() {
        case .success(let newStatus):
            status = newStatus
        case .approvalRequired(let error):
            status = .requiresApproval
            throw error
        case .failure(let error):
            throw error
        }
    }

    func unregister() async throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

@MainActor
private struct Fixture {
    let service: WatchdogService
    let defaults: UserDefaults
    let suite: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}
