import XCTest
@testable import DetachKit

final class PowerHelperLeaseServiceTests: XCTestCase {
    private enum ExpectedFailure: Error {
        case store
        case battery
    }

    private final class EventLog {
        var values: [String] = []
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var storedDate: Date

        init(_ date: Date) { storedDate = date }

        var date: Date {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedDate
            }
            set {
                lock.lock()
                storedDate = newValue
                lock.unlock()
            }
        }
    }

    private final class FakeStore: PowerHelperStateStoring {
        var state: PowerHelperPersistentState?
        var failNextSave = false
        var loadError: Error?
        var quarantineError: Error?
        private(set) var loadCount = 0
        private(set) var saveCount = 0
        private(set) var quarantineCount = 0
        let events: EventLog

        init(state: PowerHelperPersistentState? = nil, events: EventLog = EventLog()) {
            self.state = state
            self.events = events
        }

        func load() throws -> PowerHelperPersistentState? {
            loadCount += 1
            if let loadError { throw loadError }
            return state
        }

        func save(_ state: PowerHelperPersistentState) throws {
            saveCount += 1
            if failNextSave {
                failNextSave = false
                throw ExpectedFailure.store
            }
            self.state = state
            events.values.append("save:\(state.ownsClosedLidProtection):\(state.leases.count)")
        }

        func quarantineUnreadableState() throws {
            quarantineCount += 1
            if let quarantineError { throw quarantineError }
        }
    }

    /// Store without a durable file: it relies on the protocol's default
    /// no-op quarantine.
    private final class MinimalStore: PowerHelperStateStoring {
        var state: PowerHelperPersistentState?
        var loadError: Error?

        func load() throws -> PowerHelperPersistentState? {
            if let loadError { throw loadError }
            return state
        }

        func save(_ state: PowerHelperPersistentState) throws {
            self.state = state
        }
    }

    private final class FakeBackend: ClosedLidProtectionControlling {
        var enabled: Bool
        var writes: [Bool] = []
        var failure: Error?
        var disablingFailure: Error?
        var onSet: ((Bool) -> Void)?
        var onRead: (() -> Void)?
        private(set) var readCount = 0
        let events: EventLog

        init(enabled: Bool, events: EventLog = EventLog()) {
            self.enabled = enabled
            self.events = events
        }

        func protectionIsEnabled() throws -> Bool {
            readCount += 1
            onRead?()
            if let failure { throw failure }
            return enabled
        }

        func setProtectionEnabled(_ enabled: Bool) throws {
            if let failure { throw failure }
            if !enabled, let disablingFailure { throw disablingFailure }
            self.enabled = enabled
            writes.append(enabled)
            events.values.append("set:\(enabled)")
            onSet?(enabled)
        }
    }

    private struct FakeBatteryReader: PowerBatterySafetyReading {
        let lowBattery: Bool
        var failure: Error?

        func isLowBattery(thresholdPercent: Int) throws -> Bool {
            if let failure { throw failure }
            return lowBattery
        }
    }

    private struct FakeBootSessionReader: PowerBootSessionReading {
        let identifier: String

        func currentBootSessionIdentifier() throws -> String { identifier }
    }

    private final class ProbeBatteryReader: PowerBatterySafetyReading {
        private(set) var callCount = 0
        func isLowBattery(thresholdPercent: Int) throws -> Bool {
            callCount += 1
            return false
        }
    }

    private final class SequenceBatteryReader: PowerBatterySafetyReading {
        private var values: [Bool]
        init(_ values: [Bool]) { self.values = values }
        func isLowBattery(thresholdPercent: Int) throws -> Bool {
            guard values.count > 1 else { return values.first ?? false }
            return values.removeFirst()
        }
    }

    private final class MutableBatteryReader: PowerBatterySafetyReading {
        var lowBattery = false
        var failure: Error?
        func isLowBattery(thresholdPercent: Int) throws -> Bool {
            if let failure { throw failure }
            return lowBattery
        }
    }

    private final class PercentBatteryReader: PowerBatterySafetyReading {
        var percent: Int
        private(set) var lastThreshold: Int?

        init(percent: Int) { self.percent = percent }

        func isLowBattery(thresholdPercent: Int) throws -> Bool {
            lastThreshold = thresholdPercent
            return percent <= thresholdPercent
        }
    }

    private final class MutableThermalReader:
        PowerThermalStateReading, @unchecked Sendable
    {
        var state: PowerThermalState
        init(_ state: PowerThermalState = .nominal) { self.state = state }
        func thermalState() -> PowerThermalState { state }
    }

    private final class ProbeBootSessionReader:
        PowerBootSessionReading, @unchecked Sendable
    {
        private(set) var callCount = 0
        func currentBootSessionIdentifier() throws -> String {
            callCount += 1
            return "test-boot"
        }
    }

    private let now = Date(timeIntervalSince1970: 10_000)
    private let identity = PowerLeaseIdentity(sessionName: "codex-work", runToken: "run-1")

    func testAcquireVerifiesBothProtectionsAndPersistsOwnershipBeforeMutation() throws {
        let events = EventLog()
        let store = FakeStore(events: events)
        let backend = FakeBackend(enabled: false, events: events)
        let service = try makeService(store: store, backend: backend)

        let status = try service.acquireLease(identity, assertionActive: true)

        XCTAssertEqual(status.state, .protected)
        XCTAssertEqual(status.leaseCount, 1)
        XCTAssertEqual(backend.writes, [true])
        XCTAssertEqual(store.state?.leases.first?.sessionName, "codex-work")
        XCTAssertEqual(store.state?.ownsClosedLidProtection, true)
        let ownershipIntent = try XCTUnwrap(
            events.values.firstIndex(of: "save:true:1"))
        let mutation = try XCTUnwrap(events.values.firstIndex(of: "set:true"))
        XCTAssertLessThan(ownershipIntent, mutation)
    }

    func testStatusIsAnHonestReadOnlySnapshotBeforeStartupReconcile() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: true)
        let battery = ProbeBatteryReader()
        let boot = ProbeBootSessionReader()
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: boot,
            now: { self.now })
        let savesAfterInitialization = store.saveCount

        let status = try service.status()

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertFalse(status.helperReachable)
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(store.saveCount, savesAfterInitialization)
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(battery.callCount, 0)
        XCTAssertEqual(boot.callCount, 0)
    }

    func testStatusDoesNotWaitForAConcurrentSlowReconcile() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        XCTAssertEqual(try service.reconcile().state, .allowed)

        let reconcileEnteredBackend = DispatchSemaphore(value: 0)
        let allowReconcileToFinish = DispatchSemaphore(value: 0)
        let reconcileFinished = DispatchSemaphore(value: 0)
        backend.onRead = {
            backend.onRead = nil
            reconcileEnteredBackend.signal()
            _ = allowReconcileToFinish.wait(timeout: .now() + 2)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? service.reconcile()
            reconcileFinished.signal()
        }
        XCTAssertEqual(
            reconcileEnteredBackend.wait(timeout: .now() + 1), .success)
        defer { allowReconcileToFinish.signal() }

        let statusReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? service.status()
            statusReturned.signal()
        }
        XCTAssertEqual(statusReturned.wait(timeout: .now() + 0.2), .success)

        allowReconcileToFinish.signal()
        XCTAssertEqual(reconcileFinished.wait(timeout: .now() + 1), .success)
    }

    func testFailedReconcileReplacesAFormerlyHealthyCachedStatus() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let battery = MutableBatteryReader()
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)
        XCTAssertEqual(try service.reconcile().state, .allowed)
        battery.failure = ExpectedFailure.battery

        XCTAssertThrowsError(try service.reconcile())

        let cached = try service.status()
        XCTAssertEqual(cached.state, .unavailable)
        XCTAssertFalse(cached.helperReachable)
    }

    func testAcquireRejectsAnExpiredRequestBeforePersisting() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)

        XCTAssertThrowsError(try service.acquireLease(
            identity,
            assertionActive: true,
            requestDeadline: now
        )) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .requestExpired)
        }
        XCTAssertNil(store.state)
        XCTAssertFalse(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testAcquireRollsBackProtectionWhenDeadlineExpiresDuringMutation() throws {
        let clock = TestClock(now)
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        backend.onSet = { enabled in
            if enabled {
                clock.date = self.now.addingTimeInterval(6)
            }
        }
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { clock.date },
            leaseTimeout: 120)

        XCTAssertThrowsError(try service.acquireLease(
            identity,
            assertionActive: true,
            requestDeadline: now.addingTimeInterval(5)
        )) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .requestExpired)
        }
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(backend.enabled)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
    }

    func testAcquireNeverStartsMutationAfterItsDeadlineExpiresInPreflight() throws {
        let clock = TestClock(now)
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        backend.onRead = {
            backend.onRead = nil
            clock.date = self.now.addingTimeInterval(6)
        }
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { clock.date },
            leaseTimeout: 120)

        XCTAssertThrowsError(try service.acquireLease(
            identity,
            assertionActive: true,
            requestDeadline: now.addingTimeInterval(5)
        )) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .requestExpired)
        }
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertFalse(backend.enabled)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
    }

    func testAcquireReportsRestorationFailureInsteadOfExpiredAfterFailedRollback() throws {
        let clock = TestClock(now)
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        backend.disablingFailure = ExpectedFailure.battery
        backend.onSet = { enabled in
            if enabled {
                clock.date = self.now.addingTimeInterval(6)
            }
        }
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { clock.date },
            leaseTimeout: 120)

        XCTAssertThrowsError(try service.acquireLease(
            identity,
            assertionActive: true,
            requestDeadline: now.addingTimeInterval(5)
        )) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .closedLidRestorationFailed)
        }
        XCTAssertTrue(backend.enabled)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.ownsClosedLidProtection, true)
        XCTAssertEqual(try service.status().state, .unavailable)
    }

    func testUnprotectedInitialAcquireDoesNotLeaveAnOrphanLease() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(
            store: store,
            backend: backend,
            battery: FakeBatteryReader(lowBattery: true))

        let status = try service.acquireLease(
            identity, assertionActive: true)

        XCTAssertEqual(status.state, .lowBattery)
        XCTAssertEqual(status.leaseCount, 0)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertFalse(backend.enabled)
    }

    func testRollbackAmbientProtectionNeverConfirmsTheRemovedLease() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: true)
        let battery = SequenceBatteryReader([true, false])
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)

        let acquireStatus = try service.acquireLease(
            identity, assertionActive: true)

        XCTAssertEqual(acquireStatus.state, .unavailable)
        XCTAssertEqual(acquireStatus.leaseCount, 0)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(try service.status().state, .protected)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testAcquireIgnoresAnotherSessionsStagedInactiveLease() throws {
        let stagedLease = PowerLease(
            id: "staged", sessionName: "claude-review", runToken: "run-9",
            renewedAt: now, assertionActive: false)
        let store = FakeStore(state: PowerHelperPersistentState(
            leases: [stagedLease], bootSessionIdentifier: "test-boot"))
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)

        let status = try service.acquireLease(identity, assertionActive: true)

        XCTAssertEqual(status.state, .protected)
        XCTAssertEqual(status.leaseCount, 2)
        XCTAssertEqual(backend.writes, [true])
        XCTAssertEqual(store.state?.leases.count, 2)
        // The read-only snapshot keeps the honest global aggregate; only the
        // acquire confirmation is scoped to the requesting identity.
        let cached = try service.status()
        XCTAssertEqual(cached.state, .unavailable)
        XCTAssertFalse(cached.assertionActive)
    }

    func testRenewalIgnoresAnotherSessionsStagedInactiveLease() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        let other = PowerLeaseIdentity(
            sessionName: "claude-review", runToken: "run-9")
        _ = try service.acquireLease(identity, assertionActive: true)
        _ = try service.acquireLease(other, assertionActive: true)

        // The wrapper stages its lease assertion-inactive before a waiting
        // release; the staging report itself stays honest.
        let staged = try service.renewLease(other, assertionActive: false)
        XCTAssertEqual(staged.state, .unavailable)

        let renewed = try service.renewLease(identity, assertionActive: true)

        XCTAssertEqual(renewed.state, .protected)
        XCTAssertEqual(renewed.leaseCount, 2)
        XCTAssertEqual(backend.writes, [true])
        XCTAssertEqual(store.state?.leases.count, 2)
    }

    func testLowBatteryStillRefusesAcquireDespiteAnotherStagedInactiveLease() throws {
        let stagedLease = PowerLease(
            id: "staged", sessionName: "claude-review", runToken: "run-9",
            renewedAt: now, assertionActive: false)
        let store = FakeStore(state: PowerHelperPersistentState(
            leases: [stagedLease], bootSessionIdentifier: "test-boot"))
        let backend = FakeBackend(enabled: false)
        let service = try makeService(
            store: store, backend: backend,
            battery: FakeBatteryReader(lowBattery: true))

        let status = try service.acquireLease(identity, assertionActive: true)

        XCTAssertEqual(status.state, .lowBattery)
        XCTAssertEqual(store.state?.leases, [stagedLease])
        XCTAssertFalse(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testThermalSafetyStillRefusesAcquireDespiteAnotherStagedInactiveLease() throws {
        let stagedLease = PowerLease(
            id: "staged", sessionName: "claude-review", runToken: "run-9",
            renewedAt: now, assertionActive: false)
        let store = FakeStore(state: PowerHelperPersistentState(
            leases: [stagedLease], bootSessionIdentifier: "test-boot"))
        let backend = FakeBackend(enabled: false)
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            thermalReader: MutableThermalReader(.serious),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now })

        let status = try service.acquireLease(identity, assertionActive: true)

        XCTAssertEqual(status.state, .temperature)
        XCTAssertTrue(status.thermalSafetyActive)
        XCTAssertEqual(store.state?.leases, [stagedLease])
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testLowBatteryStillRefusesRenewalConfirmation() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let battery = MutableBatteryReader()
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)
        _ = try service.acquireLease(identity, assertionActive: true)
        battery.lowBattery = true

        let status = try service.renewLease(identity, assertionActive: true)

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertTrue(status.lowBattery)
        XCTAssertEqual(backend.writes, [true, false])
    }

    func testReleaseRestoresNormalSleepOnlyWhenDetachOwnedTheMutation() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        _ = try service.acquireLease(identity, assertionActive: true)

        let status = try service.releaseLease(identity)

        XCTAssertEqual(status.state, .allowed)
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
    }

    func testTerminationRestoresOwnedSettingButRetainsRenewableLeases() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        _ = try service.acquireLease(identity, assertionActive: true)

        try service.prepareForTermination()

        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(backend.enabled)
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
        XCTAssertEqual(store.state?.leases.count, 1)
        XCTAssertEqual(store.state?.unregistrationPending, false)
    }

    func testPrepareForUnregistrationRefusesLiveLeasesWithoutQuiescing() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        _ = try service.acquireLease(identity, assertionActive: true)

        XCTAssertThrowsError(try service.prepareForUnregistration()) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .activeLeasesPreventUnregistration)
        }

        XCTAssertEqual(
            try service.renewLease(identity, assertionActive: true).state,
            .protected)
    }

    func testPrepareForUnregistrationRestoresAndQuiescesUntilCancelled() throws {
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(store: store, backend: backend)

        try service.prepareForUnregistration()

        XCTAssertEqual(backend.writes, [false])
        XCTAssertFalse(backend.enabled)
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
        XCTAssertEqual(store.state?.unregistrationPending, true)
        XCTAssertThrowsError(
            try service.acquireLease(identity, assertionActive: true)
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .serviceQuiescing)
        }

        _ = try service.cancelUnregistration()
        XCTAssertEqual(store.state?.unregistrationPending, false)
        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
    }

    func testPrepareForUnregistrationNeverDisablesBorrowedProtection() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: true)
        let service = try makeService(store: store, backend: backend)

        try service.prepareForUnregistration()

        XCTAssertTrue(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testFailedUnregistrationPreparationDoesNotLeaveServiceQuiescing() throws {
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true))
        let backend = FakeBackend(enabled: true)
        backend.failure = ExpectedFailure.battery
        let service = try makeService(store: store, backend: backend)

        XCTAssertThrowsError(try service.prepareForUnregistration())

        backend.failure = nil
        XCTAssertEqual(store.state?.unregistrationPending, false)
        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
    }

    func testUnregistrationQuiesceSurvivesTimeAndHelperRestartUntilCancelled() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let clock = TestClock(now)
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { clock.date },
            leaseTimeout: 120)
        try service.prepareForUnregistration()
        clock.date = now.addingTimeInterval(3_600)

        XCTAssertThrowsError(
            try service.acquireLease(identity, assertionActive: true)
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .serviceQuiescing)
        }

        let restarted = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { clock.date },
            leaseTimeout: 120)
        XCTAssertEqual(try restarted.reconcile().state, .transitioning)
        XCTAssertThrowsError(
            try restarted.acquireLease(identity, assertionActive: true)
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .serviceQuiescing)
        }

        _ = try restarted.cancelUnregistration()
        XCTAssertEqual(store.state?.unregistrationPending, false)
        XCTAssertEqual(
            try restarted.acquireLease(identity, assertionActive: true).state,
            .protected)
    }

    func testLegacyPersistentStateDefaultsUnregistrationGateToOpen() throws {
        let data = Data(
            #"{"schema":1,"owns_closed_lid_protection":false,"leases":[],"boot_session_identifier":"test-boot"}"#.utf8)

        let state = try JSONDecoder().decode(
            PowerHelperPersistentState.self, from: data)

        XCTAssertFalse(state.unregistrationPending)
        XCTAssertFalse(state.thermalSafety.isActive)
        XCTAssertEqual(state.lowBatteryThreshold, .default)
    }

    func testUnknownStoredLowBatteryThresholdBecomesTheDefaultFloor() throws {
        let data = Data(
            #"{"schema":1,"owns_closed_lid_protection":false,"leases":[],"low_battery_threshold":7}"#.utf8)

        let state = try JSONDecoder().decode(
            PowerHelperPersistentState.self, from: data)

        XCTAssertEqual(state.lowBatteryThreshold, .percent10)
    }

    func testLowBatteryThresholdPersistsAcrossReloadAndDrivesReconcile() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let battery = PercentBatteryReader(percent: 12)
        let first = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)
        _ = try first.acquireLease(identity, assertionActive: true)
        XCTAssertEqual(try first.status().state, .protected)
        XCTAssertEqual(try first.status().lowBatteryThreshold, .percent10)
        XCTAssertEqual(battery.lastThreshold, 10)

        let raised = try first.setLowBatteryThreshold(.percent15)
        // The helper restores the owned closed-lid layer, but the wrapper
        // still holds its assertion. Status must not claim sleep is safe.
        XCTAssertEqual(raised.state, .unavailable)
        XCTAssertTrue(raised.lowBattery)
        XCTAssertEqual(raised.lowBatteryThreshold, .percent15)
        XCTAssertEqual(store.state?.lowBatteryThreshold, .percent15)
        XCTAssertEqual(battery.lastThreshold, 15)
        XCTAssertEqual(backend.writes, [true, false])

        let restarted = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)
        let status = try restarted.reconcile()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertTrue(status.lowBattery)
        XCTAssertEqual(status.lowBatteryThreshold, .percent15)
        XCTAssertEqual(store.state?.lowBatteryThreshold, .percent15)
    }

    func testSetLowBatteryThresholdIsRefusedWhileTheHelperIsQuiescing() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        try service.prepareForUnregistration()

        XCTAssertThrowsError(
            try service.setLowBatteryThreshold(.percent20)
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .serviceQuiescing)
        }
        XCTAssertEqual(store.state?.lowBatteryThreshold, .percent10)
    }

    func testBootSessionChangeKeepsTheChosenLowBatteryFloor() throws {
        let store = FakeStore(state: PowerHelperPersistentState(
            bootSessionIdentifier: "old-boot",
            lowBatteryThreshold: .percent20))
        let backend = FakeBackend(enabled: false)
        let service = try makeService(
            store: store, backend: backend, bootSessionIdentifier: "new-boot")

        XCTAssertEqual(try service.reconcile().lowBatteryThreshold, .percent20)
        XCTAssertEqual(store.state?.lowBatteryThreshold, .percent20)
        XCTAssertEqual(store.state?.bootSessionIdentifier, "new-boot")
    }

    func testFailedReleaseNeverClaimsThatSleepWasRestored() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        _ = try service.acquireLease(identity, assertionActive: true)
        backend.failure = ExpectedFailure.battery

        XCTAssertThrowsError(try service.releaseLease(identity))
        XCTAssertEqual(try service.status().state, .unavailable)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.ownsClosedLidProtection, true)
    }

    func testPreexistingProtectionIsBorrowedAndNeverDisabled() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: true)
        let service = try makeService(store: store, backend: backend)

        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
        XCTAssertEqual(try service.releaseLease(identity).state, .protected)

        XCTAssertTrue(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
    }

    func testStartupReconcileExpiresStaleLeaseAndRestoresOwnedState() throws {
        let staleLease = PowerLease(
            id: "old", sessionName: "old", runToken: "old",
            renewedAt: now.addingTimeInterval(-121), assertionActive: true)
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true, leases: [staleLease]))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(store: store, backend: backend, timeout: 120)

        let status = try service.reconcile()

        XCTAssertEqual(status.state, .allowed)
        XCTAssertEqual(backend.writes, [false])
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
    }

    func testNewBootExpiresEveryLeaseBeforeRestoringOwnedState() throws {
        let lease = PowerLease(
            id: "fresh", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true,
            leases: [lease],
            bootSessionIdentifier: "boot-before"))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(
            store: store, backend: backend,
            bootSessionIdentifier: "boot-after")

        let status = try service.reconcile()

        XCTAssertEqual(status.state, .allowed)
        XCTAssertEqual(status.leaseCount, 0)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertEqual(store.state?.bootSessionIdentifier, "boot-after")
        XCTAssertEqual(backend.writes, [false])
    }

    func testSameBootRetainsFreshLease() throws {
        let lease = PowerLease(
            id: "fresh", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true,
            leases: [lease],
            bootSessionIdentifier: "same-boot"))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(
            store: store, backend: backend,
            bootSessionIdentifier: "same-boot")

        XCTAssertEqual(try service.reconcile().state, .protected)
        XCTAssertEqual(store.state?.leases, [lease])
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testLegacyStateAdoptsBootIdentifierWithoutDroppingLiveLease() throws {
        let lease = PowerLease(
            id: "fresh", sessionName: "session", runToken: "run",
            renewedAt: now, assertionActive: true)
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true, leases: [lease]))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(
            store: store, backend: backend,
            bootSessionIdentifier: "first-recorded-boot")

        XCTAssertEqual(try service.reconcile().state, .protected)
        XCTAssertEqual(store.state?.leases, [lease])
        XCTAssertEqual(
            store.state?.bootSessionIdentifier, "first-recorded-boot")
    }

    func testLowBatteryRefusesProtectionAndDropsOwnedMutation() throws {
        let lease = PowerLease(
            id: "lease", sessionName: identity.sessionName,
            runToken: identity.runToken, renewedAt: now,
            assertionActive: true)
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true, leases: [lease]))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(
            store: store, backend: backend,
            battery: FakeBatteryReader(lowBattery: true))

        let status = try service.reconcile()
        let releasedStatus = try service.renewLease(
            identity, assertionActive: false)

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertTrue(status.lowBattery)
        XCTAssertEqual(releasedStatus.state, .lowBattery)
        XCTAssertEqual(backend.writes, [false])
        XCTAssertFalse(status.closedLidProtectionActive)
    }

    func testHotInitialAcquireIsNotIssuedOrAllowedToLaunch() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let thermal = MutableThermalReader(.serious)
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            thermalReader: thermal,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now })

        let status = try service.acquireLease(
            identity, assertionActive: true)

        XCTAssertEqual(status.state, .temperature)
        XCTAssertEqual(status.thermalState, .serious)
        XCTAssertTrue(status.thermalSafetyActive)
        XCTAssertEqual(store.state?.leases, [])
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testThermalPressureImmediatelyDropsOwnedProtectionForAllLeases() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let thermal = MutableThermalReader()
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            thermalReader: thermal,
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now })
        let second = PowerLeaseIdentity(sessionName: "second", runToken: "run-2")
        _ = try service.acquireLease(identity, assertionActive: true)
        _ = try service.acquireLease(second, assertionActive: true)

        thermal.state = .critical
        let releasing = try service.reconcile()
        _ = try service.renewLease(identity, assertionActive: false)
        let released = try service.renewLease(second, assertionActive: false)

        XCTAssertEqual(releasing.state, .unavailable)
        XCTAssertEqual(released.state, .temperature)
        XCTAssertEqual(released.leaseCount, 2)
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(store.state?.ownsClosedLidProtection ?? true)
    }

    func testThermalPressureReleasesOwnedProtectionBeforePersistence() throws {
        let lease = PowerLease(
            id: "lease", sessionName: identity.sessionName,
            runToken: identity.runToken, renewedAt: now,
            assertionActive: true)
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true,
            leases: [lease],
            bootSessionIdentifier: "test-boot"))
        store.failNextSave = true
        let backend = FakeBackend(enabled: true)
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            thermalReader: MutableThermalReader(.serious),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now })

        XCTAssertThrowsError(try service.reconcile())

        XCTAssertFalse(backend.enabled)
        XCTAssertEqual(backend.writes, [false])
        XCTAssertTrue(store.state?.ownsClosedLidProtection ?? false)
    }

    func testBorrowedProtectionIsNeverDisabledForTemperature() throws {
        let lease = PowerLease(
            id: "borrowed", sessionName: identity.sessionName,
            runToken: identity.runToken, renewedAt: now,
            assertionActive: false)
        let store = FakeStore(state: PowerHelperPersistentState(leases: [lease]))
        let backend = FakeBackend(enabled: true)
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            thermalReader: MutableThermalReader(.serious),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now })

        let status = try service.reconcile()

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertTrue(status.thermalSafetyActive)
        XCTAssertTrue(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertFalse(store.state?.ownsClosedLidProtection ?? true)
    }

    func testThermalCooldownSurvivesHelperRestart() throws {
        let clock = TestClock(now)
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let thermal = MutableThermalReader()
        func service() throws -> PowerHelperLeaseService {
            try PowerHelperLeaseService(
                store: store,
                backend: backend,
                batteryReader: FakeBatteryReader(lowBattery: false),
                thermalReader: thermal,
                bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
                now: { clock.date },
                thermalCooldown: 30)
        }
        var current = try service()
        _ = try current.acquireLease(identity, assertionActive: true)
        thermal.state = .serious
        _ = try current.reconcile()
        clock.date = now.addingTimeInterval(1)
        thermal.state = .fair
        _ = try current.reconcile()

        current = try service()
        clock.date = now.addingTimeInterval(30)
        XCTAssertTrue(try current.reconcile().thermalSafetyActive)
        clock.date = now.addingTimeInterval(31)
        let cooled = try current.reconcile()

        XCTAssertFalse(cooled.thermalSafetyActive)
        XCTAssertEqual(cooled.thermalState, .fair)
        XCTAssertEqual(cooled.state, .protected)
        XCTAssertEqual(backend.writes, [true, false, true])
    }

    func testPersistenceFailurePreventsPowerMutation() throws {
        let store = FakeStore()
        store.failNextSave = true
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)

        XCTAssertThrowsError(
            try service.acquireLease(identity, assertionActive: true))
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertFalse(backend.enabled)
    }

    func testRenewUpdatesTimestampWithoutDuplicatingLease() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let clock = TestClock(now)
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { clock.date },
            leaseTimeout: 120)
        _ = try service.acquireLease(identity, assertionActive: true)
        clock.date = now.addingTimeInterval(30)

        let status = try service.renewLease(identity, assertionActive: true)

        XCTAssertEqual(status.leaseCount, 1)
        XCTAssertEqual(store.state?.leases.count, 1)
        XCTAssertEqual(store.state?.leases.first?.renewedAt, clock.date)
    }

    func testRejectsEmptyOrOversizedIdentityBeforePersisting() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)

        XCTAssertThrowsError(try service.acquireLease(
            PowerLeaseIdentity(sessionName: "", runToken: "run"),
            assertionActive: true))
        XCTAssertThrowsError(try service.acquireLease(
            PowerLeaseIdentity(sessionName: "session", runToken: String(repeating: "x", count: 513)),
            assertionActive: true))
        XCTAssertNil(store.state)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testBatteryReaderFailureNeverClaimsProtection() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(
            store: store, backend: backend,
            battery: FakeBatteryReader(lowBattery: false, failure: ExpectedFailure.battery))

        XCTAssertThrowsError(try service.acquireLease(identity, assertionActive: true))
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testReconcileIsRefusedOnceTerminating() throws {
        let store = FakeStore()
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend)
        _ = try service.acquireLease(identity, assertionActive: true)
        try service.prepareForTermination()
        let savesAfterTermination = store.saveCount

        XCTAssertThrowsError(try service.reconcile()) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .serviceQuiescing)
        }

        // The retained live lease must not re-persist ownership or turn the
        // restored setting back on behind the shutdown hook.
        XCTAssertEqual(backend.writes, [true, false])
        XCTAssertFalse(backend.enabled)
        XCTAssertEqual(store.saveCount, savesAfterTermination)
        XCTAssertEqual(store.state?.ownsClosedLidProtection, false)
        XCTAssertEqual(store.state?.leases.count, 1)
        XCTAssertEqual(try service.status().state, .unavailable)
    }

    func testUnreadableStoreStateIsQuarantinedAndServiceStartsClean() throws {
        let store = FakeStore()
        store.loadError = ExpectedFailure.store
        let backend = FakeBackend(enabled: false)

        let service = try makeService(store: store, backend: backend)

        XCTAssertEqual(store.quarantineCount, 1)
        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
        XCTAssertEqual(store.state?.leases.count, 1)
    }

    func testQuarantineFailureDoesNotPreventACleanStart() throws {
        let store = FakeStore()
        store.loadError = ExpectedFailure.store
        store.quarantineError = ExpectedFailure.store
        let backend = FakeBackend(enabled: false)

        let service = try makeService(store: store, backend: backend)

        XCTAssertEqual(store.quarantineCount, 1)
        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
        XCTAssertEqual(store.state?.leases.count, 1)
    }

    func testDefaultQuarantineIsANoOpForStoresWithoutDurableFiles() throws {
        let store = MinimalStore()
        store.loadError = ExpectedFailure.store
        let backend = FakeBackend(enabled: false)

        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)

        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
        XCTAssertEqual(store.state?.leases.count, 1)
    }

    func testCorruptStateFileIsQuarantinedAndServiceStartsClean() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: stateURL)
        let store = SecureFilePowerHelperStateStore(fileURL: stateURL)
        let backend = FakeBackend(enabled: false)

        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        let quarantined = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .first { $0.hasPrefix("state.json.corrupt-") })
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(quarantined)),
            corrupt)
        XCTAssertEqual(try service.reconcile().state, .allowed)
        XCTAssertEqual(
            try service.acquireLease(identity, assertionActive: true).state,
            .protected)
        // The next save repairs the state path with a readable file.
        XCTAssertEqual(try store.load()?.leases.count, 1)
    }

    func testFutureSchemaStateFileIsQuarantinedWithoutClaimingOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        try Data(
            #"{"schema":2,"owns_closed_lid_protection":true,"leases":[]}"#.utf8
        ).write(to: stateURL)
        let store = SecureFilePowerHelperStateStore(fileURL: stateURL)
        // The unreadable file claimed ownership of a setting that is still
        // enabled. A clean start must treat it as borrowed and never
        // disable it.
        let backend = FakeBackend(enabled: true)

        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: FakeBatteryReader(lowBattery: false),
            bootSessionReader: FakeBootSessionReader(identifier: "test-boot"),
            now: { self.now },
            leaseTimeout: 120)

        // Quarantine happens at load time, before any reconciliation can
        // rewrite the state path.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasPrefix("state.json.corrupt-") })

        let status = try service.reconcile()

        XCTAssertEqual(status.state, .protected)
        XCTAssertTrue(status.closedLidProtectionActive)
        XCTAssertTrue(backend.enabled)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testAcquireSucceedsWhenLeaseTableIsFullOfExpiredLeases() throws {
        let expired = (0..<PowerHelperLeaseService.maximumLeaseCount).map {
            PowerLease(
                id: "expired-\($0)", sessionName: "session-\($0)",
                runToken: "run-\($0)",
                renewedAt: now.addingTimeInterval(-121),
                assertionActive: true)
        }
        let store = FakeStore(state: PowerHelperPersistentState(
            leases: expired))
        let backend = FakeBackend(enabled: false)
        let service = try makeService(store: store, backend: backend, timeout: 120)

        let status = try service.acquireLease(identity, assertionActive: true)

        XCTAssertEqual(status.state, .protected)
        XCTAssertEqual(status.leaseCount, 1)
        XCTAssertEqual(store.state?.leases.count, 1)
        XCTAssertEqual(
            store.state?.leases.first?.sessionName, identity.sessionName)
    }

    func testAcquireStillRejectsWhenLeaseTableIsFullOfLiveLeases() throws {
        let live = (0..<PowerHelperLeaseService.maximumLeaseCount).map {
            PowerLease(
                id: "live-\($0)", sessionName: "session-\($0)",
                runToken: "run-\($0)",
                renewedAt: now,
                assertionActive: true)
        }
        let store = FakeStore(state: PowerHelperPersistentState(
            ownsClosedLidProtection: true,
            leases: live,
            bootSessionIdentifier: "test-boot"))
        let backend = FakeBackend(enabled: true)
        let service = try makeService(store: store, backend: backend, timeout: 120)

        XCTAssertThrowsError(
            try service.acquireLease(identity, assertionActive: true)
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperLeaseServiceError,
                .tooManyLeases)
        }
        XCTAssertEqual(store.state?.leases.count, 256)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    private func makeService(
        store: FakeStore,
        backend: FakeBackend,
        battery: FakeBatteryReader = FakeBatteryReader(lowBattery: false),
        timeout: TimeInterval = 120,
        bootSessionIdentifier: String = "test-boot"
    ) throws -> PowerHelperLeaseService {
        try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: battery,
            bootSessionReader: FakeBootSessionReader(
                identifier: bootSessionIdentifier),
            now: { self.now },
            leaseTimeout: timeout)
    }
}
