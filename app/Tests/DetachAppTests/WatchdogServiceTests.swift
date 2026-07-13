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
        XCTAssertEqual(
            fixture.defaults.string(forKey: "watchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
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
        fixture.defaults.set("digest-previous", forKey: "watchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 2)
        XCTAssertEqual(delays, [250_000_000])
        XCTAssertEqual(
            fixture.defaults.string(forKey: "watchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    func testPendingUnavailableStateRecoversInsteadOfDeadEnding() async throws {
        let backend = FakeWatchdogBackend(
            status: .unavailable,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "watchdogDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
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
        XCTAssertEqual(
            fixture.defaults.string(forKey: "watchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
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

        XCTAssertTrue(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
        XCTAssertNil(fixture.defaults.string(forKey: "watchdogDefinitionDigest"))
    }

    func testDisableUnregistersServiceAndClearsDefinitionState() async throws {
        let backend = FakeWatchdogBackend(status: .enabled, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set("digest-current", forKey: "watchdogDefinitionDigest")
        fixture.defaults.set(true, forKey: "watchdogDefinitionReconcilePending")

        try await fixture.service.disable()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(fixture.service.status, .notRegistered)
        XCTAssertNil(fixture.defaults.string(forKey: "watchdogDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    private func makeFixture(
        backend: FakeWatchdogBackend,
        sleep: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> Fixture {
        let suite = "WatchdogServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = WatchdogService(
            backend: backend,
            defaults: defaults,
            digestProvider: { "digest-current" },
            sleep: sleep)
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
