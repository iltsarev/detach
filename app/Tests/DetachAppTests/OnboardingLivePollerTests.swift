import DetachKit
import Foundation
import XCTest
@testable import DetachApp

@MainActor
final class OnboardingLivePollerTests: XCTestCase {
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
            reconcile: { reconciles += 1 })

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

    func testInstalledCopyDetectionPublishes() async {
        var present = false
        let poller = makePoller(installedCopyExists: { present })

        await poller.tick(.moveToApplications)
        XCTAssertFalse(poller.installedCopyPresent)

        present = true
        await poller.tick(.moveToApplications)
        XCTAssertTrue(poller.installedCopyPresent)
    }

    private func makePoller(
        refreshStatuses: @escaping @MainActor () -> Void = {},
        servicesEnabled: @escaping @MainActor () -> Bool = { false },
        readinessConfirmed: @escaping @MainActor () -> Bool = { false },
        providerCheckPassed: @escaping @MainActor () -> Bool = { false },
        reconcile: @escaping @MainActor () async -> Void = {},
        locate: @escaping () async -> ProviderAvailability = {
            ProviderAvailability()
        },
        heartbeatIsHealthy: @escaping @MainActor () -> Bool = { false },
        installedCopyExists: @escaping () -> Bool = { false }
    ) -> OnboardingLivePoller {
        OnboardingLivePoller(
            refreshStatuses: refreshStatuses,
            servicesEnabled: servicesEnabled,
            readinessConfirmed: readinessConfirmed,
            providerCheckPassed: providerCheckPassed,
            reconcile: reconcile,
            locate: locate,
            heartbeatIsHealthy: heartbeatIsHealthy,
            installedCopyExists: installedCopyExists)
    }
}

final class OnboardingProviderLocatorTests: XCTestCase {
    private final class ShellStub: DetachCLIRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: CLIResult] = [:]
        private var recordedScripts: [String] = []

        func set(_ name: String, _ result: CLIResult) {
            lock.lock()
            defer { lock.unlock() }
            results[name] = result
        }

        var scripts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedScripts
        }

        func run(
            arguments: [String], timeout: TimeInterval
        ) async throws -> CLIResult {
            lock.lock()
            defer { lock.unlock() }
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
        stub.set("codex", CLIResult(
            exitCode: 0, stdout: "", stderr: "", timedOut: false))
        stub.set("claude", CLIResult(
            exitCode: 1, stdout: "", stderr: "", timedOut: false))
        let locator = OnboardingProviderLocator(runner: stub)

        let availability = await locator.locate()

        XCTAssertTrue(availability.codex)
        XCTAssertFalse(availability.claude)
        XCTAssertTrue(availability.any)
        XCTAssertEqual(stub.scripts.count, 2)
        XCTAssertTrue(stub.scripts.allSatisfy { $0.contains("--version") })
    }

    func testTimedOutProbeCountsAsAbsent() async {
        let stub = ShellStub()
        stub.set("codex", CLIResult(
            exitCode: 0, stdout: "", stderr: "", timedOut: true))
        let locator = OnboardingProviderLocator(runner: stub)

        let availability = await locator.locate()

        XCTAssertFalse(availability.codex)
        XCTAssertFalse(availability.any)
    }
}
