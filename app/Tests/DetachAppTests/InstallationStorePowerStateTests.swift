import DetachKit
import Foundation
import Observation
import XCTest
@testable import DetachApp

@MainActor
final class InstallationStorePowerStateTests: XCTestCase {
    func testDefaultPowerStateRootUsesTheSharedHeartbeatResolver() {
        let store = InstallationStore(detachPath: "/tmp/detach-test")

        XCTAssertEqual(
            store.watchdogHeartbeat.statusURL.standardizedFileURL,
            PowerHeartbeatReader.defaultStatusURL().standardizedFileURL)
    }

    func testInitialAppContextChecksTruthfullyDescribeUnconfiguredServices() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)

        let checks = Dictionary(uniqueKeysWithValues: store.appContextChecks.map {
            ($0.id, $0)
        })

        XCTAssertEqual(Set(checks.keys), [
            "app_location", "app_cli_match", "app_power_helper",
            "app_watchdog", "watchdog_heartbeat",
        ])
        XCTAssertEqual(checks["app_location"]?.status, .ok)
        XCTAssertEqual(checks["app_cli_match"]?.status, .error)
        XCTAssertEqual(checks["app_power_helper"]?.status, .error)
        XCTAssertEqual(
            checks["app_power_helper"]?.summary,
            "macOS could not register the native power helper")
        XCTAssertEqual(checks["app_watchdog"]?.status, .error)
        XCTAssertEqual(
            checks["app_watchdog"]?.summary,
            "macOS has not registered the power monitor yet")
        XCTAssertEqual(checks["watchdog_heartbeat"]?.status, .unknown)
        XCTAssertFalse(checks["watchdog_heartbeat"]?.required ?? true)
        XCTAssertFalse(store.providerCheckPassed)
        XCTAssertFalse(store.presentsUIE2EOnboarding)
    }

    func testProductionFactoriesConstructRealProcessBoundaries() {
        let installerURL = URL(fileURLWithPath: "/tmp/detach-install")
        let cliURL = URL(fileURLWithPath: "/tmp/detach")
        let payloadURL = URL(fileURLWithPath: "/tmp/payload")
        let versionURL = payloadURL.appendingPathComponent("VERSION")

        let distribution = InstallationStore.makeDistributionClient(
            installerURL: installerURL,
            cliURL: cliURL,
            payloadDirectory: payloadURL,
            versionURL: versionURL)
        let cli = InstallationStore.makeCLI(executable: cliURL)

        XCTAssertTrue(distribution is DistributionClient)
        XCTAssertEqual((cli as? ProcessDetachCLI)?.executable, cliURL)
    }

    func testUIE2EOnboardingFixturesExposeOnlyTheirRequestedStep() {
        let fixtures: [(String, OnboardingStep)] = [
            ("onboarding-first-run", .done),
            ("onboarding-provider", .provider),
            ("onboarding-approval", .permissions),
        ]

        for (scenario, expectedStep) in fixtures {
            let store = InstallationStore(
                detachPath: "/tmp/detach-test",
                uiE2EScenario: scenario)

            XCTAssertTrue(store.presentsUIE2EOnboarding)
            XCTAssertEqual(store.onboardingStep, expectedStep)
        }
    }

    func testHealthyFirstRunCompletionClearsTheFixtureStep() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp())"}"#,
            to: root)
        let suite = "detach-ui-e2e-onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root,
            defaults: defaults,
            uiE2EScenario: "onboarding-first-run")

        XCTAssertEqual(store.onboardingStep, .done)
        XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted"))

        store.markOnboardingCompleted()

        XCTAssertFalse(store.presentsUIE2EOnboarding)
        XCTAssertEqual(store.onboardingStep, .mainApp)
        XCTAssertTrue(defaults.bool(forKey: "onboardingCompleted"))
    }

    func testAppContextHeartbeatCheckPublishesFreshReportedPowerState() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp())"}"#,
            to: root)
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)

        let heartbeat = try XCTUnwrap(
            store.appContextChecks.first { $0.id == "watchdog_heartbeat" })

        XCTAssertEqual(heartbeat.status, .ok)
        XCTAssertEqual(
            heartbeat.summary,
            "The background monitor reported power state: protected")
        XCTAssertEqual(
            heartbeat.path,
            root.appendingPathComponent("watchdog-status.json").path)
    }

    func testHealthyHeartbeatWithoutPowerStateUsesLaunchSummary() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","checked_at":"\#(stamp())"}"#,
            to: root)
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)

        let heartbeat = try XCTUnwrap(
            store.appContextChecks.first { $0.id == "watchdog_heartbeat" })

        XCTAssertEqual(heartbeat.status, .ok)
        XCTAssertEqual(
            heartbeat.summary,
            "The background power monitor ran within the last three minutes")
    }

    func testBundledPayloadOutsideApplicationsRequiresMoveBeforeWork() async throws {
        let bundleRoot = try makeTestAppBundle()
        defer { try? FileManager.default.removeItem(at: bundleRoot) }
        let bundle = try XCTUnwrap(Bundle(path: bundleRoot.path))
        var operations: [InstallationContextOperation] = []
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            bundle: bundle,
            contextOperationOverride: { operations.append($0) })

        XCTAssertTrue(store.hasDistributionPayload)
        XCTAssertFalse(store.isStableApplicationLocation)
        XCTAssertEqual(store.onboardingStep, .moveToApplications)
        let location = try XCTUnwrap(
            store.appContextChecks.first { $0.id == "app_location" })
        XCTAssertEqual(location.status, .error)
        XCTAssertEqual(
            location.summary,
            "Move Detach.app to Applications and open the installed copy")

        await store.bootstrap()
        XCTAssertEqual(store.phase, .actionRequired)
        await store.repair()
        XCTAssertTrue(operations.isEmpty)
    }

    func testDeveloperBootstrapIsIdempotentAfterReady() async {
        let store = InstallationStore(detachPath: "/tmp/detach-test")

        await store.bootstrap()
        XCTAssertEqual(store.phase, .ready)
        await store.bootstrap()
        XCTAssertEqual(store.phase, .ready)
    }

    func testPowerHelperHandoffErrorPreventsReadyPhase() {
        let phase = InstallationStore.phaseForReadiness(
            isStableApplicationLocation: true,
            distributionMatchesBundle: true,
            requiredDoctorChecksHealthy: true,
            watchdogStatus: .enabled,
            powerHelperStatus: .enabled,
            powerHelperError: "previous helper has not finished exiting")

        XCTAssertEqual(phase, .actionRequired)
    }

    func testDeferredPowerHelperUpdateKeepsCompletedOnboardingOnDashboard() {
        let fixture = makeCompletedOnboardingStore()
        defer { fixture.cleanup() }

        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .updateDeferred,
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: true,
                    isBusy: false,
                    failureMessage: nil,
                    distributionMatchesBundle: true,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: false,
                    providerInstalled: true,
                    onboardingEverCompleted: true)),
            .mainApp)
    }

    func testCompletedOnboardingKeepsDashboardDuringPowerRetry() {
        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .syncing,
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: true,
                    isBusy: true,
                    failureMessage: nil,
                    distributionMatchesBundle: true,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: false,
                    providerInstalled: true,
                    onboardingEverCompleted: true)),
            .mainApp)
    }

    func testCompletedOnboardingKeepsDashboardWhenPowerReadinessFails() {
        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .actionRequired,
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: true,
                    isBusy: false,
                    failureMessage: nil,
                    distributionMatchesBundle: true,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: false,
                    providerInstalled: true,
                    onboardingEverCompleted: true)),
            .mainApp)
    }

    func testCompletedOnboardingKeepsDashboardWhenProviderIsMissing() {
        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .actionRequired,
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: true,
                    isBusy: false,
                    failureMessage: nil,
                    distributionMatchesBundle: true,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: true,
                    providerInstalled: false,
                    onboardingEverCompleted: true)),
            .mainApp)
    }

    func testCompletedOnboardingKeepsDashboardForTransientDoctorFailure() {
        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .failed("helper is unavailable"),
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: true,
                    isBusy: false,
                    failureMessage: "helper is unavailable",
                    distributionMatchesBundle: true,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: false,
                    providerInstalled: true,
                    onboardingEverCompleted: true)),
            .mainApp)
    }

    func testCompletedOnboardingShowsRuntimeRepairWhenPayloadDoesNotMatch() {
        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .failed("runtime mismatch"),
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: true,
                    isBusy: false,
                    failureMessage: "runtime mismatch",
                    distributionMatchesBundle: false,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: true,
                    providerInstalled: true,
                    onboardingEverCompleted: true)),
            .autoSetup(failureMessage: "runtime mismatch"))
    }

    func testCompletedOnboardingShowsActionableLocationGuidance() {
        XCTAssertEqual(
            InstallationStore.onboardingStep(
                phase: .actionRequired,
                onboardingEverCompleted: true,
                input: .init(
                    isStableApplicationLocation: false,
                    isBusy: false,
                    failureMessage: nil,
                    distributionMatchesBundle: true,
                    powerHelperEnabled: true,
                    watchdogEnabled: true,
                    powerReadinessConfirmed: true,
                    providerInstalled: true,
                    onboardingEverCompleted: true)),
            .moveToApplications)
    }

    func testHealthyReadinessInputsStillProduceReadyPhase() {
        let phase = InstallationStore.phaseForReadiness(
            isStableApplicationLocation: true,
            distributionMatchesBundle: true,
            requiredDoctorChecksHealthy: true,
            watchdogStatus: .enabled,
            powerHelperStatus: .enabled,
            powerHelperError: nil)

        XCTAssertEqual(phase, .ready)
    }

    func testEnabledRegistrationNeedsReachableDoctorCheck() {
        let unreachable = doctorReport(powerHelperStatus: .error)
        XCTAssertFalse(InstallationStore.powerHelperReadiness(
            distributionMatchesBundle: true,
            powerHelperStatus: .enabled,
            powerHelperError: nil,
            report: unreachable))

        let reachable = doctorReport(powerHelperStatus: .ok)
        XCTAssertTrue(InstallationStore.powerHelperReadiness(
            distributionMatchesBundle: true,
            powerHelperStatus: .enabled,
            powerHelperError: nil,
            report: reachable))
    }

    func testDoctorReachabilityCannotOverrideRegistrationOrReconcileFailure() {
        let reachable = doctorReport(powerHelperStatus: .ok)
        XCTAssertFalse(InstallationStore.powerHelperReadiness(
            distributionMatchesBundle: true,
            powerHelperStatus: .requiresApproval,
            powerHelperError: nil,
            report: reachable))
        XCTAssertFalse(InstallationStore.powerHelperReadiness(
            distributionMatchesBundle: true,
            powerHelperStatus: .enabled,
            powerHelperError: "readiness failed",
            report: reachable))
        XCTAssertFalse(InstallationStore.powerHelperReadiness(
            distributionMatchesBundle: false,
            powerHelperStatus: .enabled,
            powerHelperError: nil,
            report: reachable))
    }

    func testInstalledRuntimeRequiresIdentityAndEveryOwnedCheck() {
        let healthy = installedRuntimeReport()
        XCTAssertTrue(InstallationStore.installedRuntimeMatches(
            report: healthy,
            version: "0.2.7",
            build: "17",
            payloadID: "payload"))

        var damaged = healthy
        damaged.checks[3].status = .error
        XCTAssertFalse(InstallationStore.installedRuntimeMatches(
            report: damaged,
            version: "0.2.7",
            build: "17",
            payloadID: "payload"))

        var incomplete = healthy
        incomplete.checks.removeAll { $0.id == "power_runtime" }
        XCTAssertFalse(InstallationStore.installedRuntimeMatches(
            report: incomplete,
            version: "0.2.7",
            build: "17",
            payloadID: "payload"))

        XCTAssertFalse(InstallationStore.installedRuntimeMatches(
            report: healthy,
            version: "0.2.7",
            build: "18",
            payloadID: "payload"))
    }

    func testFreshHealthyHeartbeatProvidesEffectivePowerState() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp())"}"#,
            to: root)

        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)

        XCTAssertEqual(store.powerProtectionState, .protected)
    }

    func testStaleHeartbeatDoesNotClaimPowerState() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(stamp(offset: -300))"}"#,
            to: root)

        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)

        XCTAssertEqual(store.powerProtectionState, .unknown)
    }

    func testFutureDatedHeartbeatDoesNotClaimPowerState() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp(offset: 300))"}"#,
            to: root)

        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)

        XCTAssertEqual(store.powerProtectionState, .unknown)
    }

    func testUnhealthyOrMalformedHeartbeatDoesNotClaimPowerState() throws {
        for body in [
            #"{"state":"status_failed","power_state":"protected","checked_at":"\#(stamp())"}"#,
            #"{"state":"ok","power_state":"future_state","checked_at":"\#(stamp())"}"#,
            #"{"state":"ok","power_state":"protected"}"#, // no checked_at → stale
            "not-json",
        ] {
            let root = try makeStateRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeHeartbeat(body, to: root)
            let store = InstallationStore(
                detachPath: "/tmp/detach-test",
                powerStateRoot: root)

            XCTAssertEqual(store.powerProtectionState, .unknown)
        }
    }

    func testRefreshingSnapshotPublishesHeartbeatAndPowerStateChanges() throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(stamp())"}"#,
            to: root)
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)
        XCTAssertEqual(store.powerProtectionState, .allowed)
        XCTAssertEqual(store.watchdogHeartbeat.powerState, .allowed)

        nonisolated(unsafe) var heartbeatObservationInvalidated = false
        withObservationTracking {
            _ = store.watchdogHeartbeat
        } onChange: {
            heartbeatObservationInvalidated = true
        }

        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp())"}"#,
            to: root)
        store.refreshPowerProtectionState()

        XCTAssertTrue(heartbeatObservationInvalidated)
        XCTAssertEqual(store.watchdogHeartbeat.powerState, .protected)
        XCTAssertEqual(store.powerProtectionState, .protected)
    }

    func testTimestampOnlyHeartbeatRefreshDoesNotInvalidatePresentedState()
        throws
    {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(stamp(offset: -30))"}"#,
            to: root)
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)
        let initialCheckedAt = try XCTUnwrap(store.watchdogHeartbeat.checkedAt)

        nonisolated(unsafe) var observationInvalidated = false
        withObservationTracking {
            _ = store.watchdogHeartbeat
            _ = store.powerProtectionState
        } onChange: {
            observationInvalidated = true
        }

        try writeHeartbeat(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(stamp())"}"#,
            to: root)
        store.refreshPowerProtectionState()

        XCTAssertFalse(observationInvalidated)
        XCTAssertGreaterThan(
            try XCTUnwrap(store.watchdogHeartbeat.checkedAt),
            initialCheckedAt)
        XCTAssertEqual(store.powerProtectionState, .allowed)
    }

    func testPowerObservationPublishesAtomicChangesWithoutPolling() async throws {
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeartbeat(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(stamp())"}"#,
            to: root)
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)
        var delivered: PowerHeartbeatSnapshot?
        store.onPowerSnapshot = { delivered = $0 }
        store.startPowerObservation()

        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp())"}"#,
            to: root)
        for _ in 0..<100
            where store.powerProtectionState != .protected
                || delivered?.effectivePowerState != .protected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.powerProtectionState, .protected)
        XCTAssertEqual(delivered?.effectivePowerState, .protected)
    }

    func testCompletedOnboardingColdLaunchStartsOnDashboard() {
        let fixture = makeCompletedOnboardingStore()
        defer { fixture.cleanup() }

        XCTAssertEqual(fixture.store.onboardingStep, .mainApp)
    }

    func testCompletedOnboardingRefreshKeepsDashboardMounted() async {
        let probe = InstallationContextOperationProbe()
        let fixture = makeCompletedOnboardingStore(
            contextOperationOverride: { operation in
                await probe.run(operation)
            })
        defer { fixture.cleanup() }
        await fixture.store.bootstrap()
        XCTAssertEqual(fixture.store.onboardingStep, .mainApp)

        let refresh = Task { await fixture.store.refreshContext() }
        await waitUntil { probe.operations == [.refresh] }

        XCTAssertTrue(fixture.store.isBusy)
        XCTAssertEqual(fixture.store.onboardingStep, .mainApp)

        probe.releaseNext()
        _ = await refresh.value
        XCTAssertEqual(fixture.store.onboardingStep, .mainApp)
    }

    func testOnboardingCannotCompleteBeforeFreshHeartbeat() throws {
        let suite = "InstallationStorePowerStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root,
            defaults: defaults)

        store.markOnboardingCompleted()
        XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted"))

        try writeHeartbeat(
            #"{"state":"ok","power_state":"allowed","checked_at":"\#(stamp())"}"#,
            to: root)
        store.markOnboardingCompleted()
        XCTAssertTrue(defaults.bool(forKey: "onboardingCompleted"))
    }

    func testRepairQueuesBehindRefreshAndForcesOneFinalRefresh() async {
        let probe = InstallationContextOperationProbe()
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            contextOperationOverride: { operation in
                await probe.run(operation)
            })
        var firstRefreshFinished = false
        var repairFinished = false
        var secondRefreshFinished = false

        let firstRefresh = Task {
            await store.refreshContext()
            firstRefreshFinished = true
        }
        await waitUntil { probe.operations.count == 1 }
        XCTAssertEqual(probe.operations, [.refresh])
        XCTAssertTrue(store.isBusy)

        let repair = Task {
            await store.repair()
            repairFinished = true
        }
        let secondRefresh = Task {
            await store.refreshContext()
            secondRefreshFinished = true
        }
        await Task.yield()
        XCTAssertEqual(probe.operations, [.refresh])

        probe.releaseNext()
        await waitUntil { probe.operations.count == 2 }
        XCTAssertEqual(probe.operations, [.refresh, .repair])
        XCTAssertFalse(firstRefreshFinished)
        XCTAssertFalse(repairFinished)
        XCTAssertFalse(secondRefreshFinished)

        probe.releaseNext()
        await waitUntil { probe.operations.count == 3 }
        XCTAssertEqual(probe.operations, [.refresh, .repair, .refresh])
        XCTAssertFalse(firstRefreshFinished)
        XCTAssertFalse(repairFinished)
        XCTAssertFalse(secondRefreshFinished)

        probe.releaseNext()
        await firstRefresh.value
        await repair.value
        await secondRefresh.value

        XCTAssertEqual(probe.maximumConcurrentOperations, 1)
        XCTAssertFalse(store.isBusy)
        XCTAssertNotEqual(store.phase, .actionRequired)
        XCTAssertTrue(firstRefreshFinished)
        XCTAssertTrue(repairFinished)
        XCTAssertTrue(secondRefreshFinished)
    }

    func testConcurrentRefreshTriggersCoalesceIntoOneTrailingRefresh() async {
        let probe = InstallationContextOperationProbe()
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            contextOperationOverride: { operation in
                await probe.run(operation)
            })

        let first = Task { await store.refreshContext() }
        await waitUntil { probe.operations.count == 1 }
        let duplicates = (0..<4).map { _ in
            Task { await store.refreshContext() }
        }
        await Task.yield()

        probe.releaseNext()
        await waitUntil { probe.operations.count == 2 }
        XCTAssertEqual(probe.operations, [.refresh, .refresh])

        probe.releaseNext()
        _ = await first.value
        for duplicate in duplicates { _ = await duplicate.value }

        XCTAssertEqual(probe.operations, [.refresh, .refresh])
        XCTAssertEqual(probe.maximumConcurrentOperations, 1)
        XCTAssertFalse(store.isBusy)
    }

    func testConcurrentRepairsDeduplicateAndConvergeWithOneRefresh() async {
        let probe = InstallationContextOperationProbe()
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            contextOperationOverride: { operation in
                await probe.run(operation)
            })

        let first = Task { await store.repair() }
        await waitUntil { probe.operations == [.repair] }
        let duplicate = Task { await store.repair() }

        probe.releaseNext()
        await waitUntil { probe.operations == [.repair, .refresh] }
        probe.releaseNext()
        await first.value
        await duplicate.value

        XCTAssertEqual(probe.operations, [.repair, .refresh])
        XCTAssertEqual(probe.maximumConcurrentOperations, 1)
        XCTAssertFalse(store.isBusy)
    }

    func testPackagedBootstrapReconcilesServicesAndPublishesReadyState()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed payload")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: watchdog,
            powerHelper: powerHelper)
        defer { fixture.cleanup() }

        await fixture.store.bootstrap()

        XCTAssertEqual(fixture.store.phase, .ready)
        XCTAssertTrue(fixture.store.distributionMatchesBundle)
        XCTAssertTrue(fixture.store.powerHelperReadinessConfirmed)
        XCTAssertEqual(fixture.store.lastInstallMessage, "installed payload")
        XCTAssertEqual(distribution.repairs, [false])
        XCTAssertEqual(distribution.doctorCallCount, 2)
        XCTAssertEqual(powerHelper.reconcileCallCount, 1)
        XCTAssertEqual(watchdog.forceReplacementRequests, [true])
        let checks = Dictionary(uniqueKeysWithValues:
            fixture.store.appContextChecks.map { ($0.id, $0) })
        XCTAssertEqual(checks["app_cli_match"]?.status, .ok)
        XCTAssertEqual(checks["app_power_helper"]?.status, .ok)
        XCTAssertEqual(checks["app_watchdog"]?.status, .ok)
        XCTAssertEqual(checks["watchdog_heartbeat"]?.status, .warning)
    }

    func testDeferredExistingInstallRetriesAutomaticallyAndRecovers()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [
                .success("first install"), .success("recovered install"),
            ],
            doctorResults: [
                .success(installedRuntimeReport(build: "other")),
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            completedOnboarding: true,
            distribution: distribution,
            watchdog: watchdog,
            powerHelper: powerHelper)
        defer { fixture.cleanup() }

        await fixture.store.bootstrap()

        XCTAssertEqual(fixture.store.phase, .updateDeferred)
        XCTAssertFalse(fixture.store.distributionMatchesBundle)
        XCTAssertEqual(powerHelper.reconcileCallCount, 0)
        XCTAssertTrue(watchdog.forceReplacementRequests.isEmpty)

        let refreshed = await fixture.store.refreshContext()
        XCTAssertTrue(refreshed)

        XCTAssertEqual(fixture.store.phase, .ready)
        XCTAssertTrue(fixture.store.distributionMatchesBundle)
        XCTAssertEqual(fixture.store.lastInstallMessage, "recovered install")
        XCTAssertEqual(distribution.repairs, [false, false])
        XCTAssertEqual(powerHelper.reconcileCallCount, 1)
        XCTAssertEqual(watchdog.forceReplacementRequests, [false])
    }

    func testSynchronizeDecidesForceReplacementFromFreshHeartbeatSnapshot()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("repaired")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            completedOnboarding: true,
            distribution: distribution,
            watchdog: watchdog,
            powerHelper: powerHelper)
        defer { fixture.cleanup() }

        XCTAssertFalse(fixture.store.watchdogHeartbeat.healthy)
        try writeHeartbeat(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp())"}"#,
            to: fixture.stateRoot)
        XCTAssertFalse(fixture.store.watchdogHeartbeat.healthy)

        await fixture.store.repair()

        XCTAssertTrue(fixture.store.watchdogHeartbeat.healthy)
        XCTAssertEqual(watchdog.forceReplacementRequests, [false])
        XCTAssertEqual(distribution.repairs, [true])
    }

    func testRepairDefersHelperReplacementWhileActiveLeasesRemain()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("repaired")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(
            status: .enabled,
            reconcileResult: .success(.deferredForActiveLeases))
        let fixture = try makePackagedInstallationFixture(
            completedOnboarding: true,
            distribution: distribution,
            watchdog: watchdog,
            powerHelper: powerHelper)
        defer { fixture.cleanup() }

        await fixture.store.repair()

        XCTAssertEqual(fixture.store.phase, .updateDeferred)
        XCTAssertEqual(fixture.store.onboardingStep, .mainApp)
        XCTAssertTrue(fixture.store.powerHelperReadinessConfirmed)
        XCTAssertEqual(distribution.repairs, [true])
        XCTAssertEqual(watchdog.forceReplacementRequests, [true])
    }

    func testRefreshWithdrawsReadinessWhenServiceReconciliationFails()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: watchdog,
            powerHelper: powerHelper)
        defer { fixture.cleanup() }
        await fixture.store.bootstrap()
        XCTAssertEqual(fixture.store.phase, .ready)

        watchdog.status = .notRegistered
        watchdog.reconcileResult = .failure(InstallationProbeError.watchdog)
        powerHelper.reconcileResult = .failure(
            InstallationProbeError.powerHelper)

        let refreshed = await fixture.store.refreshContext()
        XCTAssertTrue(refreshed)

        XCTAssertEqual(fixture.store.phase, .actionRequired)
        XCTAssertFalse(fixture.store.powerHelperReadinessConfirmed)
        XCTAssertEqual(
            fixture.store.powerHelperError, "power helper probe failed")
        XCTAssertEqual(fixture.store.watchdogError, "watchdog probe failed")
        XCTAssertEqual(watchdog.forceReplacementRequests, [true, false])
        let checks = Dictionary(uniqueKeysWithValues:
            fixture.store.appContextChecks.map { ($0.id, $0) })
        XCTAssertEqual(checks["app_power_helper"]?.status, .error)
        XCTAssertEqual(checks["app_watchdog"]?.status, .error)
    }

    func testRefreshRejectsRuntimeIdentityDrift() async throws {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport(build: "replaced")),
            ])
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: InstallationWatchdogProbe(status: .enabled),
            powerHelper: InstallationPowerHelperProbe(status: .enabled))
        defer { fixture.cleanup() }
        await fixture.store.bootstrap()

        let refreshed = await fixture.store.refreshContext()
        XCTAssertTrue(refreshed)

        XCTAssertEqual(
            fixture.store.phase,
            .failed("The CLI is missing or belongs to another build; run Repair from the intended app version"))
        XCTAssertFalse(fixture.store.distributionMatchesBundle)
        XCTAssertFalse(fixture.store.powerHelperReadinessConfirmed)
    }

    func testRefreshRejectsAnApplicationLocationThatBecameUnstable()
        async throws
    {
        var stableLocation = true
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: InstallationWatchdogProbe(status: .enabled),
            powerHelper: InstallationPowerHelperProbe(status: .enabled),
            applicationLocationValidator: { _ in stableLocation })
        defer { fixture.cleanup() }
        await fixture.store.bootstrap()
        XCTAssertEqual(fixture.store.phase, .ready)

        stableLocation = false
        let refreshed = await fixture.store.refreshContext()

        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.store.phase, .actionRequired)
        XCTAssertEqual(distribution.doctorCallCount, 2)
    }

    func testPostRegistrationDoctorFailureCannotPublishStaleReadiness()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .failure(InstallationProbeError.doctor),
            ])
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: InstallationWatchdogProbe(status: .enabled),
            powerHelper: InstallationPowerHelperProbe(status: .enabled))
        defer { fixture.cleanup() }

        await fixture.store.bootstrap()

        XCTAssertEqual(fixture.store.phase, .failed("doctor probe failed"))
        XCTAssertFalse(fixture.store.powerHelperReadinessConfirmed)
    }

    func testRegistrationPollingPublishesEveryActionableStatus() throws {
        let watchdog = InstallationWatchdogProbe(status: .requiresApproval)
        let powerHelper = InstallationPowerHelperProbe(
            status: .requiresApproval)
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            watchdog: watchdog,
            powerHelper: powerHelper)

        store.refreshRegistrationStatusesOnly()
        var checks = Dictionary(uniqueKeysWithValues:
            store.appContextChecks.map { ($0.id, $0) })
        XCTAssertEqual(checks["app_power_helper"]?.status, .warning)
        XCTAssertEqual(checks["app_watchdog"]?.status, .error)

        watchdog.status = .notRegistered
        powerHelper.status = .notRegistered
        store.refreshRegistrationStatusesOnly()
        checks = Dictionary(uniqueKeysWithValues:
            store.appContextChecks.map { ($0.id, $0) })
        XCTAssertEqual(checks["app_power_helper"]?.status, .warning)
        XCTAssertEqual(checks["app_watchdog"]?.status, .error)

        watchdog.status = .enabled
        powerHelper.status = .enabled
        store.refreshRegistrationStatusesOnly()
        checks = Dictionary(uniqueKeysWithValues:
            store.appContextChecks.map { ($0.id, $0) })
        XCTAssertEqual(checks["app_power_helper"]?.status, .warning)
        XCTAssertEqual(checks["app_watchdog"]?.status, .ok)

        store.openLoginItemsSettings()
        store.openPowerHelperApprovalSettings()
        XCTAssertEqual(watchdog.openSettingsCallCount, 1)
        XCTAssertEqual(powerHelper.openSettingsCallCount, 1)
    }

    func testUninstallRemovesServicesBeforeDistribution() async throws {
        let cli = InstallationCLIProbe(result: .success(CLIResult(
            exitCode: 0,
            stdout: "removed\n",
            stderr: "",
            timedOut: false)))
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            distribution: InstallationDistributionProbe(),
            watchdog: watchdog,
            powerHelper: powerHelper,
            cli: cli)
        defer { fixture.cleanup() }

        await fixture.store.uninstall(purgeState: true)

        XCTAssertEqual(fixture.store.phase, .actionRequired)
        XCTAssertEqual(fixture.store.lastInstallMessage, "removed")
        XCTAssertFalse(fixture.store.distributionMatchesBundle)
        XCTAssertEqual(watchdog.disableCallCount, 1)
        XCTAssertEqual(powerHelper.disableCallCount, 1)
        let calls = await cli.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments), [["uninstall", "--purge-state"]])
        XCTAssertEqual(calls.map(\.timeout), [30])
    }

    func testFailedUninstallRestoresPreviouslyEnabledServices()
        async throws
    {
        let cli = InstallationCLIProbe(result: .success(CLIResult(
            exitCode: 17,
            stdout: "",
            stderr: "cannot remove runtime\n",
            timedOut: false)))
        let watchdog = InstallationWatchdogProbe(status: .enabled)
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            distribution: InstallationDistributionProbe(),
            watchdog: watchdog,
            powerHelper: powerHelper,
            cli: cli)
        defer { fixture.cleanup() }

        await fixture.store.uninstall(purgeState: false)

        XCTAssertEqual(
            fixture.store.phase,
            .failed("Could not remove components: cannot remove runtime"))
        XCTAssertEqual(watchdog.enableCallCount, 1)
        XCTAssertEqual(powerHelper.enableCallCount, 1)
        XCTAssertEqual(watchdog.status, .enabled)
        XCTAssertEqual(powerHelper.status, .enabled)
        let calls = await cli.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments), [["uninstall", "--keep-state"]])
    }

    func testIdleRefreshBootstrapsPackagedPayload() async throws {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed from refresh")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: InstallationWatchdogProbe(status: .enabled),
            powerHelper: InstallationPowerHelperProbe(status: .enabled))
        defer { fixture.cleanup() }

        let refreshed = await fixture.store.refreshContext()

        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.store.phase, .ready)
        XCTAssertEqual(distribution.repairs, [false])
    }

    func testRefreshDefersHelperReplacementWhileActiveLeasesRemain()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            completedOnboarding: true,
            distribution: distribution,
            watchdog: InstallationWatchdogProbe(status: .enabled),
            powerHelper: powerHelper)
        defer { fixture.cleanup() }
        await fixture.store.bootstrap()
        powerHelper.reconcileResult = .success(.deferredForActiveLeases)

        let refreshed = await fixture.store.refreshContext()

        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.store.phase, .updateDeferred)
        XCTAssertEqual(fixture.store.onboardingStep, .mainApp)
    }

    func testDeferredRefreshDoctorFailureWithdrawsStaleReadiness()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
                .failure(InstallationProbeError.doctor),
            ])
        let powerHelper = InstallationPowerHelperProbe(status: .enabled)
        let fixture = try makePackagedInstallationFixture(
            completedOnboarding: true,
            distribution: distribution,
            watchdog: InstallationWatchdogProbe(status: .enabled),
            powerHelper: powerHelper)
        defer { fixture.cleanup() }
        await fixture.store.bootstrap()
        XCTAssertTrue(fixture.store.powerHelperReadinessConfirmed)
        powerHelper.reconcileResult = .success(.deferredForActiveLeases)

        let refreshed = await fixture.store.refreshContext()

        XCTAssertTrue(refreshed)
        XCTAssertEqual(fixture.store.phase, .updateDeferred)
        XCTAssertFalse(fixture.store.powerHelperReadinessConfirmed)
    }

    func testBootstrapPublishesBothServiceReconciliationFailures()
        async throws
    {
        let distribution = InstallationDistributionProbe(
            synchronizeResults: [.success("installed")],
            doctorResults: [
                .success(installedRuntimeReport()),
                .success(installedRuntimeReport()),
            ])
        let watchdog = InstallationWatchdogProbe(
            status: .notRegistered,
            reconcileResult: .failure(InstallationProbeError.watchdog))
        let powerHelper = InstallationPowerHelperProbe(
            status: .enabled,
            reconcileResult: .failure(InstallationProbeError.powerHelper))
        let fixture = try makePackagedInstallationFixture(
            distribution: distribution,
            watchdog: watchdog,
            powerHelper: powerHelper)
        defer { fixture.cleanup() }

        await fixture.store.bootstrap()

        XCTAssertEqual(fixture.store.phase, .actionRequired)
        XCTAssertEqual(
            fixture.store.powerHelperError, "power helper probe failed")
        XCTAssertEqual(fixture.store.watchdogError, "watchdog probe failed")
        XCTAssertFalse(fixture.store.powerHelperReadinessConfirmed)
    }

    private func makeStateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTestAppBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Detach-\(UUID().uuidString).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let payload = contents.appendingPathComponent(
            "Resources/DetachCLI", isDirectory: true)
        try FileManager.default.createDirectory(
            at: payload, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>dev.tsarev.detach.coverage-fixture</string>
        <key>CFBundleName</key><string>Detach</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(
            to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        for (name, value) in [
            ("VERSION", "0.2.7\n"),
            ("BUILD", "17\n"),
            ("PAYLOAD_ID", "payload\n"),
        ] {
            try Data(value.utf8).write(
                to: payload.appendingPathComponent(name), options: .atomic)
        }
        return root
    }

    private func doctorReport(
        powerHelperStatus: DiagnosticCheck.Status
    ) -> DoctorReport {
        DoctorReport(
            schema: 1,
            version: "0.2.7",
            build: "17",
            payloadID: "payload",
            ok: powerHelperStatus == .ok,
            checks: [DiagnosticCheck(
                id: "power_helper",
                section: .base,
                label: "Detach power helper",
                required: true,
                status: powerHelperStatus,
                path: "/tmp/detach-power",
                summary: "power helper")])
    }

    private func installedRuntimeReport(build: String = "17") -> DoctorReport {
        let ids = [
            "integrity", "cli", "manifest", "tmux", "state_helper",
            "power_runtime", "power_helper", "provider",
        ]
        return DoctorReport(
            schema: 1,
            version: "0.2.7",
            build: build,
            payloadID: "payload",
            ok: true,
            checks: ids.map { id in
                DiagnosticCheck(
                    id: id,
                    section: .base,
                    label: id,
                    required: true,
                    status: .ok,
                    path: "/tmp/\(id)",
                    summary: "ok")
            })
    }

    private func makePackagedInstallationFixture(
        completedOnboarding: Bool = false,
        distribution: InstallationDistributionProbe,
        watchdog: InstallationWatchdogProbe,
        powerHelper: InstallationPowerHelperProbe,
        applicationLocationValidator: @escaping @MainActor (URL) -> Bool = { _ in true },
        cli: InstallationCLIProbe = InstallationCLIProbe(result: .success(
            CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)))
    ) throws -> PackagedInstallationFixture {
        let bundleRoot = try makeTestAppBundle()
        let stateRoot = try makeStateRoot()
        let bundle = try XCTUnwrap(Bundle(path: bundleRoot.path))
        let suite = "InstallationStorePowerStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(completedOnboarding, forKey: "onboardingCompleted")
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            bundle: bundle,
            powerStateRoot: stateRoot,
            defaults: defaults,
            watchdog: watchdog,
            powerHelper: powerHelper,
            applicationLocationValidator: applicationLocationValidator,
            distributionClientFactory: { _, _, _, _ in distribution },
            cliFactory: { _ in cli })
        return PackagedInstallationFixture(
            store: store,
            bundleRoot: bundleRoot,
            stateRoot: stateRoot,
            defaults: defaults,
            suite: suite)
    }

    private func makeCompletedOnboardingStore(
        contextOperationOverride:
            (@MainActor (InstallationContextOperation) async -> Void)? = nil
    ) -> CompletedOnboardingFixture {
        let suite = "InstallationStorePowerStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "onboardingCompleted")
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            defaults: defaults,
            contextOperationOverride: contextOperationOverride)
        return CompletedOnboardingFixture(
            store: store, defaults: defaults, suite: suite)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }

    @discardableResult
    private func writeHeartbeat(_ body: String, to root: URL) throws -> URL {
        let url = root.appendingPathComponent("watchdog-status.json")
        try Data(body.utf8).write(to: url, options: .atomic)
        return url
    }

    private func stamp(offset: TimeInterval = 0) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
    }
}

@MainActor
private struct CompletedOnboardingFixture {
    let store: InstallationStore
    let defaults: UserDefaults
    let suite: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class InstallationContextOperationProbe {
    private(set) var operations: [InstallationContextOperation] = []
    private(set) var maximumConcurrentOperations = 0
    private var activeOperations = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: InstallationContextOperation) async {
        operations.append(operation)
        activeOperations += 1
        maximumConcurrentOperations = max(
            maximumConcurrentOperations, activeOperations)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        activeOperations -= 1
    }

    func releaseNext() {
        continuations.removeFirst().resume()
    }
}

private enum InstallationProbeError: LocalizedError {
    case watchdog
    case powerHelper
    case doctor

    var errorDescription: String? {
        switch self {
        case .watchdog: "watchdog probe failed"
        case .powerHelper: "power helper probe failed"
        case .doctor: "doctor probe failed"
        }
    }
}

@MainActor
private final class InstallationWatchdogProbe:
    InstallationWatchdogServicing
{
    var status: WatchdogStatus
    var reconcileResult: Result<Void, Error>
    private(set) var forceReplacementRequests: [Bool] = []
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        status: WatchdogStatus,
        reconcileResult: Result<Void, Error> = .success(())
    ) {
        self.status = status
        self.reconcileResult = reconcileResult
    }

    func reconcileAfterAppUpdate(forceReplacement: Bool) async throws {
        forceReplacementRequests.append(forceReplacement)
        try reconcileResult.get()
    }

    func enable() async throws {
        enableCallCount += 1
        status = .enabled
    }

    func disable() async throws {
        disableCallCount += 1
        status = .notRegistered
    }

    func openLoginItemsSettings() {
        openSettingsCallCount += 1
    }
}

@MainActor
private final class InstallationPowerHelperProbe:
    InstallationPowerHelperServicing
{
    var status: PowerHelperRegistrationStatus
    var reconcileResult: Result<PowerHelperReconciliationOutcome, Error>
    private(set) var reconcileCallCount = 0
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        status: PowerHelperRegistrationStatus,
        reconcileResult: Result<PowerHelperReconciliationOutcome, Error> =
            .success(.complete)
    ) {
        self.status = status
        self.reconcileResult = reconcileResult
    }

    func reconcileAfterAppUpdate() async throws
        -> PowerHelperReconciliationOutcome
    {
        reconcileCallCount += 1
        return try reconcileResult.get()
    }

    func enable() async throws {
        enableCallCount += 1
        status = .enabled
    }

    func disable() async throws {
        disableCallCount += 1
        status = .notRegistered
    }

    func openApprovalSettings() {
        openSettingsCallCount += 1
    }
}

@MainActor
private final class InstallationDistributionProbe:
    InstallationDistributionServicing
{
    var synchronizeResults: [Result<String, Error>]
    var doctorResults: [Result<DoctorReport, Error>]
    private(set) var repairs: [Bool] = []
    private(set) var doctorCallCount = 0

    init(
        synchronizeResults: [Result<String, Error>] = [],
        doctorResults: [Result<DoctorReport, Error>] = []
    ) {
        self.synchronizeResults = synchronizeResults
        self.doctorResults = doctorResults
    }

    func synchronize(repair: Bool) async throws -> String {
        repairs.append(repair)
        return try synchronizeResults.removeFirst().get()
    }

    func doctor() async throws -> DoctorReport {
        doctorCallCount += 1
        return try doctorResults.removeFirst().get()
    }
}

private actor InstallationCLIProbe: DetachCLIRunning {
    struct Call: Sendable {
        let arguments: [String]
        let timeout: TimeInterval
    }

    let result: Result<CLIResult, Error>
    private var calls: [Call] = []

    init(result: Result<CLIResult, Error>) {
        self.result = result
    }

    func run(arguments: [String], timeout: TimeInterval) async throws
        -> CLIResult
    {
        calls.append(Call(arguments: arguments, timeout: timeout))
        return try result.get()
    }

    func recordedCalls() -> [Call] { calls }
}

@MainActor
private struct PackagedInstallationFixture {
    let store: InstallationStore
    let bundleRoot: URL
    let stateRoot: URL
    let defaults: UserDefaults
    let suite: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: bundleRoot)
        try? FileManager.default.removeItem(at: stateRoot)
    }
}
