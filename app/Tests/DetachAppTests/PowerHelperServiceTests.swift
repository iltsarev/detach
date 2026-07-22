import Foundation
import ServiceManagement
import XCTest
@testable import DetachApp
import DetachKit

@MainActor
final class PowerHelperServiceTests: XCTestCase {
    func testLifecycleRunnerMapsSuccessfulAndActiveLeasePreparations() async throws {
        let cli = LifecycleCLI(responses: [
            .success(CLIResult(
                exitCode: 0, stdout: "", stderr: "", timedOut: false)),
            .success(CLIResult(
                exitCode: DetachPowerExecutable.temporaryFailureExitCode,
                stdout: "", stderr: "", timedOut: false)),
        ])
        let runner = SystemPowerHelperLifecycleRunner(cli: cli)

        let first = try await runner.prepareForUnregistration()
        let second = try await runner.prepareForUnregistration()
        let calls = await cli.calls()
        XCTAssertEqual(first, .prepared)
        XCTAssertEqual(second, .activeLeases)
        XCTAssertEqual(calls.arguments, [
            ["helper", "prepare-unregistration"],
            ["helper", "prepare-unregistration"],
        ])
        XCTAssertEqual(calls.timeouts, [35, 35])
    }

    func testLifecycleRunnerFormatsTimeoutStderrAndExitFailures() async {
        let cli = LifecycleCLI(responses: [
            .success(CLIResult(
                exitCode: 1, stdout: "", stderr: "ignored", timedOut: true)),
            .success(CLIResult(
                exitCode: 2, stdout: "", stderr: " daemon failed \n",
                timedOut: false)),
            .success(CLIResult(
                exitCode: 3, stdout: "", stderr: "", timedOut: false)),
        ])
        let runner = SystemPowerHelperLifecycleRunner(cli: cli)
        let expected = [
            "power helper lifecycle request timed out",
            "daemon failed",
            "power helper lifecycle request exited with status 3",
        ]

        for message in expected {
            do {
                _ = try await runner.prepareForUnregistration()
                XCTFail("Expected lifecycle failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, message)
            }
        }
    }

    func testLifecycleRunnerCancelsOrSurfacesCancellationFailure() async throws {
        let cli = LifecycleCLI(responses: [
            .success(CLIResult(
                exitCode: 0, stdout: "", stderr: "", timedOut: false)),
            .success(CLIResult(
                exitCode: 4, stdout: "", stderr: "cancel failed",
                timedOut: false)),
        ])
        let runner = SystemPowerHelperLifecycleRunner(cli: cli)

        try await runner.cancelUnregistration()
        do {
            try await runner.cancelUnregistration()
            XCTFail("Expected cancellation failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "cancel failed")
        }
        let calls = await cli.calls()
        XCTAssertEqual(calls.arguments, [
            ["helper", "cancel-unregistration"],
            ["helper", "cancel-unregistration"],
        ])
    }

    func testServiceErrorsHaveActionableDescriptions() {
        let cases: [(PowerHelperServiceError, String)] = [
            (
                .bundledDefinitionMissing,
                "The bundled power helper definition is missing or incomplete."
            ),
            (
                .registrationDidNotComplete,
                "macOS did not finish registering the power helper."
            ),
            (
                .unregistrationBarrierDidNotComplete,
                "macOS has not finished removing the previous power helper."
            ),
            (
                .activeLeasesPreventUnregistration,
                "Stop active Detach sessions before removing the power helper."
            ),
            (
                .notActiveConsoleUser,
                "Switch to this macOS user before updating the power helper."
            ),
            (.lifecycleCommandFailed("lifecycle failed"), "lifecycle failed"),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testMissingBundledDefinitionFailsBeforeRegistration() async {
        let backend = FakePowerHelperBackend(
            status: .notRegistered, registrations: [])
        let fixture = makeFixture(backend: backend, digestProvider: { nil })
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.enable()
        }

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

    func testEnableFailsAfterBoundedUnconfirmedRegistrationRetries() async {
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: Array(
                repeating: .success(.notRegistered), count: 5))
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .missing },
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.enable()
        }

        XCTAssertEqual(backend.registerCalls, 5)
        XCTAssertEqual(
            delays, [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000])
    }

    func testDisableRefusesToRemoveHelperWithActiveLeases() async {
        let backend = FakePowerHelperBackend(
            status: .enabled, registrations: [])
        let lifecycle = FakePowerHelperLifecycle(
            preparations: [.success(.activeLeases)])
        let fixture = makeFixture(backend: backend, lifecycle: lifecycle)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.disable()
        }

        XCTAssertEqual(lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

    func testDisableNotRegisteredHelperClearsStaleDefinitionState() async throws {
        let backend = FakePowerHelperBackend(
            status: .notRegistered, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "stale", forKey: "powerHelperDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerHelperDefinitionReconcilePending")

        try await fixture.service.disable()

        XCTAssertNil(fixture.defaults.string(
            forKey: "powerHelperDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

    func testDisableApprovalStateSubmitsUnregistration() async throws {
        let backend = FakePowerHelperBackend(
            status: .requiresApproval, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.disable()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .removed)
        XCTAssertEqual(fixture.handoffStore.transaction?.goal, .remove)
    }

    func testMatchingApprovedRegistrationRemainsPendingWithoutMutation() async throws {
        let backend = FakePowerHelperBackend(
            status: .requiresApproval, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertTrue(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testInvalidBootSessionFailsBeforeRegistration() async {
        let backend = FakePowerHelperBackend(
            status: .notRegistered, registrations: [])
        let fixture = makeFixture(
            backend: backend,
            bootSessionProvider: { "not-a-boot-session-uuid" })
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

    func testLegacyGateReopenDigestCompletesWithoutReplacingEnabledHelper() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "powerHelperGateReopenPending")
        fixture.defaults.set(
            "digest-current", forKey: "powerHelperGateReopenDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(fixture.lifecycle.prepareCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperGateReopenPending"))
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerHelperGateReopenDigest"))
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testMalformedRegisteringRemovalJournalConvergesToRemoved() async throws {
        let backend = FakePowerHelperBackend(
            status: .notRegistered, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .registering,
            goal: .remove,
            digest: nil,
            lifetimeBarrierExpected: false)

        try await fixture.service.disable()

        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .removed)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
    }

    func testRebootWithEnabledHelperRestartsRemovalFromPreparation() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            bootSessionProvider: {
                "00000000-0000-0000-0000-000000000002"
            })
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testRebootWithApprovalStateRefreshesJournalBeforeUnregister() async throws {
        let backend = FakePowerHelperBackend(
            status: .requiresApproval,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            bootSessionProvider: {
                "00000000-0000-0000-0000-000000000002"
            })
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.prepareCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testSecondOperationIsRejectedWhileUnregisterIsInFlight() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled, registrations: [])
        backend.suspendUnregister = true
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        let firstDisable = Task { try await fixture.service.disable() }
        await waitUntil { backend.unregisterCalls == 1 }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.disable()
        }

        backend.completeSuspendedUnregister()
        try await firstDisable.value
        XCTAssertEqual(backend.unregisterCalls, 1)
    }

    func testUsesBundledPrivilegedDaemonDefinition() {
        XCTAssertEqual(
            PowerHelperService.plistName,
            "dev.tsarev.detach.power-helper.plist")
    }

    func testInitialRegistrationIsAutomatic() async throws {
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .missing })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerHelperDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
    }

    func testChangedDefinitionRetriesTransientRegisterFailure() async throws {
        let transient = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.failure(transient), .success(.enabled)])
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 2)
        XCTAssertEqual(fixture.lifecycle.prepareCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(delays, [250_000_000])
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerHelperDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
    }

    func testApprovalStateIsTruthfullyExposedWithoutRetryLoop() async throws {
        let denied = NSError(
            domain: "SMAppServiceErrorDomain", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Approval required"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.approvalRequired(denied)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .requiresApproval)
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerHelperDefinitionDigest"))
        XCTAssertTrue(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .registering)
        XCTAssertEqual(fixture.handoffStore.transaction?.goal, .install)
    }

    func testUnavailableStateRecoversInsteadOfDeadEnding() async throws {
        let backend = FakePowerHelperBackend(
            status: .unavailable,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            true, forKey: "powerHelperDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
    }

    func testNonTransientFailureKeepsRecoveryPending() async {
        let failure = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError)
        let backend = FakePowerHelperBackend(
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
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerHelperDefinitionDigest"))
    }

    func testDisableUnregistersDaemonAndClearsDefinitionState() async throws {
        let backend = FakePowerHelperBackend(status: .enabled, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerHelperDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerHelperDefinitionReconcilePending")

        try await fixture.service.disable()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(fixture.lifecycle.prepareCalls, 1)
        XCTAssertEqual(fixture.service.status, .notRegistered)
        XCTAssertNil(fixture.defaults.string(
            forKey: "powerHelperDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .removed)
        XCTAssertEqual(fixture.handoffStore.transaction?.goal, .remove)
    }

    func testChangedDefinitionDefersWhileSessionsHoldPowerLeases() async throws {
        let backend = FakePowerHelperBackend(status: .enabled, registrations: [])
        let lifecycle = FakePowerHelperLifecycle(
            preparations: [.success(.activeLeases)])
        let fixture = makeFixture(backend: backend, lifecycle: lifecycle)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerHelperDefinitionDigest"),
            "digest-previous")
        XCTAssertTrue(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperUnregistrationPending"))
        XCTAssertEqual(fixture.service.status, .enabled)
    }

    func testFailedUnregisterKeepsRootGateClosedAndSubmittedPhase() async {
        let failure = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        let backend = FakePowerHelperBackend(
            status: .enabled, registrations: [],
            unregisterError: failure)
        let lifecycle = FakePowerHelperLifecycle()
        let fixture = makeFixture(backend: backend, lifecycle: lifecycle)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(lifecycle.prepareCalls, 1)
        XCTAssertEqual(lifecycle.cancelCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertEqual(
            fixture.handoffStore.transaction?.phase,
            .unregisterSubmitted)
    }

    func testAmbiguousLegacyMarkerPreparesBeforeSafeReplay() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-current", forKey: "powerHelperDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerHelperUnregistrationPending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(fixture.lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperUnregistrationPending"))
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testSubmittedUnregisterWaitsForFreshCompletionBeforeReplacement() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        backend.suspendUnregister = true
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerHelperDefinitionReconcilePending")
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        let reconciliation = Task {
            try await fixture.service.reconcileAfterAppUpdate()
        }
        await waitUntil { backend.unregisterCalls == 1 }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)

        // SMAppService.status can change before the asynchronous unregister
        // callback confirms that the old daemon process was killed. Status is
        // therefore not a safe replacement barrier by itself.
        backend.status = .notRegistered
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)
        XCTAssertEqual(
            fixture.handoffStore.transaction?.phase,
            .unregisterSubmitted)

        backend.completeSuspendedUnregister()
        try await reconciliation.value

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testSubmittedUnregisterErrorWithLiveJobRemainsFailClosed() async {
        let failure = NSError(
            domain: "SMAppServiceErrorDomain", code: 99,
            userInfo: [NSLocalizedDescriptionKey: "operation still pending"])
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)],
            unregisterError: failure)
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)
        XCTAssertEqual(
            fixture.handoffStore.transaction?.phase,
            .unregisterSubmitted)
    }

    func testJobNotFoundWaitsForReleasedLifetimeBarrier() async throws {
        let failure = NSError(
            domain: "SMAppServiceErrorDomain", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "job not found"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregisterError: failure)
        var probes = [
            PowerHelperLifetimeBarrierStatus.busy,
            .busy,
            .released,
        ]
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: {
                probes.isEmpty ? .released : probes.removeFirst()
            },
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(delays, [1_000_000_000, 1_000_000_000])
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testJobNotFoundWithBusyLifetimeBarrierNeverRegisters() async {
        let failure = NSError(
            domain: "SMAppServiceErrorDomain", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "job not found"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregisterError: failure)
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .busy })
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)
        XCTAssertEqual(
            fixture.handoffStore.transaction?.phase,
            .unregisterSubmitted)
    }

    func testRequiresApprovalLostCallbackAcceptsAbsentJobAndMissingLock() async throws {
        let failure = NSError(
            domain: "SMAppServiceErrorDomain", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "job not found"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregisterError: failure)
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .missing })
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: false)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testRebootCompletesAbsentOldGenerationWithoutLifetimeProbe() async throws {
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        var lifetimeProbeCalls = 0
        let fixture = makeFixture(
            backend: backend,
            bootSessionProvider: {
                "00000000-0000-0000-0000-000000000002"
            },
            lifetimeBarrierStatus: {
                lifetimeProbeCalls += 1
                return .missing
            })
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(lifetimeProbeCalls, 0)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testPrepareRequiresHeldLifetimeBarrierBeforeUnregisterSubmit() async {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .released })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(fixture.lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)
        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .preparing)
    }

    func testSubmittedPhaseIsDurableBeforeBackendUnregisterCall() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")
        backend.onUnregister = {
            XCTAssertEqual(
                fixture.handoffStore.transaction?.phase,
                .unregisterSubmitted)
        }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testDisableRecoveryDoesNotRegisterUntilNextInstallGoal() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        backend.suspendUnregister = true
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .unregisterSubmitted,
            goal: .remove,
            digest: nil,
            lifetimeBarrierExpected: true)

        let disabling = Task { try await fixture.service.disable() }
        await waitUntil { backend.unregisterCalls == 1 }
        backend.status = .notRegistered
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)

        backend.completeSuspendedUnregister()
        try await disabling.value

        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .removed)
        XCTAssertEqual(fixture.handoffStore.transaction?.goal, .remove)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testNewDigestDuringRegisteringReplacesBeforeOpeningGate() async throws {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .registering,
            goal: .install,
            digest: "digest-previous",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerHelperDefinitionDigest"),
            "digest-current")
    }

    func testCrashAfterUnregisterBeforeRegisterRestoresHelperWithoutPreparingAgain() async throws {
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        // This is also the disable/uninstall crash shape: the old digest can
        // still be current and no definition reconciliation was pending.
        fixture.defaults.set(
            "digest-current", forKey: "powerHelperDefinitionDigest")
        fixture.defaults.set(
            false, forKey: "powerHelperDefinitionReconcilePending")
        fixture.handoffStore.transaction = makeTransaction(
            phase: .removed,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.prepareCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testCrashAfterRegisterBeforeCancelCompletesHandoffWithoutSecondReplacement() async throws {
        let backend = FakePowerHelperBackend(status: .enabled, registrations: [])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")
        fixture.defaults.set(
            true, forKey: "powerHelperDefinitionReconcilePending")
        fixture.handoffStore.transaction = makeTransaction(
            phase: .registering,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertEqual(fixture.lifecycle.prepareCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerHelperDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(
            forKey: "powerHelperDefinitionReconcilePending"))
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testFailedStaleQuiesceRecoveryRemainsDurablyPending() async {
        let backend = FakePowerHelperBackend(status: .enabled, registrations: [])
        let lifecycle = FakePowerHelperLifecycle()
        lifecycle.cancelError = PowerHelperServiceError
            .registrationDidNotComplete
        let fixture = makeFixture(backend: backend, lifecycle: lifecycle)
        defer { fixture.cleanup() }
        fixture.handoffStore.transaction = makeTransaction(
            phase: .registering,
            goal: .install,
            digest: "digest-current",
            lifetimeBarrierExpected: true)

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(lifecycle.cancelCalls, 5)
        XCTAssertEqual(lifecycle.prepareCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .registering)
    }

    func testTransientPostRegisterCancelFailureRetriesNextLaunchWithoutReplacingAgain() async {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let lifecycle = FakePowerHelperLifecycle()
        lifecycle.cancelError = PowerHelperServiceError
            .registrationDidNotComplete
        let fixture = makeFixture(backend: backend, lifecycle: lifecycle)
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(lifecycle.cancelCalls, 5)
        XCTAssertEqual(fixture.handoffStore.transaction?.phase, .registering)

        lifecycle.cancelError = nil
        do {
            try await fixture.service.reconcileAfterAppUpdate()
        } catch {
            XCTFail("Expected next-launch gate recovery to succeed: \(error)")
        }

        XCTAssertEqual(lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(lifecycle.cancelCalls, 6)
        XCTAssertNil(fixture.handoffStore.transaction)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "powerHelperDefinitionDigest"),
            "digest-current")
    }

    func testUpdateHandoffReopensPersistedRootGateForNewAcquire() async throws {
        let rootStore = RootMemoryStore()
        let rootBackend = RootPowerBackend()
        let rootService = try PowerHelperLeaseService(
            store: rootStore,
            backend: rootBackend,
            batteryReader: RootBatteryReader(),
            bootSessionReader: RootBootSessionReader(),
            now: { Date(timeIntervalSince1970: 100) })
        let lifecycle = RootBackedPowerHelperLifecycle(service: rootService)
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let suite = "PowerHelperServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let handoffStore = MemoryPowerHelperHandoffStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let appService = PowerHelperService(
            backend: backend,
            lifecycle: lifecycle,
            defaults: defaults,
            handoffStore: handoffStore,
            digestProvider: { "digest-current" },
            sleep: { _ in })
        defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        try await appService.reconcileAfterAppUpdate()

        XCTAssertEqual(lifecycle.prepareCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(lifecycle.cancelCalls, 1)
        XCTAssertFalse(rootStore.state?.unregistrationPending ?? true)
        XCTAssertEqual(
            try rootService.acquireLease(
                PowerLeaseIdentity(
                    sessionName: "post-update", runToken: "run"),
                assertionActive: true).state,
            .protected)
    }

    func testMachineWideHandoffLockSerializesDifferentUserJournals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-power-system-handoff-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = PowerHelperSystemHandoffLock(
            fileURL: root.appendingPathComponent("handoff.lock"),
            expectedOwner: UInt32(geteuid()))
        try barrier.ensureExists()

        let firstBackend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        firstBackend.suspendUnregister = true
        let first = makeFixture(
            backend: firstBackend,
            systemHandoffLockProvider: {
                try barrier.acquire().map {
                    $0 as any PowerHelperHandoffLocking
                }
            })
        defer { first.cleanup() }
        first.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        let secondBackend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let second = makeFixture(
            backend: secondBackend,
            systemHandoffLockProvider: {
                try barrier.acquire().map {
                    $0 as any PowerHelperHandoffLocking
                }
            })
        defer { second.cleanup() }
        second.defaults.set(
            "digest-other-user", forKey: "powerHelperDefinitionDigest")

        let firstReconciliation = Task {
            try await first.service.reconcileAfterAppUpdate()
        }
        await waitUntil { firstBackend.unregisterCalls == 1 }

        await XCTAssertThrowsErrorAsync {
            try await second.service.reconcileAfterAppUpdate()
        }
        XCTAssertEqual(second.lifecycle.prepareCalls, 0)
        XCTAssertEqual(secondBackend.unregisterCalls, 0)
        XCTAssertEqual(secondBackend.registerCalls, 0)

        firstBackend.completeSuspendedUnregister()
        try await firstReconciliation.value
    }

    func testDifferentUserWithoutJournalReplaysInterruptedSystemUnregister() async throws {
        let alreadyAbsent = NSError(
            domain: "SMAppServiceErrorDomain", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "job not found"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregisterError: alreadyAbsent)
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .released })
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 1)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testForeignReplayErrorIsNotMistakenForACompletionBarrier() async {
        let operationInProgress = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "operation in progress"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregisterError: operationInProgress)
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .released })
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)
        XCTAssertEqual(
            fixture.handoffStore.transaction?.phase,
            .unregisterSubmitted)
    }

    func testMatchingJobNotFoundCodeFromForeignDomainIsNotACompletionBarrier() async {
        let foreignError = NSError(
            domain: "example.foreign-error",
            code: Int(kSMErrorJobNotFound),
            userInfo: [NSLocalizedDescriptionKey: "unrelated error"])
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)],
            unregisterError: foreignError)
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .released })
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(fixture.lifecycle.cancelCalls, 0)
        XCTAssertEqual(
            fixture.handoffStore.transaction?.phase,
            .unregisterSubmitted)
    }

    func testCrashReleasedSystemLockStillRequiresFreshForeignReplayBarrier() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-power-crashed-handoff-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = PowerHelperSystemHandoffLock(
            fileURL: root.appendingPathComponent("handoff.lock"),
            expectedOwner: UInt32(geteuid()))
        try barrier.ensureExists()

        // User A submitted unregister while owning this kernel lock, then its
        // app crashed. The descriptor release alone is not a completion proof.
        var crashedUserLease: PowerHelperSystemHandoffLease? = try XCTUnwrap(
            barrier.acquire())
        XCTAssertNotNil(crashedUserLease)
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        backend.suspendUnregister = true
        let foreignUser = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .released },
            systemHandoffLockProvider: {
                try barrier.acquire().map {
                    $0 as any PowerHelperHandoffLocking
                }
            })
        defer { foreignUser.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await foreignUser.service.reconcileAfterAppUpdate()
        }
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)

        // Simulate A's crash: the kernel lock is released, but B still has no
        // local journal proving that A's asynchronous unregister completed.
        crashedUserLease = nil
        let recovery = Task {
            try await foreignUser.service.reconcileAfterAppUpdate()
        }
        await waitUntil { backend.unregisterCalls == 1 }
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertEqual(foreignUser.lifecycle.cancelCalls, 0)

        backend.completeSuspendedUnregister()
        try await recovery.value
        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(foreignUser.lifecycle.cancelCalls, 1)
    }

    func testBackgroundUserCannotPerformPristineInitialRegistration() async {
        let backend = FakePowerHelperBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            lifetimeBarrierStatus: { .missing },
            systemHandoffLockProvider: { nil },
            currentProcessIsActiveConsoleUser: { false })
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
        XCTAssertNil(fixture.handoffStore.transaction)
    }

    func testMissingSystemLockFailsClosedAfterAHelperHasRun() async {
        let backend = FakePowerHelperBackend(
            status: .enabled,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(
            backend: backend,
            systemHandoffLockProvider: { nil })
        defer { fixture.cleanup() }
        fixture.defaults.set(
            "digest-previous", forKey: "powerHelperDefinitionDigest")

        await XCTAssertThrowsErrorAsync {
            try await fixture.service.reconcileAfterAppUpdate()
        }

        XCTAssertEqual(fixture.lifecycle.prepareCalls, 0)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(backend.registerCalls, 0)
    }

    private func makeFixture(
        backend: FakePowerHelperBackend,
        lifecycle: FakePowerHelperLifecycle? = nil,
        bootSessionProvider: @escaping () throws -> String = {
            "00000000-0000-0000-0000-000000000001"
        },
        lifetimeBarrierStatus: @escaping () throws
            -> PowerHelperLifetimeBarrierStatus = { .busy },
        systemHandoffLockProvider: @escaping () throws
            -> (any PowerHelperHandoffLocking)? = {
                MemoryPowerHelperHandoffLock()
            },
        currentProcessIsActiveConsoleUser: @escaping () -> Bool = { true },
        digestProvider: @escaping () -> String? = { "digest-current" },
        sleep: @escaping (UInt64) async throws -> Void = { _ in }
    ) -> PowerHelperFixture {
        let lifecycle = lifecycle ?? FakePowerHelperLifecycle()
        let suite = "PowerHelperServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let handoffStore = MemoryPowerHelperHandoffStore()
        let service = PowerHelperService(
            backend: backend,
            lifecycle: lifecycle,
            defaults: defaults,
            handoffStore: handoffStore,
            digestProvider: digestProvider,
            bootSessionProvider: bootSessionProvider,
            lifetimeBarrierStatus: lifetimeBarrierStatus,
            systemHandoffLockProvider: systemHandoffLockProvider,
            currentProcessIsActiveConsoleUser:
                currentProcessIsActiveConsoleUser,
            sleep: sleep)
        return PowerHelperFixture(
            service: service, lifecycle: lifecycle,
            defaults: defaults, handoffStore: handoffStore, suite: suite)
    }
}

private final class RootMemoryStore: PowerHelperStateStoring {
    var state: PowerHelperPersistentState?

    func load() throws -> PowerHelperPersistentState? { state }

    func save(_ state: PowerHelperPersistentState) throws {
        self.state = state
    }
}

private actor LifecycleCLI: DetachCLIRunning {
    private var responses: [Result<CLIResult, Error>]
    private(set) var arguments: [[String]] = []
    private(set) var timeouts: [TimeInterval] = []

    init(responses: [Result<CLIResult, Error>]) {
        self.responses = responses
    }

    func run(
        arguments: [String], timeout: TimeInterval
    ) async throws -> CLIResult {
        self.arguments.append(arguments)
        timeouts.append(timeout)
        return try responses.removeFirst().get()
    }

    func calls() -> (arguments: [[String]], timeouts: [TimeInterval]) {
        (arguments, timeouts)
    }
}

private final class RootPowerBackend: ClosedLidProtectionControlling {
    private(set) var enabled = false

    func protectionIsEnabled() throws -> Bool { enabled }

    func setProtectionEnabled(_ enabled: Bool) throws {
        self.enabled = enabled
    }
}

private struct RootBatteryReader: PowerBatterySafetyReading {
    func isLowBattery() throws -> Bool { false }
}

private struct RootBootSessionReader: PowerBootSessionReading {
    func currentBootSessionIdentifier() throws -> String { "test-boot" }
}

@MainActor
private final class RootBackedPowerHelperLifecycle:
    PowerHelperLifecycleRunning
{
    let service: PowerHelperLeaseService
    private(set) var prepareCalls = 0
    private(set) var cancelCalls = 0

    init(service: PowerHelperLeaseService) {
        self.service = service
    }

    func prepareForUnregistration() async throws
        -> PowerHelperUnregistrationPreparation
    {
        prepareCalls += 1
        try service.prepareForUnregistration()
        return .prepared
    }

    func cancelUnregistration() async throws {
        cancelCalls += 1
        _ = try service.cancelUnregistration()
    }
}

@MainActor
private final class FakePowerHelperBackend: PowerHelperRegistrationBackend {
    enum Registration {
        case success(PowerHelperRegistrationStatus)
        case approvalRequired(Error)
        case failure(Error)
    }

    var status: PowerHelperRegistrationStatus
    var registrations: [Registration]
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    var unregisterError: Error?
    var suspendUnregister = false
    var onUnregister: (() -> Void)?
    private var unregisterContinuation: CheckedContinuation<Void, Never>?

    init(
        status: PowerHelperRegistrationStatus,
        registrations: [Registration],
        unregisterError: Error? = nil
    ) {
        self.status = status
        self.registrations = registrations
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCalls += 1
        guard !registrations.isEmpty else {
            throw PowerHelperServiceError.registrationDidNotComplete
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
        onUnregister?()
        if suspendUnregister {
            await withCheckedContinuation { continuation in
                unregisterContinuation = continuation
            }
        }
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func completeSuspendedUnregister() {
        suspendUnregister = false
        unregisterContinuation?.resume()
        unregisterContinuation = nil
    }
}

@MainActor
private final class FakePowerHelperLifecycle: PowerHelperLifecycleRunning {
    var preparations: [Result<PowerHelperUnregistrationPreparation, Error>]
    var cancelError: Error?
    private(set) var prepareCalls = 0
    private(set) var cancelCalls = 0

    init(
        preparations: [Result<PowerHelperUnregistrationPreparation, Error>] = [
            .success(.prepared),
        ]
    ) {
        self.preparations = preparations
    }

    func prepareForUnregistration() async throws
        -> PowerHelperUnregistrationPreparation
    {
        prepareCalls += 1
        guard !preparations.isEmpty else {
            throw PowerHelperServiceError.registrationDidNotComplete
        }
        return try preparations.removeFirst().get()
    }

    func cancelUnregistration() async throws {
        cancelCalls += 1
        if let cancelError { throw cancelError }
    }
}

private final class MemoryPowerHelperHandoffStore: PowerHelperHandoffStoring {
    var transaction: PowerHelperHandoffTransaction?

    func acquireTransactionLock() throws -> any PowerHelperHandoffLocking {
        MemoryPowerHelperHandoffLock()
    }

    func load() throws -> PowerHelperHandoffTransaction? { transaction }

    func save(_ transaction: PowerHelperHandoffTransaction) throws {
        self.transaction = transaction
    }

    func clear() throws {
        transaction = nil
    }
}

private final class MemoryPowerHelperHandoffLock: PowerHelperHandoffLocking {}

@MainActor
private struct PowerHelperFixture {
    let service: PowerHelperService
    let lifecycle: FakePowerHelperLifecycle
    let defaults: UserDefaults
    let handoffStore: MemoryPowerHelperHandoffStore
    let suite: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private func makeTransaction(
    phase: PowerHelperHandoffTransaction.Phase,
    goal: PowerHelperHandoffTransaction.Goal,
    digest: String?,
    lifetimeBarrierExpected: Bool
) -> PowerHelperHandoffTransaction {
    PowerHelperHandoffTransaction(
        phase: phase,
        goal: goal,
        targetDigest: digest,
        bootSessionIdentifier: "00000000-0000-0000-0000-000000000001",
        lifetimeBarrierExpected: lifetimeBarrierExpected)
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

@MainActor
private func waitUntil(
    _ predicate: () -> Bool,
    attempts: Int = 100,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<attempts {
        if predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition did not become true", file: file, line: line)
}
