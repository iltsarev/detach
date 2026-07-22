import DetachKit
import Foundation
import Observation
import XCTest
@testable import DetachApp

@MainActor
final class InstallationStorePowerStateTests: XCTestCase {
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
