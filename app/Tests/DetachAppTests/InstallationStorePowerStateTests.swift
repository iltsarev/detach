import DetachKit
import Foundation
import Observation
import XCTest
@testable import DetachApp

@MainActor
final class InstallationStorePowerStateTests: XCTestCase {
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

    private func makeStateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
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

    private func installedRuntimeReport() -> DoctorReport {
        let ids = [
            "integrity", "cli", "manifest", "tmux", "state_helper",
            "power_runtime",
        ]
        return DoctorReport(
            schema: 1,
            version: "0.2.7",
            build: "17",
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
