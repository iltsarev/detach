import Foundation
import XCTest
@testable import DetachKit

final class PowerHelperXPCClientTests: XCTestCase {
    private struct ExpectedFailure: Error {}

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

    func testClientDeadlineCoversWorstCaseSerializedRootMutation() {
        XCTAssertGreaterThan(
            NSXPCPowerHelperTransport.defaultTimeout,
            RootProcessCommandRunner.defaultTimeout * 5
                + RootProcessCommandRunner.defaultTerminationGrace)
        XCTAssertLessThan(
            NSXPCPowerHelperTransport.defaultInitialAcquireBudget,
            NSXPCPowerHelperTransport.defaultTimeout / 3 + 0.001)
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

    func testUnregistrationLifecycleIsForwarded() throws {
        let transport = FakeTransport()
        let client = PowerHelperXPCClient(transport: transport)

        try client.prepareForUnregistration()
        try client.cancelUnregistration()

        XCTAssertEqual(transport.prepareCalls, 1)
        XCTAssertEqual(transport.cancelCalls, 1)
    }
}
