import XCTest
@testable import DetachKit

final class PowerProtectionTests: XCTestCase {
    private final class FakeClosedLidBackend: ClosedLidProtectionControlling {
        var enabled: Bool
        var writes: [Bool] = []
        var failure: Error?
        var writeFailure: Error?
        var readFailures: [Int: Error] = [:]
        private(set) var readCount = 0

        init(enabled: Bool) {
            self.enabled = enabled
        }

        func protectionIsEnabled() throws -> Bool {
            readCount += 1
            if let failure = readFailures[readCount] { throw failure }
            if let failure { throw failure }
            return enabled
        }

        func setProtectionEnabled(_ enabled: Bool) throws {
            if let writeFailure { throw writeFailure }
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

    func testStatusInitializerNormalizesNegativeLeaseCount() {
        let status = PowerProtectionStatus(
            state: .protected,
            leaseCount: -10,
            assertionActive: true,
            closedLidProtectionActive: true,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false)

        XCTAssertEqual(status.leaseCount, 0)
        XCTAssertEqual(status.state, .protected)
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

    func testInvalidLeaseTimingPolicyFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now)

        XCTAssertTrue(PowerLeaseRegistry.liveLeases(
            [lease], now: now, timeout: -1).isEmpty)
        XCTAssertTrue(PowerLeaseRegistry.liveLeases(
            [lease], now: now, timeout: 60,
            maximumFutureClockSkew: -1).isEmpty)
    }

    func testLeaseDecodingDefaultsLegacyAssertionAndAcceptsCurrentField() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacyJSON = #"{"id":"legacy","session_name":"session","run_token":"run","renewed_at":100}"#
        let currentJSON = #"{"id":"current","session_name":"session","run_token":"run","renewed_at":100,"assertion_active":true}"#
        let legacy = try decoder.decode(
            PowerLease.self, from: Data(legacyJSON.utf8))
        let current = try decoder.decode(
            PowerLease.self, from: Data(currentJSON.utf8))

        XCTAssertFalse(legacy.assertionActive)
        XCTAssertTrue(current.assertionActive)
        XCTAssertEqual(legacy.renewedAt, Date(timeIntervalSince1970: 100))
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

    func testCoordinatorHonorsExpiredAcquireDeadlineBeforeGlobalMutation() {
        let backend = FakeClosedLidBackend(enabled: false)
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)
        var deadlineChecks = 0

        let status = coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: false, backend: backend,
            allowEnablingProtection: {
                deadlineChecks += 1
                return false
            })

        XCTAssertEqual(status.state, .transitioning)
        XCTAssertEqual(deadlineChecks, 1)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertFalse(coordinator.ownsClosedLidProtection)
    }

    func testVerificationFailureAfterEnableRetainsOwnershipForLaterRestore() {
        struct ExpectedFailure: Error {}
        let backend = FakeClosedLidBackend(enabled: false)
        backend.readFailures[2] = ExpectedFailure()
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let lease = PowerLease(
            id: "lease", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)

        let failed = coordinator.reconcile(
            leases: [lease], now: now, timeout: 60,
            lowBattery: false, backend: backend)

        XCTAssertEqual(failed.state, .unavailable)
        XCTAssertFalse(failed.helperReachable)
        XCTAssertTrue(coordinator.ownsClosedLidProtection)
        XCTAssertEqual(backend.writes, [true])

        let restored = coordinator.reconcile(
            leases: [], now: now, timeout: 60,
            lowBattery: false, backend: backend)
        XCTAssertEqual(restored.state, .allowed)
        XCTAssertFalse(coordinator.ownsClosedLidProtection)
        XCTAssertEqual(backend.writes, [true, false])
    }

    func testCoordinatorClearsStaleOwnershipWhenSettingIsAlreadyOff() {
        let backend = FakeClosedLidBackend(enabled: false)
        var coordinator = PowerProtectionCoordinator(
            ownsClosedLidProtection: true)

        let status = coordinator.reconcile(
            leases: [], now: Date(timeIntervalSince1970: 1_000), timeout: 60,
            lowBattery: false, backend: backend)

        XCTAssertEqual(status.state, .allowed)
        XCTAssertFalse(coordinator.ownsClosedLidProtection)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testFailedOwnedRestoreRemainsUnavailableAndOwnedForRetry() {
        struct ExpectedFailure: Error {}
        let backend = FakeClosedLidBackend(enabled: true)
        backend.writeFailure = ExpectedFailure()
        var coordinator = PowerProtectionCoordinator(
            ownsClosedLidProtection: true)

        let status = coordinator.reconcile(
            leases: [], now: Date(timeIntervalSince1970: 1_000), timeout: 60,
            lowBattery: false, backend: backend)

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertFalse(status.helperReachable)
        XCTAssertTrue(coordinator.ownsClosedLidProtection)
    }

    func testMixedAssertionEvidenceCannotClaimFullProtection() {
        let backend = FakeClosedLidBackend(enabled: true)
        var coordinator = PowerProtectionCoordinator()
        let now = Date(timeIntervalSince1970: 1_000)
        let leases = [
            PowerLease(
                id: "active", sessionName: "one", runToken: "one",
                renewedAt: now, assertionActive: true),
            PowerLease(
                id: "inactive", sessionName: "two", runToken: "two",
                renewedAt: now, assertionActive: false),
        ]

        let status = coordinator.reconcile(
            leases: leases, now: now, timeout: 60,
            lowBattery: false, backend: backend)

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertFalse(status.assertionActive)
        XCTAssertEqual(status.leaseCount, 2)
    }
}
