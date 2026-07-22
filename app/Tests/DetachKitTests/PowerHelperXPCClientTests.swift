import Foundation
import XCTest
@testable import DetachKit

final class PowerHelperXPCClientTests: XCTestCase {
    private struct ExpectedFailure: Error, Equatable {}

    private final class FakeTransport: PowerHelperXPCTransport, @unchecked Sendable {
        var statusResult: Result<Data, Error> = .failure(ExpectedFailure())
        var acquireResult: Result<Bool, Error> = .success(true)
        var renewResult: Result<Bool, Error> = .success(true)
        var releaseError: Error?
        var prepareError: Error?
        var cancelError: Error?
        private(set) var acquired: [(PowerLeaseIdentity, Bool)] = []
        private(set) var renewed: [(PowerLeaseIdentity, Bool)] = []
        private(set) var released: [PowerLeaseIdentity] = []
        private(set) var prepareCalls = 0
        private(set) var cancelCalls = 0

        func statusData() throws -> Data {
            try statusResult.get()
        }

        func acquireLease(
            _ identity: PowerLeaseIdentity,
            assertionActive: Bool
        ) throws -> Bool {
            acquired.append((identity, assertionActive))
            return try acquireResult.get()
        }

        func renewLease(
            _ identity: PowerLeaseIdentity,
            assertionActive: Bool
        ) throws -> Bool {
            renewed.append((identity, assertionActive))
            return try renewResult.get()
        }

        func releaseLease(_ identity: PowerLeaseIdentity) throws {
            released.append(identity)
            if let releaseError { throw releaseError }
        }

        func prepareForUnregistration() throws {
            prepareCalls += 1
            if let prepareError { throw prepareError }
        }

        func cancelUnregistration() throws {
            cancelCalls += 1
            if let cancelError { throw cancelError }
        }
    }

    func testObjectiveCProtocolCanBackAnNSXPCInterface() {
        XCTAssertNotNil(NSXPCInterface(with: DetachPowerHelperXPCProtocol.self))
    }

    func testRealTransportFailsClosedForUnknownMachService() {
        let transport = NSXPCPowerHelperTransport(
            machServiceName: "dev.tsarev.detach.tests.\(UUID().uuidString)",
            timeout: 0.1,
            initialAcquireBudget: 10)
        let identity = PowerLeaseIdentity(sessionName: "session", runToken: "token")

        assertTransportFailure { _ = try transport.statusData() }
        assertTransportFailure {
            _ = try transport.acquireLease(identity, assertionActive: true)
        }
        assertTransportFailure {
            _ = try transport.renewLease(identity, assertionActive: true)
        }
        assertTransportFailure { try transport.releaseLease(identity) }
        assertTransportFailure { try transport.prepareForUnregistration() }
        assertTransportFailure { try transport.cancelUnregistration() }
    }

    func testReplyTimesOutAndAcceptsOnlyTheFirstResolution() throws {
        let unanswered = PowerHelperXPCReply<Bool>()
        XCTAssertThrowsError(try unanswered.wait(timeout: 0.01)) { error in
            XCTAssertEqual(error as? PowerHelperXPCError, .timedOut)
        }

        let answered = PowerHelperXPCReply<Bool>()
        answered.resolve(.success(true))
        answered.resolve(.success(false))
        XCTAssertTrue(try answered.wait(timeout: 0.01))
    }

    func testClientDeadlineCoversWorstCaseSerializedRootMutation() {
        XCTAssertGreaterThan(
            NSXPCPowerHelperTransport.defaultTimeout,
            RootProcessCommandRunner.defaultTimeout * 5
                + RootProcessCommandRunner.defaultTerminationGrace)
        XCTAssertLessThan(
            NSXPCPowerHelperTransport.defaultStatusTimeout,
            NSXPCPowerHelperTransport.defaultTimeout)
        XCTAssertLessThan(
            NSXPCPowerHelperTransport.defaultStatusTimeout,
            15,
            "read-only status must finish before detach doctor times out")
        XCTAssertLessThan(
            NSXPCPowerHelperTransport.defaultInitialAcquireBudget,
            NSXPCPowerHelperTransport.defaultTimeout / 3 + 0.001)
    }

    func testPublicErrorsDescribeFailuresPrecisely() {
        XCTAssertEqual(
            PowerHelperLifecycleError.activeLeases.localizedDescription,
            "active power leases prevent helper unregistration")
        XCTAssertEqual(
            PowerHelperLifecycleError.serviceQuiescing.localizedDescription,
            "power helper is preparing to unregister")
        XCTAssertEqual(
            PowerHelperXPCError.unavailable("connection invalidated")
                .localizedDescription,
            "power helper is unavailable: connection invalidated")
        XCTAssertEqual(
            PowerHelperXPCError.timedOut.localizedDescription,
            "power helper request timed out")
        XCTAssertEqual(
            PowerHelperXPCError.invalidReply.localizedDescription,
            "power helper returned an invalid reply")
    }

    func testStatusDecodesHelperSnapshot() throws {
        let transport = FakeTransport()
        let expected = PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: true,
            closedLidProtectionActive: true,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false)
        transport.statusResult = .success(try JSONEncoder().encode(expected))
        let client = PowerHelperXPCClient(transport: transport)

        XCTAssertEqual(try client.status(), expected)
    }

    func testUnavailableHelperProducesHonestReportableStatus() throws {
        let transport = FakeTransport()
        transport.statusResult = .failure(ExpectedFailure())
        let client = PowerHelperXPCClient(transport: transport)
        let status = try client.status()

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.leaseCount, 0)
        XCTAssertFalse(status.assertionActive)
        XCTAssertFalse(status.closedLidProtectionActive)
        XCTAssertFalse(status.helperReachable)

        let result = try DetachPowerCommand(helperClient: client).execute(
            arguments: ["status", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        guard case let .statusJSON(data) = result else {
            return XCTFail("expected status JSON")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "unavailable")
        XCTAssertEqual(object["helper_reachable"] as? Bool, false)
    }

    func testMalformedHelperSnapshotAlsoFailsClosed() throws {
        let transport = FakeTransport()
        transport.statusResult = .success(Data("not-json".utf8))

        let status = try PowerHelperXPCClient(transport: transport).status()

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.leaseCount, 0)
        XCTAssertFalse(status.assertionActive)
        XCTAssertFalse(status.closedLidProtectionActive)
        XCTAssertFalse(status.helperReachable)
        XCTAssertFalse(status.transitionInProgress)
        XCTAssertFalse(status.lowBattery)
    }

    func testLeaseConfirmationIsForwardedWithoutGuessing() throws {
        let transport = FakeTransport()
        transport.acquireResult = .success(false)
        transport.renewResult = .success(true)
        let client = PowerHelperXPCClient(transport: transport)
        let identity = PowerLeaseIdentity(sessionName: "session", runToken: "token")

        XCTAssertFalse(try client.acquireLease(identity, assertionActive: true))
        XCTAssertTrue(try client.renewLease(identity, assertionActive: true))
        try client.releaseLease(identity)

        XCTAssertEqual(transport.acquired.first?.0, identity)
        XCTAssertEqual(transport.acquired.first?.1, true)
        XCTAssertEqual(transport.renewed.first?.0, identity)
        XCTAssertEqual(transport.released, [identity])
    }

    func testMutationFailuresAreForwardedWithoutBeingReclassified() {
        let transport = FakeTransport()
        transport.acquireResult = .failure(ExpectedFailure())
        transport.renewResult = .failure(ExpectedFailure())
        transport.releaseError = ExpectedFailure()
        let client = PowerHelperXPCClient(transport: transport)
        let identity = PowerLeaseIdentity(sessionName: "session", runToken: "token")

        XCTAssertThrowsError(
            try client.acquireLease(identity, assertionActive: false)
        ) { XCTAssertTrue($0 is ExpectedFailure) }
        XCTAssertThrowsError(
            try client.renewLease(identity, assertionActive: false)
        ) { XCTAssertTrue($0 is ExpectedFailure) }
        XCTAssertThrowsError(try client.releaseLease(identity)) {
            XCTAssertTrue($0 is ExpectedFailure)
        }

        XCTAssertEqual(transport.acquired.first?.0, identity)
        XCTAssertEqual(transport.acquired.first?.1, false)
        XCTAssertEqual(transport.renewed.first?.0, identity)
        XCTAssertEqual(transport.renewed.first?.1, false)
        XCTAssertEqual(transport.released, [identity])
    }

    func testUnregistrationLifecycleIsForwarded() throws {
        let transport = FakeTransport()
        let client = PowerHelperXPCClient(transport: transport)

        try client.prepareForUnregistration()
        try client.cancelUnregistration()

        XCTAssertEqual(transport.prepareCalls, 1)
        XCTAssertEqual(transport.cancelCalls, 1)
    }

    func testLifecycleServiceErrorsAreMappedToStableClientErrors() {
        let transport = FakeTransport()
        transport.prepareError = NSError(
            domain: PowerHelperXPCService.errorDomain,
            code: PowerHelperXPCService.ErrorCode.activeLeases.rawValue)
        transport.cancelError = NSError(
            domain: PowerHelperXPCService.errorDomain,
            code: PowerHelperXPCService.ErrorCode.serviceQuiescing.rawValue)
        let client = PowerHelperXPCClient(transport: transport)

        XCTAssertThrowsError(try client.prepareForUnregistration()) {
            XCTAssertEqual($0 as? PowerHelperLifecycleError, .activeLeases)
        }
        XCTAssertThrowsError(try client.cancelUnregistration()) {
            XCTAssertEqual($0 as? PowerHelperLifecycleError, .serviceQuiescing)
        }
    }

    func testLifecycleUnknownServiceCodeAndForeignErrorArePreserved() {
        let transport = FakeTransport()
        let unknown = NSError(
            domain: PowerHelperXPCService.errorDomain,
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "future service error"])
        transport.prepareError = unknown
        transport.cancelError = ExpectedFailure()
        let client = PowerHelperXPCClient(transport: transport)

        XCTAssertThrowsError(try client.prepareForUnregistration()) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, PowerHelperXPCService.errorDomain)
            XCTAssertEqual(error.code, 999)
        }
        XCTAssertThrowsError(try client.cancelUnregistration()) {
            XCTAssertTrue($0 is ExpectedFailure)
        }
    }

    private func assertTransportFailure(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let error = error as? PowerHelperXPCError else {
                return XCTFail(
                    "expected typed XPC transport error, got \(error)",
                    file: file,
                    line: line)
            }
            switch error {
            case .unavailable, .timedOut:
                break
            case .invalidReply:
                XCTFail("missing service must not look like an invalid reply",
                        file: file, line: line)
            }
        }
    }
}
