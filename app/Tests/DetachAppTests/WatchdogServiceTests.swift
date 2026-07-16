import Foundation
import ServiceManagement
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
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testProductionRegistrationIgnoresPreReleaseDefinitionState() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "pre-release-digest", forKey: "watchdogDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "watchdogDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testForcedReplacementRestartsMatchingEnabledRegistration() async throws {
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate(
            forceReplacement: true)

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testMatchingEnabledRegistrationStillNormallyNoOps() async throws {
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
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
        fixture.defaults.set(
            "digest-previous", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 2)
        XCTAssertEqual(delays, [250_000_000])
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testPendingUnavailableStateRecoversInsteadOfDeadEnding() async throws {
        let backend = FakeWatchdogBackend(
            status: .unavailable,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            true, forKey: "powerWatchdogDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
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
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
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

        XCTAssertTrue(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerWatchdogDefinitionDigest"))
    }

    func testDisableUnregistersServiceAndClearsDefinitionState() async throws {
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [],
            unregistrations: [.success])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerWatchdogDefinitionReconcilePending")

        try await fixture.service.disable()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(fixture.service.status, .notRegistered)
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerWatchdogDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testRelaunchAfterRegisterSuccessFinishesJournalWithoutReregistering() async throws {
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .registering,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            true, forKey: "powerWatchdogDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertNil(store.transaction)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testChangedTargetReplaysRegisteringPhaseThroughUnregister() async throws {
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .registering,
                targetDigest: "digest-previous"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.success])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            true, forKey: "powerWatchdogDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertNil(store.transaction)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
    }

    func testDisableCompletesUnfinishedUnregisterWithoutRegistering() async throws {
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .registering,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.suspended])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerWatchdogDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerWatchdogDefinitionReconcilePending")

        let removal = Task { try await fixture.service.disable() }
        await waitUntil { backend.unregisterCalls == 1 }

        XCTAssertNil(store.transaction?.targetDigest)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
        XCTAssertEqual(backend.registerCalls, 0)

        backend.finishUnregistration()
        try await removal.value

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertNil(store.transaction)
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerWatchdogDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testRelaunchReplaysLostUnregisterCallbackBeforeRegistering() async throws {
        let store = MemoryWatchdogHandoffStore()
        let suite = "WatchdogServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "digest-previous", forKey: "powerWatchdogDefinitionDigest")

        let oldBackend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [],
            unregistrations: [.suspended])
        let oldService = makeService(
            backend: oldBackend,
            defaults: defaults,
            handoffStore: store)
        let interrupted = Task {
            try await oldService.reconcileAfterAppUpdate()
        }
        await waitUntil { oldBackend.unregisterCalls == 1 }

        XCTAssertEqual(
            store.transaction,
            WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        XCTAssertEqual(oldBackend.registerCalls, 0)

        // The production process would disappear here and lose its callback.
        // Releasing the suspended test task leaves the same durable phase.
        oldBackend.finishUnregistration(
            throwing: CancellationError())
        do {
            try await interrupted.value
            XCTFail("Expected the interrupted handoff to fail")
        } catch is CancellationError {
            // Expected.
        }

        let relaunchedBackend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.suspended])
        let relaunchedService = makeService(
            backend: relaunchedBackend,
            defaults: defaults,
            handoffStore: store)
        let replay = Task {
            try await relaunchedService.reconcileAfterAppUpdate()
        }
        await waitUntil { relaunchedBackend.unregisterCalls == 1 }

        XCTAssertEqual(relaunchedBackend.registerCalls, 0)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)

        relaunchedBackend.finishUnregistration()
        try await replay.value

        XCTAssertEqual(relaunchedBackend.registerCalls, 1)
        XCTAssertNil(store.transaction)
        XCTAssertEqual(
            defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
    }

    func testReplayAcceptsOnlyExactAlreadyUnregisteredError() async throws {
        let alreadyAbsent = NSError(
            domain: "SMAppServiceErrorDomain",
            code: Int(kSMErrorJobNotFound))
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(alreadyAbsent)])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertNil(store.transaction)
    }

    func testAlreadyUnregisteredReplayWaitsForLifetimeRelease() async throws {
        let alreadyAbsent = NSError(
            domain: "SMAppServiceErrorDomain",
            code: Int(kSMErrorJobNotFound))
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(alreadyAbsent)])
        var barriers: [WatchdogLifetimeBarrierStatus] = [.busy, .released]
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            handoffStore: store,
            lifetimeBarrierStatus: { barriers.removeFirst() },
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(delays, [1_000_000_000])
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertTrue(barriers.isEmpty)
    }

    func testAlreadyUnregisteredReplayFailsClosedWhileLifetimeBusy() async {
        let alreadyAbsent = NSError(
            domain: "SMAppServiceErrorDomain",
            code: Int(kSMErrorJobNotFound))
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(alreadyAbsent)])
        var barrierProbes = 0
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            handoffStore: store,
            lifetimeBarrierStatus: {
                barrierProbes += 1
                return .busy
            },
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected the lifetime barrier to time out")
        } catch let error as WatchdogServiceError {
            guard case .unregistrationBarrierDidNotComplete = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(barrierProbes, 31)
        XCTAssertEqual(delays.count, 30)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
    }

    func testLegacyReplayRequiresStableAbsenceWithoutLifetimeMarker() async throws {
        let alreadyAbsent = NSError(
            domain: "SMAppServiceErrorDomain",
            code: Int(kSMErrorJobNotFound))
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(alreadyAbsent)])
        var processStates = [true, false, false, false]
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            handoffStore: store,
            lifetimeBarrierStatus: { .missing },
            legacyWatchdogIsRunning: { processStates.removeFirst() },
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertTrue(processStates.isEmpty)
    }

    func testReplayDoesNotTreatStatusOrWrongErrorDomainAsCompletion() async {
        let lookalike = NSError(
            domain: NSCocoaErrorDomain,
            code: Int(kSMErrorJobNotFound))
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(lookalike)])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected replay to remain fail-closed")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
    }

    func testReplayDoesNotTreatOperationInProgressAsJobAbsence() async {
        let inProgress = NSError(
            domain: "SMAppServiceErrorDomain",
            code: 1)
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(inProgress)])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected replay to remain fail-closed")
        } catch {
            XCTAssertEqual((error as NSError).domain, "SMAppServiceErrorDomain")
            XCTAssertEqual((error as NSError).code, 1)
        }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
    }

    private func makeFixture(
        backend: FakeWatchdogBackend,
        handoffStore: MemoryWatchdogHandoffStore =
            MemoryWatchdogHandoffStore(),
        lifetimeBarrierStatus: @escaping () throws
            -> WatchdogLifetimeBarrierStatus = { .released },
        legacyWatchdogIsRunning: @escaping () throws -> Bool = { false },
        sleep: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> Fixture {
        let suite = "WatchdogServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let service = makeService(
            backend: backend,
            defaults: defaults,
            handoffStore: handoffStore,
            lifetimeBarrierStatus: lifetimeBarrierStatus,
            legacyWatchdogIsRunning: legacyWatchdogIsRunning,
            sleep: sleep)
        return Fixture(
            service: service,
            defaults: defaults,
            suite: suite,
            handoffStore: handoffStore)
    }

    private func makeService(
        backend: FakeWatchdogBackend,
        defaults: UserDefaults,
        handoffStore: MemoryWatchdogHandoffStore,
        lifetimeBarrierStatus: @escaping () throws
            -> WatchdogLifetimeBarrierStatus = { .released },
        legacyWatchdogIsRunning: @escaping () throws -> Bool = { false },
        sleep: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> WatchdogService {
        WatchdogService(
            backend: backend,
            defaults: defaults,
            handoffStore: handoffStore,
            digestProvider: { "digest-current" },
            lifetimeBarrierStatus: lifetimeBarrierStatus,
            legacyWatchdogIsRunning: legacyWatchdogIsRunning,
            sleep: sleep)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class FakeWatchdogBackend: WatchdogRegistrationBackend {
    enum Registration {
        case success(WatchdogStatus)
        case approvalRequired(Error)
        case failure(Error)
    }

    enum Unregistration {
        case success
        case failure(Error)
        case suspended
    }

    var status: WatchdogStatus
    var registrations: [Registration]
    var unregistrations: [Unregistration]
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private var pendingUnregistration:
        CheckedContinuation<Void, Error>?

    init(
        status: WatchdogStatus,
        registrations: [Registration],
        unregistrations: [Unregistration] = [.success]
    ) {
        self.status = status
        self.registrations = registrations
        self.unregistrations = unregistrations
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
        let unregistration = unregistrations.isEmpty
            ? .success
            : unregistrations.removeFirst()
        switch unregistration {
        case .success:
            status = .notRegistered
        case .failure(let error):
            throw error
        case .suspended:
            status = .notRegistered
            try await withCheckedThrowingContinuation {
                pendingUnregistration = $0
            }
        }
    }

    func finishUnregistration(throwing error: Error? = nil) {
        let continuation = pendingUnregistration
        pendingUnregistration = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

private final class MemoryWatchdogHandoffStore: WatchdogHandoffStoring {
    var transaction: WatchdogHandoffTransaction?

    init(transaction: WatchdogHandoffTransaction? = nil) {
        self.transaction = transaction
    }

    func acquireTransactionLock() throws -> any WatchdogHandoffLocking {
        MemoryWatchdogHandoffLock()
    }

    func load() throws -> WatchdogHandoffTransaction? { transaction }

    func save(_ transaction: WatchdogHandoffTransaction) throws {
        self.transaction = transaction
    }

    func clear() throws {
        transaction = nil
    }
}

private final class MemoryWatchdogHandoffLock: WatchdogHandoffLocking {}

@MainActor
private struct Fixture {
    let service: WatchdogService
    let defaults: UserDefaults
    let suite: String
    let handoffStore: MemoryWatchdogHandoffStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}
