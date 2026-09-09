import DetachKit
import Foundation
import XCTest
@testable import DetachApp

@MainActor
final class OnboardingLivePollerTests: XCTestCase {
    func testProductionWiringConstructsAnIdlePoller() async throws {
        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            watchdog: PollerWatchdogStub(),
            powerHelper: PollerPowerHelperStub())
        let poller = OnboardingLivePoller(store: store)

        XCTAssertEqual(poller.providerAvailability, ProviderAvailability())
        XCTAssertFalse(poller.heartbeatHealthy)
        XCTAssertFalse(poller.installedCopyPresent)

        await poller.tick(.permissions)
        await poller.tick(.moveToApplications)
        try await OnboardingLivePoller.defaultSleep(nanoseconds: 0)
    }

    func testEnableTransitionTriggersExactlyOneReconcile() async {
        var enabled = false
        var confirmed = false
        var reconciles = 0
        let poller = makePoller(
            servicesEnabled: { enabled },
            readinessConfirmed: { confirmed },
            reconcile: {
                reconciles += 1
                confirmed = true
                return true
            })

        await poller.tick(.permissions)
        XCTAssertEqual(reconciles, 0)

        enabled = true
        await poller.tick(.permissions)
        XCTAssertEqual(reconciles, 1)

        await poller.tick(.permissions)
        await poller.tick(.permissions)
        XCTAssertEqual(reconciles, 1)
    }

    func testFailedReconcileDoesNotLoopButRearmsAfterRegression() async {
        var enabled = true
        var reconciles = 0
        let poller = makePoller(
            servicesEnabled: { enabled },
            readinessConfirmed: { false },
            reconcile: {
                reconciles += 1
                return true
            })

        await poller.tick(.permissions)
        XCTAssertEqual(reconciles, 1)
        // Still enabled but unconfirmed: no silent retry loop.
        await poller.tick(.permissions)
        XCTAssertEqual(reconciles, 1)

        // Status regressed and recovered: the next transition reconciles once.
        enabled = false
        await poller.tick(.permissions)
        enabled = true
        await poller.tick(.permissions)
        XCTAssertEqual(reconciles, 2)
    }

    func testProviderAppearanceTriggersSingleRefresh() async {
        var available = ProviderAvailability()
        var checkPassed = false
        var reconciles = 0
        let poller = makePoller(
            providerCheckPassed: { checkPassed },
            reconcile: {
                reconciles += 1
                checkPassed = true
                return true
            },
            locate: { available })

        await poller.tick(.provider)
        XCTAssertEqual(reconciles, 0)
        XCTAssertFalse(poller.providerAvailability.any)

        available.claude = true
        await poller.tick(.provider)
        XCTAssertEqual(reconciles, 1)
        XCTAssertTrue(poller.providerAvailability.claude)

        await poller.tick(.provider)
        XCTAssertEqual(reconciles, 1)
    }

    func testRejectedPermissionReconcileIsRetriedOnNextTick() async {
        var reconciles = 0
        let poller = makePoller(
            servicesEnabled: { true },
            readinessConfirmed: { false },
            reconcile: {
                reconciles += 1
                return reconciles > 1
            })

        await poller.tick(.permissions)
        await poller.tick(.permissions)
        await poller.tick(.permissions)

        XCTAssertEqual(reconciles, 2)
    }

    func testDoneTickUsesTheDefaultRefreshWhenNoneIsProvided() async {
        let poller = OnboardingLivePoller(
            refreshStatuses: {},
            servicesEnabled: { false },
            readinessConfirmed: { false },
            providerCheckPassed: { false },
            reconcile: { true },
            locate: { ProviderAvailability() },
            heartbeatIsHealthy: { true },
            installedCopyExists: { false })

        await poller.tick(.done)
        XCTAssertTrue(poller.heartbeatHealthy)
        XCTAssertFalse(poller.heartbeatWaitIsLong)
    }

    func testHeartbeatGatePublishesHealth() async {
        var healthy = false
        let poller = makePoller(heartbeatIsHealthy: { healthy })

        await poller.tick(.done)
        XCTAssertFalse(poller.heartbeatHealthy)

        healthy = true
        await poller.tick(.done)
        XCTAssertTrue(poller.heartbeatHealthy)
        XCTAssertFalse(poller.heartbeatWaitIsLong)
    }

    func testDoneTickRereadsHeartbeatFileWithoutMenuBarTimer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-onboarding-heartbeat-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InstallationStore(
            detachPath: "/tmp/detach-test",
            powerStateRoot: root)
        let poller = OnboardingLivePoller(store: store)

        await poller.tick(.done)
        XCTAssertFalse(poller.heartbeatHealthy)
        XCTAssertFalse(store.watchdogHeartbeat.healthy)

        let stamp = ISO8601DateFormatter().string(from: Date())
        try Data(
            #"{"state":"ok","power_state":"protected","checked_at":"\#(stamp)"}"#
                .utf8
        ).write(
            to: root.appendingPathComponent("watchdog-status.json"),
            options: .atomic)
        XCTAssertFalse(store.watchdogHeartbeat.healthy)

        await poller.tick(.done)
        XCTAssertTrue(store.watchdogHeartbeat.healthy)
        XCTAssertTrue(poller.heartbeatHealthy)
        XCTAssertFalse(poller.heartbeatWaitIsLong)
    }

    func testInstalledCopyDetectionPublishes() async {
        var present = false
        let poller = makePoller(installedCopyExists: { present })

        await poller.tick(.moveToApplications)
        XCTAssertFalse(poller.installedCopyPresent)

        present = true
        await poller.tick(.moveToApplications)
        XCTAssertTrue(poller.installedCopyPresent)
    }

    func testUpdateRunsEachSupportedStepAtItsContractCadence() async {
        let sleeps = PollSleepRecorder()
        var statusRefreshes = 0
        let poller = makePoller(
            refreshStatuses: { statusRefreshes += 1 },
            providerCheckPassed: { true },
            locate: { ProviderAvailability(codex: true, claude: false) },
            heartbeatIsHealthy: { true },
            installedCopyExists: { true },
            sleep: { try await sleeps.recordAndStop($0) })

        poller.update(for: .moveToApplications)
        await waitUntil { await sleeps.count == 1 }
        XCTAssertTrue(poller.installedCopyPresent)

        poller.update(for: .permissions)
        await waitUntil { await sleeps.count == 2 }
        XCTAssertEqual(statusRefreshes, 1)

        poller.update(for: .provider)
        await waitUntil { await sleeps.count == 3 }
        XCTAssertEqual(poller.providerAvailability, .init(codex: true, claude: false))

        poller.update(for: .done)
        await waitUntil { await sleeps.count == 4 }
        XCTAssertTrue(poller.heartbeatHealthy)

        let intervals = await sleeps.intervals
        XCTAssertEqual(
            intervals,
            [3_000_000_000, 3_000_000_000, 5_000_000_000, 2_000_000_000])
    }

    func testRunLoopRepeatsAndExitsAfterTaskCancellation() async {
        var intervals: [UInt64] = []
        var detections = 0
        let poller = makePoller(
            installedCopyExists: {
                detections += 1
                return true
            },
            sleep: { interval in
                intervals.append(interval)
                if intervals.count == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })

        await poller.run(.moveToApplications, interval: 3_000_000_000)

        XCTAssertEqual(detections, 2)
        XCTAssertEqual(intervals, [3_000_000_000, 3_000_000_000])
    }

    func testUpdateIsIdempotentAndStopRearmsTheSameStep() async {
        let sleeps = PollSleepRecorder()
        let poller = makePoller(
            installedCopyExists: { true },
            sleep: { try await sleeps.recordAndStop($0) })

        poller.update(for: .moveToApplications)
        await waitUntil { await sleeps.count == 1 }
        poller.update(for: .moveToApplications)
        let countAfterDuplicate = await sleeps.count
        XCTAssertEqual(countAfterDuplicate, 1)

        poller.stop()
        poller.update(for: .moveToApplications)
        await waitUntil { await sleeps.count == 2 }

        poller.update(for: .autoSetup(failureMessage: nil))
        poller.update(for: .mainApp)
        let countAfterInactiveSteps = await sleeps.count
        XCTAssertEqual(countAfterInactiveSteps, 2)

        await poller.tick(.autoSetup(failureMessage: "ignored"))
        await poller.tick(.mainApp)
    }

    private func makePoller(
        refreshStatuses: @escaping @MainActor () -> Void = {},
        servicesEnabled: @escaping @MainActor () -> Bool = { false },
        readinessConfirmed: @escaping @MainActor () -> Bool = { false },
        providerCheckPassed: @escaping @MainActor () -> Bool = { false },
        reconcile: @escaping @MainActor () async -> Bool = { true },
        locate: @escaping () async -> ProviderAvailability = {
            ProviderAvailability()
        },
        refreshHeartbeat: @escaping @MainActor () -> Void = {},
        heartbeatIsHealthy: @escaping @MainActor () -> Bool = { false },
        installedCopyExists: @escaping () -> Bool = { false },
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) -> OnboardingLivePoller {
        OnboardingLivePoller(
            refreshStatuses: refreshStatuses,
            servicesEnabled: servicesEnabled,
            readinessConfirmed: readinessConfirmed,
            providerCheckPassed: providerCheckPassed,
            reconcile: reconcile,
            locate: locate,
            refreshHeartbeat: refreshHeartbeat,
            heartbeatIsHealthy: heartbeatIsHealthy,
            installedCopyExists: installedCopyExists,
            sleep: sleep)
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("asynchronous poller condition was not reached")
    }
}

private actor PollSleepRecorder {
    private(set) var intervals: [UInt64] = []
    var count: Int { intervals.count }

    func recordAndStop(_ interval: UInt64) throws {
        intervals.append(interval)
        throw CancellationError()
    }
}

@MainActor
private final class PollerWatchdogStub: InstallationWatchdogServicing {
    var status: WatchdogStatus = .notRegistered

    func reconcileAfterAppUpdate(forceReplacement: Bool) async throws {}
    func enable() async throws {}
    func disable() async throws {}
    func openLoginItemsSettings() {}
}

@MainActor
private final class PollerPowerHelperStub: InstallationPowerHelperServicing {
    var status: PowerHelperRegistrationStatus = .notRegistered

    func reconcileAfterAppUpdate() async throws -> PowerHelperReconciliationOutcome {
        .complete
    }
    func enable() async throws {}
    func disable() async throws {}
    func openApprovalSettings() {}
}

final class OnboardingProviderLocatorTests: XCTestCase {
    private actor ShellStub: DetachCLIRunning {
        private var results: [String: CLIResult] = [:]
        private var recordedScripts: [String] = []

        func set(_ name: String, _ result: CLIResult) {
            results[name] = result
        }

        var scripts: [String] {
            recordedScripts
        }

        func run(
            arguments: [String], timeout: TimeInterval
        ) async throws -> CLIResult {
            let script = arguments.last ?? ""
            recordedScripts.append(script)
            guard arguments.first == "-lc" else {
                return CLIResult(
                    exitCode: 64, stdout: "", stderr: "", timedOut: false)
            }
            for (name, result) in results
            where script.contains("command -v \(name) ") {
                return result
            }
            return CLIResult(
                exitCode: 127, stdout: "", stderr: "", timedOut: false)
        }
    }

    func testProbesLoginShellAndRequiresVersionSuccess() async {
        let stub = ShellStub()
        await stub.set("codex", CLIResult(
            exitCode: 0, stdout: "", stderr: "", timedOut: false))
        await stub.set("claude", CLIResult(
            exitCode: 1, stdout: "", stderr: "", timedOut: false))
        let locator = OnboardingProviderLocator(runner: stub)

        let availability = await locator.locate()

        XCTAssertTrue(availability.codex)
        XCTAssertFalse(availability.claude)
        XCTAssertTrue(availability.any)
        let scripts = await stub.scripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.allSatisfy { $0.contains("--version") })
    }

    func testTimedOutProbeCountsAsAbsent() async {
        let stub = ShellStub()
        await stub.set("codex", CLIResult(
            exitCode: 0, stdout: "", stderr: "", timedOut: true))
        let locator = OnboardingProviderLocator(runner: stub)

        let availability = await locator.locate()

        XCTAssertFalse(availability.codex)
        XCTAssertFalse(availability.any)
    }
}
