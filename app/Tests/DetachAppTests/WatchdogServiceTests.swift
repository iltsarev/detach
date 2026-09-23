import Foundation
import ServiceManagement
import XCTest
@testable import DetachApp

@MainActor
final class WatchdogServiceTests: XCTestCase {
    func testServiceErrorsHaveActionableDescriptions() {
        XCTAssertEqual(
            WatchdogServiceError.bundledDefinitionMissing.errorDescription,
            "The bundled watchdog definition is missing or incomplete.")
        XCTAssertEqual(
            WatchdogServiceError.releaseSignatureRequired.errorDescription,
            "Only a signed Detach release can update the background monitor.")
        XCTAssertEqual(
            WatchdogServiceError.registrationDidNotComplete.errorDescription,
            "macOS did not finish registering the watchdog.")
        XCTAssertEqual(
            WatchdogServiceError.unregistrationBarrierDidNotComplete.errorDescription,
            "macOS did not finish stopping the previous watchdog.")
    }

    func testMissingBundledDefinitionFailsBeforeRegistration() async {
        let backend = FakeWatchdogBackend(
            status: .notRegistered, registrations: [])
        let fixture = makeFixture(backend: backend, digestProvider: { nil })
        defer { fixture.cleanup() }

        do {
            try await fixture.service.enable()
            XCTFail("Expected missing definition to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The bundled watchdog definition is missing or incomplete.")
        }

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

    func testAdHocBuildCannotMutateSharedWatchdogRegistration() async {
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            serviceMutationAllowed: { false })
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected release-signature admission failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Only a signed Detach release can update the background monitor.")
        }
        do {
            try await fixture.service.disable()
            XCTFail("Expected release-signature admission failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Only a signed Detach release can update the background monitor.")
        }

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertNil(fixture.handoffStore.transaction)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testEnableFailsAfterBoundedUnconfirmedRegistrationRetries() async {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: Array(
                repeating: .success(.notRegistered), count: 5))
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend, sleep: { delays.append($0) })
        defer { fixture.cleanup() }

        do {
            try await fixture.service.enable()
            XCTFail("Expected unconfirmed registration to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "macOS did not finish registering the watchdog.")
        }

        XCTAssertEqual(backend.registerCalls, 5)
        XCTAssertEqual(
            delays, [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000])
    }

    func testDisableUnavailableRegistrationClearsStaleDefinitionState() async throws {
        let backend = FakeWatchdogBackend(
            status: .unavailable, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "stale", forKey: "powerWatchdogDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerWatchdogDefinitionReconcilePending")

        try await fixture.service.disable()

        XCTAssertNil(fixture.defaults.string(
            forKey: "powerWatchdogDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

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
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .busy })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
    }

    func testMatchingEnabledRegistrationWithoutLiveProcessReregisters() async throws {
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .released },
            legacyWatchdogIsRunning: { false })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerWatchdogDefinitionReconcilePending"))
    }

    func testEnabledRegistrationWaitsForItsLifetimeHolderBeforeRepair() async throws {
        // Login starts the app and the watchdog together. A record whose lock
        // is not yet held is only stale if it stays unheld after the grace.
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [])
        var barrierStates: [WatchdogLifetimeBarrierStatus] = [.missing, .busy]
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { barrierStates.removeFirst() },
            legacyWatchdogIsRunning: { false },
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(delays, [WatchdogService.staleRegistrationGraceNanoseconds])
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertNil(fixture.handoffStore.transaction)
        XCTAssertTrue(barrierStates.isEmpty)
    }

    func testMatchingLegacyRegistrationWithLiveProcessNoOps() async throws {
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [])
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .missing },
            legacyWatchdogIsRunning: { true })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerWatchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertNil(fixture.handoffStore.transaction)
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
                targetDigest: "digest-current",
                bootSessionIdentifier: Self.currentBoot))
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

    func testReplayAcceptsAbsentRecordRejectionAfterLifetimeRelease() async throws {
        // macOS 26 reports an absent BTM record as EPERM in the SMAppService
        // domain instead of kSMErrorJobNotFound. The replay must still cross
        // the lifetime barrier before it registers.
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(Self.absentRecordRejection)])
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
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertTrue(barriers.isEmpty)
        XCTAssertNil(store.transaction)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
    }

    func testAbsentRecordRejectionWithLiveRecordRemainsFailClosed() async {
        // BTM also answers EPERM for mutations it forbids by policy. A record
        // that BTM still reports cannot be treated as already removed.
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(Self.absentRecordRejection)])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected replay to remain fail-closed")
        } catch {
            XCTAssertEqual((error as NSError).domain, "SMAppServiceErrorDomain")
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
    }

    func testLegacyJournalRecordsBootBeforeReplayAndCompletesAfterRestart() async throws {
        // A journal written before the boot field can stay stuck when
        // unregister fails with an unclassified error. The replay records the
        // boot first, so a restart provides the release proof.
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current"))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(Self.unclassifiedRejection)])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected an unclassified error to remain fail-closed")
        } catch {
            XCTAssertEqual((error as NSError).code, 22)
        }
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
        XCTAssertEqual(
            store.transaction?.bootSessionIdentifier, Self.currentBoot)

        let restarted = makeService(
            backend: backend,
            defaults: fixture.defaults,
            handoffStore: store,
            bootSessionProvider: { Self.nextBoot })
        try await restarted.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertNil(store.transaction)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerWatchdogDefinitionDigest"),
            "digest-current")
    }

    func testChangedBootWithLiveRecordStillReplaysUnregister() async throws {
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current",
                bootSessionIdentifier: Self.currentBoot))
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.success(.enabled)],
            unregistrations: [.success])
        let fixture = makeFixture(
            backend: backend,
            handoffStore: store,
            bootSessionProvider: { Self.nextBoot })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertNil(store.transaction)
    }

    func testSameBootDoesNotTreatNotRegisteredStatusAsCompletion() async {
        let store = MemoryWatchdogHandoffStore(
            transaction: WatchdogHandoffTransaction(
                phase: .unregisterSubmitted,
                targetDigest: "digest-current",
                bootSessionIdentifier: Self.currentBoot))
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregistrations: [.failure(Self.unclassifiedRejection)])
        let fixture = makeFixture(backend: backend, handoffStore: store)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected the same boot to require a completion barrier")
        } catch {
            XCTAssertEqual((error as NSError).code, 22)
        }
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(store.transaction?.phase, .unregisterSubmitted)
    }

    func testJournalRejectsNonCanonicalBootIdentifier() {
        XCTAssertFalse(WatchdogHandoffTransaction(
            phase: .unregisterSubmitted,
            targetDigest: nil,
            bootSessionIdentifier: "not-a-uuid").isValid)
        XCTAssertFalse(WatchdogHandoffTransaction(
            phase: .unregisterSubmitted,
            targetDigest: nil,
            bootSessionIdentifier: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
            .isValid)
    }

    func testJournalWithoutBootFieldStillDecodes() throws {
        let data = Data(
            #"{"phase":"unregisterSubmitted","schema":1,"targetDigest":"d"}"#
                .utf8)
        let transaction = try JSONDecoder().decode(
            WatchdogHandoffTransaction.self, from: data)
        XCTAssertTrue(transaction.isValid)
        XCTAssertNil(transaction.bootSessionIdentifier)
    }

    fileprivate static let currentBoot = "11111111-1111-4111-8111-111111111111"
    private static let nextBoot = "22222222-2222-4222-8222-222222222222"

    private static let unclassifiedRejection = NSError(
        domain: "SMAppServiceErrorDomain", code: Int(EINVAL))

    private static let absentRecordRejection = NSError(
        domain: "SMAppServiceErrorDomain", code: Int(EPERM),
        userInfo: [NSLocalizedFailureReasonErrorKey: "Operation not permitted"])

    private func makeFixture(
        backend: FakeWatchdogBackend,
        handoffStore: MemoryWatchdogHandoffStore =
            MemoryWatchdogHandoffStore(),
        lifetimeBarrierStatus: @escaping () throws
            -> WatchdogLifetimeBarrierStatus = { .released },
        legacyWatchdogIsRunning: @escaping () throws -> Bool = { false },
        serviceMutationAllowed: @escaping () -> Bool = { true },
        digestProvider: @escaping () -> String? = { "digest-current" },
        bootSessionProvider: @escaping () throws -> String = {
            WatchdogServiceTests.currentBoot
        },
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
            serviceMutationAllowed: serviceMutationAllowed,
            digestProvider: digestProvider,
            bootSessionProvider: bootSessionProvider,
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
        serviceMutationAllowed: @escaping () -> Bool = { true },
        digestProvider: @escaping () -> String? = { "digest-current" },
        bootSessionProvider: @escaping () throws -> String = {
            WatchdogServiceTests.currentBoot
        },
        sleep: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> WatchdogService {
        WatchdogService(
            backend: backend,
            defaults: defaults,
            handoffStore: handoffStore,
            digestProvider: digestProvider,
            lifetimeBarrierStatus: lifetimeBarrierStatus,
            legacyWatchdogIsRunning: legacyWatchdogIsRunning,
            serviceMutationAllowed: serviceMutationAllowed,
            bootSessionProvider: bootSessionProvider,
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
