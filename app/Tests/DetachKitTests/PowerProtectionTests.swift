import XCTest
@testable import DetachKit

final class PowerProtectionTests: XCTestCase {
    private final class FakeClosedLidBackend: ClosedLidProtectionControlling {
        var enabled: Bool
        var writes: [Bool] = []
        var failure: Error?

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func protectionIsEnabled() throws -> Bool {
            if let failure { throw failure }
            return enabled
        }

        func setProtectionEnabled(_ enabled: Bool) throws {
            if let failure { throw failure }
            self.enabled = enabled
            writes.append(enabled)
        }
    }

    func testProtectedRequiresBothAssertionAndClosedLidProtection() {
        XCTAssertEqual(PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: true,
            closedLidProtectionActive: true,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false).state, .protected)

        XCTAssertEqual(PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: true,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false).state, .unavailable)
    }

    func testNoLeasesMeansNormalSleepIsAllowed() {
        let status = PowerProtectionStatus.derive(
            leaseCount: 0,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false)

        XCTAssertEqual(status.state, .allowed)
        XCTAssertEqual(status.leaseCount, 0)
    }

    func testNoLeasesStillReportsBorrowedMachineProtectionTruthfully() {
        let status = PowerProtectionStatus.derive(
            leaseCount: 0,
            assertionActive: false,
            closedLidProtectionActive: true,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false)

        XCTAssertEqual(status.state, .protected)
    }

    func testUnreachableHelperNeverClaimsSleepIsAllowed() {
        let status = PowerProtectionStatus.derive(
            leaseCount: 0,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: false,
            transitionInProgress: false,
            lowBattery: false)

        XCTAssertEqual(status.state, .unavailable)
    }

    func testLowBatteryTakesPrecedenceOverAnIncompleteTransition() {
        XCTAssertEqual(PowerProtectionStatus.derive(
            leaseCount: 2,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: true,
            lowBattery: true).state, .lowBattery)
    }

    func testLowBatteryDoesNotClaimSleepWhenBorrowedProtectionRemains() {
        XCTAssertEqual(PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: true,
            closedLidProtectionActive: true,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: true).state, .unavailable)
    }

    func testLowBatteryDoesNotClaimSleepUntilIdleAssertionIsReleased() {
        XCTAssertEqual(PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: true,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: true).state, .unavailable)
    }

    func testTransitionIsShownUntilBothProtectionsAreVerified() {
        XCTAssertEqual(PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: true,
            lowBattery: false).state, .transitioning)
    }

    func testStaleLeasesExpireAndLiveLeasesRemain() {
        let now = Date(timeIntervalSince1970: 1_000)
        let leases = [
            PowerLease(id: "live", sessionName: "s1", runToken: "r1",
                       renewedAt: now.addingTimeInterval(-20)),
            PowerLease(id: "stale", sessionName: "s2", runToken: "r2",
                       renewedAt: now.addingTimeInterval(-61)),
        ]

        XCTAssertEqual(
            PowerLeaseRegistry.liveLeases(leases, now: now, timeout: 60).map(\.id),
            ["live"])
    }

    func testFarFutureLeasesExpireButSmallClockCorrectionsSurvive() {
        let now = Date(timeIntervalSince1970: 1_000)
        let leases = [
            PowerLease(id: "near", sessionName: "s1", runToken: "r1",
                       renewedAt: now.addingTimeInterval(60)),
            PowerLease(id: "far", sessionName: "s2", runToken: "r2",
                       renewedAt: now.addingTimeInterval(301)),
        ]

        XCTAssertEqual(
            PowerLeaseRegistry.liveLeases(
                leases, now: now, timeout: 60,
                maximumFutureClockSkew: 300).map(\.id),
            ["near"])
    }

    func testPowerStateDecodesUnknownValuesSafely() throws {
        let known = try JSONDecoder().decode(
            PowerProtectionState.self, from: Data(#""protected""#.utf8))
        let future = try JSONDecoder().decode(
            PowerProtectionState.self, from: Data(#""future-state""#.utf8))

        XCTAssertEqual(known, .protected)
        XCTAssertEqual(future, .unknown)
    }

    func testCoordinatorOwnsAndRestoresClosedLidProtection() {
        let backend = FakeClosedLidBackend(enabled: false)
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)

        let active = coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: false, backend: backend)
        let released = coordinator.reconcile(
            leases: [], now: now, timeout: 60,
            lowBattery: false, backend: backend)

        XCTAssertEqual(active.state, .protected)
        XCTAssertEqual(released.state, .allowed)
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(coordinator.ownsClosedLidProtection)
    }

    func testCoordinatorBorrowsPreexistingProtectionWithoutDisablingIt() {
        let backend = FakeClosedLidBackend(enabled: true)
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)

        XCTAssertEqual(coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: false, backend: backend).state, .protected)
        XCTAssertEqual(coordinator.reconcile(
            leases: [], now: now, timeout: 60,
            lowBattery: false, backend: backend).state, .protected)

        XCTAssertTrue(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testCoordinatorDropsOwnedProtectionAtLowBattery() {
        let backend = FakeClosedLidBackend(enabled: false)
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)

        _ = coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: false, backend: backend)
        let releasingAssertion = coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: true, backend: backend)
        let releasedLease = PowerLease(
            id: lease.id, sessionName: lease.sessionName,
            runToken: lease.runToken, renewedAt: lease.renewedAt,
            assertionActive: false)
        let lowBattery = coordinator.reconcile(
            leases: [releasedLease], now: now, timeout: 60,
            lowBattery: true, backend: backend)

        XCTAssertEqual(releasingAssertion.state, .unavailable)
        XCTAssertTrue(releasingAssertion.lowBattery)
        XCTAssertEqual(lowBattery.state, .lowBattery)
        XCTAssertEqual(backend.writes, [true, false])
    }

    func testCoordinatorReportsBackendFailureInsteadOfClaimingProtection() {
        struct ExpectedFailure: Error {}
        let backend = FakeClosedLidBackend(enabled: false)
        backend.failure = ExpectedFailure()
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)

        let status = coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: false, backend: backend)

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertFalse(status.helperReachable)
    }
}
