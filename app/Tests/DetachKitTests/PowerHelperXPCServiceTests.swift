import XCTest
@testable import DetachKit

final class PowerHelperXPCServiceTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    private final class MemoryStore: PowerHelperStateStoring {
        var state: PowerHelperPersistentState?
        var saveError: Error?
        func load() throws -> PowerHelperPersistentState? { state }
        func save(_ state: PowerHelperPersistentState) throws {
            if let saveError { throw saveError }
            self.state = state
        }
    }

    private final class Backend: ClosedLidProtectionControlling {
        var enabled = false
        var readError: Error?
        var writeError: Error?

        func protectionIsEnabled() throws -> Bool {
            if let readError { throw readError }
            return enabled
        }

        func setProtectionEnabled(_ enabled: Bool) throws {
            if let writeError { throw writeError }
            self.enabled = enabled
        }
    }

    private struct Battery: PowerBatterySafetyReading {
        let low: Bool
        func isLowBattery() throws -> Bool { low }
    }

    private struct BootSession: PowerBootSessionReading {
        func currentBootSessionIdentifier() throws -> String { "test-boot" }
    }

    func testStatusReturnsVersionedTypedSnapshot() throws {
        let bridge = try makeBridge(lowBattery: false)
        let reply = expectation(description: "status")
        var decoded: PowerProtectionStatus?
        var replyError: NSError?

        bridge.status { data, error in
            replyError = error
            if let data {
                decoded = try? JSONDecoder().decode(
                    PowerProtectionStatus.self, from: data as Data)
            }
            reply.fulfill()
        }
        wait(for: [reply], timeout: 1)

        XCTAssertNil(replyError)
        XCTAssertEqual(decoded?.state, .allowed)
        XCTAssertEqual(decoded?.helperReachable, true)
    }

    func testAcquireConfirmsOnlyFullyProtectedLease() throws {
        let protectedBridge = try makeBridge(lowBattery: false)
        let lowBatteryBridge = try makeBridge(lowBattery: true)
        let protectedReply = expectation(description: "protected")
        let lowReply = expectation(description: "low")
        var protected = false
        var lowBatteryConfirmed = true

        protectedBridge.acquireLease(
            sessionName: "session", runToken: "run",
            assertionActive: true, requestDeadline: 200
        ) { confirmed, error in
            XCTAssertNil(error)
            protected = confirmed
            protectedReply.fulfill()
        }
        lowBatteryBridge.acquireLease(
            sessionName: "session", runToken: "run",
            assertionActive: true, requestDeadline: 200
        ) { confirmed, error in
            XCTAssertNil(error)
            lowBatteryConfirmed = confirmed
            lowReply.fulfill()
        }
        wait(for: [protectedReply, lowReply], timeout: 1)

        XCTAssertTrue(protected)
        XCTAssertFalse(lowBatteryConfirmed)
    }

    func testReleaseIsIdempotentAndRestoresOwnedProtection() throws {
        let backend = Backend()
        let bridge = try makeBridge(lowBattery: false, backend: backend)
        let acquire = expectation(description: "acquire")
        bridge.acquireLease(
            sessionName: "session", runToken: "run", assertionActive: true,
            requestDeadline: 200
        ) { _, _ in acquire.fulfill() }
        wait(for: [acquire], timeout: 1)
        XCTAssertTrue(backend.enabled)

        let release = expectation(description: "release")
        bridge.releaseLease(sessionName: "session", runToken: "run") { error in
            XCTAssertNil(error)
            release.fulfill()
        }
        wait(for: [release], timeout: 1)

        XCTAssertFalse(backend.enabled)
    }

    func testPrepareAndCancelUnregistrationGateNewLeases() throws {
        let bridge = try makeBridge(lowBattery: false)
        let prepared = expectation(description: "prepared")
        bridge.prepareForUnregistration { error in
            XCTAssertNil(error)
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 1)

        let rejected = expectation(description: "rejected")
        bridge.acquireLease(
            sessionName: "session", runToken: "run", assertionActive: true,
            requestDeadline: 200
        ) { confirmed, error in
            XCTAssertFalse(confirmed)
            XCTAssertEqual(
                error?.code,
                PowerHelperXPCService.ErrorCode.serviceQuiescing.rawValue)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)

        let cancelled = expectation(description: "cancelled")
        bridge.cancelUnregistration { error in
            XCTAssertNil(error)
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 1)

        let accepted = expectation(description: "accepted")
        bridge.acquireLease(
            sessionName: "session", runToken: "run", assertionActive: true,
            requestDeadline: 200
        ) { confirmed, error in
            XCTAssertNil(error)
            XCTAssertTrue(confirmed)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 1)
    }

    func testExpiredAcquireDeadlineFailsBeforeCreatingALease() throws {
        let bridge = try makeBridge(lowBattery: false)
        let expired = expectation(description: "expired")

        bridge.acquireLease(
            sessionName: "session", runToken: "run", assertionActive: true,
            requestDeadline: 99
        ) { confirmed, error in
            XCTAssertFalse(confirmed)
            XCTAssertEqual(
                error?.code,
                PowerHelperXPCService.ErrorCode.requestExpired.rawValue)
            expired.fulfill()
        }
        wait(for: [expired], timeout: 1)
    }

    func testNonFiniteAcquireDeadlineIsRejectedBeforeLeaseMutation() throws {
        for deadline in [TimeInterval.infinity, -.infinity, .nan] {
            let bridge = try makeBridge(lowBattery: false)
            let rejected = expectation(description: "non-finite \(deadline)")

            bridge.acquireLease(
                sessionName: "session", runToken: "run",
                assertionActive: true, requestDeadline: deadline
            ) { confirmed, error in
                XCTAssertFalse(confirmed)
                XCTAssertEqual(error?.domain, PowerHelperXPCService.errorDomain)
                XCTAssertEqual(
                    error?.code,
                    PowerHelperXPCService.ErrorCode.requestExpired.rawValue)
                rejected.fulfill()
            }
            wait(for: [rejected], timeout: 1)
        }
    }

    func testRenewReportsConfirmationAndMapsInvalidIdentityToGenericError() throws {
        let bridge = try makeBridge(lowBattery: false)
        let protected = expectation(description: "protected renewal")
        bridge.renewLease(
            sessionName: "session", runToken: "run", assertionActive: true
        ) { confirmed, error in
            XCTAssertTrue(confirmed)
            XCTAssertNil(error)
            protected.fulfill()
        }
        wait(for: [protected], timeout: 1)

        let invalid = expectation(description: "invalid renewal")
        bridge.renewLease(
            sessionName: "", runToken: "run", assertionActive: true
        ) { confirmed, error in
            XCTAssertFalse(confirmed)
            XCTAssertEqual(error?.domain, PowerHelperXPCService.errorDomain)
            XCTAssertEqual(
                error?.code,
                PowerHelperXPCService.ErrorCode.generic.rawValue)
            XCTAssertFalse(error?.localizedDescription.isEmpty ?? true)
            invalid.fulfill()
        }
        wait(for: [invalid], timeout: 1)
    }

    func testReleaseMapsInvalidIdentityToGenericError() throws {
        let bridge = try makeBridge(lowBattery: false)
        let reply = expectation(description: "invalid release")

        bridge.releaseLease(sessionName: "session", runToken: "") { error in
            XCTAssertEqual(error?.domain, PowerHelperXPCService.errorDomain)
            XCTAssertEqual(
                error?.code,
                PowerHelperXPCService.ErrorCode.generic.rawValue)
            reply.fulfill()
        }
        wait(for: [reply], timeout: 1)
    }

    func testPrepareMapsActiveLeaseErrorAndCancelMapsBackendFailure() throws {
        let backend = Backend()
        let bridge = try makeBridge(lowBattery: false, backend: backend)
        let acquired = expectation(description: "acquired")
        bridge.acquireLease(
            sessionName: "session", runToken: "run", assertionActive: true,
            requestDeadline: 200
        ) { confirmed, error in
            XCTAssertTrue(confirmed)
            XCTAssertNil(error)
            acquired.fulfill()
        }
        wait(for: [acquired], timeout: 1)

        let active = expectation(description: "active lease")
        bridge.prepareForUnregistration { error in
            XCTAssertEqual(
                error?.code,
                PowerHelperXPCService.ErrorCode.activeLeases.rawValue)
            active.fulfill()
        }
        wait(for: [active], timeout: 1)

        let cancelStore = MemoryStore()
        let cancelBridge = try makeBridge(
            lowBattery: false, store: cancelStore)
        let prepared = expectation(description: "prepared for failed cancel")
        cancelBridge.prepareForUnregistration { error in
            XCTAssertNil(error)
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 1)

        cancelStore.saveError = ExpectedFailure()
        let failedCancel = expectation(description: "failed cancel")
        cancelBridge.cancelUnregistration { error in
            XCTAssertEqual(
                error?.code,
                PowerHelperXPCService.ErrorCode.generic.rawValue)
            failedCancel.fulfill()
        }
        wait(for: [failedCancel], timeout: 1)
    }

    private func makeBridge(
        lowBattery: Bool,
        store: MemoryStore = MemoryStore(),
        backend: Backend = Backend()
    ) throws -> PowerHelperXPCService {
        let service = try PowerHelperLeaseService(
            store: store,
            backend: backend,
            batteryReader: Battery(low: lowBattery),
            bootSessionReader: BootSession(),
            now: { Date(timeIntervalSince1970: 100) })
        // Production reconciles once before listener.resume(), so XPC status
        // always serves a populated read-only snapshot.
        _ = try service.reconcile()
        return PowerHelperXPCService(service: service)
    }
}
