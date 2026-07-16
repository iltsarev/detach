import Foundation
import XCTest
@testable import DetachKit

final class DetachPowerCommandTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    private final class FakeAssertionController:
        IdleSleepAssertionControlling, @unchecked Sendable
    {
        let events: EventLog
        var acquireError: Error?
        var releaseError: Error?
        var acquisitionActivates = true
        private(set) var isActive = false

        init(events: EventLog) {
            self.events = events
        }

        func acquire() throws -> Bool {
            events.append("assertion.acquire")
            if let acquireError { throw acquireError }
            guard acquisitionActivates else { return false }
            let changed = !isActive
            isActive = true
            return changed
        }

        func release() throws -> Bool {
            events.append("assertion.release")
            if let releaseError { throw releaseError }
            let changed = isActive
            isActive = false
            return changed
        }
    }

    private final class FakeHelperClient:
        PowerHelperClient, PowerHelperLifecycleClient, @unchecked Sendable
    {
        let events: EventLog
        var statusValue = PowerProtectionStatus.derive(
            leaseCount: 0,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false)
        var acquireError: Error?
        var renewError: Error?
        var releaseError: Error?
        var prepareError: Error?
        var cancelError: Error?
        var acquireConfirmed = true
        var renewConfirmed = true
        private(set) var acquired: [(PowerLeaseIdentity, Bool)] = []
        private(set) var renewed: [(PowerLeaseIdentity, Bool)] = []
        private(set) var released: [PowerLeaseIdentity] = []
        private(set) var prepareCalls = 0
        private(set) var cancelCalls = 0

        init(events: EventLog) {
            self.events = events
        }

        func status() throws -> PowerProtectionStatus {
            events.append("helper.status")
            return statusValue
        }

        func acquireLease(
            _ identity: PowerLeaseIdentity,
            assertionActive: Bool
        ) throws -> Bool {
            events.append("helper.acquire")
            if let acquireError { throw acquireError }
            acquired.append((identity, assertionActive))
            return acquireConfirmed
        }

        func renewLease(
            _ identity: PowerLeaseIdentity,
            assertionActive: Bool
        ) throws -> Bool {
            events.append("helper.renew")
            if let renewError { throw renewError }
            renewed.append((identity, assertionActive))
            return renewConfirmed
        }

        func releaseLease(_ identity: PowerLeaseIdentity) throws {
            events.append("helper.release")
            released.append(identity)
            if let releaseError { throw releaseError }
        }

        func prepareForUnregistration() throws {
            events.append("helper.prepare-unregistration")
            prepareCalls += 1
            if let prepareError { throw prepareError }
        }

        func cancelUnregistration() throws {
            events.append("helper.cancel-unregistration")
            cancelCalls += 1
            if let cancelError { throw cancelError }
        }
    }

    private final class FakeChildRunner: ChildCommandRunning, @unchecked Sendable {
        let events: EventLog
        var result = ChildCommandResult(exitCode: 0)
        var error: Error?
        private(set) var commands: [ChildCommand] = []

        init(events: EventLog) {
            self.events = events
        }

        func run(_ command: ChildCommand) throws -> ChildCommandResult {
            events.append("child.run")
            commands.append(command)
            if let error { throw error }
            return result
        }
    }

    private final class FakeReadinessMarker:
        PowerRunReadinessMarking, @unchecked Sendable
    {
        let events: EventLog
        var error: Error?
        private(set) var paths: [String] = []

        init(events: EventLog) {
            self.events = events
        }

        func markReady(atPath path: String) throws {
            events.append("ready.mark")
            paths.append(path)
            if let error { throw error }
        }
    }

    private final class FakeHeartbeatRunner: PowerHeartbeatRunning, @unchecked Sendable {
        let events: EventLog
        var heartbeatCount = 2

        init(events: EventLog) {
            self.events = events
        }

        func run(
            heartbeat: @escaping @Sendable () throws -> Void,
            operation: @escaping @Sendable () throws -> ChildCommandResult
        ) throws -> ChildCommandResult {
            events.append("heartbeat.start")
            defer { events.append("heartbeat.end") }
            for _ in 0..<heartbeatCount {
                try heartbeat()
            }
            return try operation()
        }
    }

    private struct FailingClamshellWatcher: ClamshellStateWatching {
        func run(
            onStateChange: @escaping @Sendable (Bool) -> Void,
            operation: @escaping @Sendable () throws -> ChildCommandResult
        ) throws -> ChildCommandResult {
            throw ExpectedFailure()
        }
    }

    private struct NoopScreenLockRequester: ScreenLockRequesting {
        func requestLock() throws {}
    }

    private func fixture() -> (
        DetachPowerCommand,
        EventLog,
        FakeAssertionController,
        FakeHelperClient,
        FakeChildRunner,
        FakeHeartbeatRunner
    ) {
        let events = EventLog()
        let assertion = FakeAssertionController(events: events)
        let helper = FakeHelperClient(events: events)
        let child = FakeChildRunner(events: events)
        let heartbeat = FakeHeartbeatRunner(events: events)
        return (
            DetachPowerCommand(
                helperClient: helper,
                assertionController: assertion,
                childRunner: child,
                heartbeatRunner: heartbeat),
            events,
            assertion,
            helper,
            child,
            heartbeat)
    }

    func testStatusJSONAddsSchemaAndUsesSnakeCaseContract() throws {
        let (command, events, _, helper, child, _) = fixture()
        helper.statusValue = PowerProtectionStatus.derive(
            leaseCount: 2,
            assertionActive: true,
            closedLidProtectionActive: true,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: false)

        let result = try command.execute(arguments: ["status", "--json"])
        guard case let .statusJSON(data) = result else {
            return XCTFail("expected status JSON")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["state"] as? String, "protected")
        XCTAssertEqual(object["lease_count"] as? Int, 2)
        XCTAssertEqual(object["assertion_active"] as? Bool, true)
        XCTAssertEqual(object["closed_lid_protection_active"] as? Bool, true)
        XCTAssertEqual(object["helper_reachable"] as? Bool, true)
        XCTAssertEqual(object["transition_in_progress"] as? Bool, false)
        XCTAssertEqual(object["low_battery"] as? Bool, false)
        XCTAssertNil(object["leaseCount"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events.values, ["helper.status"])
        XCTAssertTrue(child.commands.isEmpty)
    }

    func testRunAcquiresRenewsAndReleasesBothProtections() throws {
        let (command, events, assertion, helper, child, _) = fixture()
        child.result = ChildCommandResult(exitCode: 23)

        let result = try command.execute(arguments: [
            "run", "--session", "detach-codex-project-1234",
            "--run-token", "token-1", "--",
            "/fixture/provider", "--flag", "value",
        ])

        let identity = PowerLeaseIdentity(
            sessionName: "detach-codex-project-1234", runToken: "token-1")
        XCTAssertEqual(helper.acquired.count, 1)
        XCTAssertEqual(helper.acquired.first?.0, identity)
        XCTAssertEqual(helper.acquired.first?.1, true)
        XCTAssertEqual(helper.renewed.map(\.0), [identity, identity])
        XCTAssertEqual(helper.renewed.map(\.1), [true, true])
        XCTAssertEqual(helper.released, [identity])
        XCTAssertEqual(child.commands, [ChildCommand(
            executable: "/fixture/provider", arguments: ["--flag", "value"])])
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(result, .child(ChildCommandResult(exitCode: 23)))
        XCTAssertEqual(result.exitCode, 23)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "heartbeat.start",
            "helper.renew",
            "helper.renew",
            "child.run",
            "heartbeat.end",
            "helper.release",
            "assertion.release",
        ])
    }

    func testAssertionFailureRefusesToAcquireLeaseOrLaunchChild() {
        let (command, events, assertion, helper, child, _) = fixture()
        assertion.acquireError = ExpectedFailure()

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ]))

        XCTAssertTrue(helper.acquired.isEmpty)
        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertEqual(events.values, ["assertion.acquire", "assertion.release"])
    }

    func testInactiveAssertionRefusesToAcquireLeaseOrLaunchChild() {
        let (command, _, assertion, helper, child, _) = fixture()
        assertion.acquisitionActivates = false

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])) { error in
            XCTAssertEqual(error as? DetachPowerCommandError, .assertionUnavailable)
        }

        XCTAssertTrue(helper.acquired.isEmpty)
        XCTAssertTrue(child.commands.isEmpty)
    }

    func testHelperAcquireFailureRefusesChildAndAttemptsFullCleanup() {
        let (command, events, assertion, helper, child, _) = fixture()
        helper.acquireError = ExpectedFailure()

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ]))

        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "helper.release",
            "assertion.release",
        ])
    }

    func testUnconfirmedHelperLeaseRefusesChildAndAttemptsFullCleanup() {
        let (command, events, assertion, helper, child, _) = fixture()
        helper.acquireConfirmed = false

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])) { error in
            XCTAssertEqual(error as? DetachPowerCommandError, .helperLeaseUnavailable)
        }

        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "helper.release",
            "assertion.release",
        ])
    }

    func testHeartbeatFailureRefusesChildAndReleasesProtection() {
        let (command, events, assertion, helper, child, _) = fixture()
        helper.renewError = ExpectedFailure()

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ]))

        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "heartbeat.start",
            "helper.renew",
            "heartbeat.end",
            "helper.release",
            "assertion.release",
        ])
    }

    func testLowBatteryHeartbeatReleasesAssertionButLetsChildFinish() throws {
        let (command, events, assertion, helper, child, heartbeat) = fixture()
        heartbeat.heartbeatCount = 1
        helper.renewConfirmed = false
        helper.statusValue = PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: true,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: true)
        child.result = ChildCommandResult(exitCode: 29)

        let result = try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])

        XCTAssertEqual(result.exitCode, 29)
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(helper.renewed.map(\.1), [true, false])
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "heartbeat.start",
            "helper.renew",
            "helper.status",
            "assertion.release",
            "helper.renew",
            "child.run",
            "heartbeat.end",
            "helper.release",
            "assertion.release",
        ])
    }

    func testChildLaunchFailureReleasesProtection() {
        let (command, events, assertion, _, child, heartbeat) = fixture()
        heartbeat.heartbeatCount = 0
        child.error = ExpectedFailure()

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ]))

        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "heartbeat.start",
            "child.run",
            "heartbeat.end",
            "helper.release",
            "assertion.release",
        ])
    }

    func testClamshellMonitorFailureRefusesChildAndReleasesProtection() {
        let events = EventLog()
        let assertion = FakeAssertionController(events: events)
        let helper = FakeHelperClient(events: events)
        let child = FakeChildRunner(events: events)
        let heartbeat = FakeHeartbeatRunner(events: events)
        heartbeat.heartbeatCount = 0
        let command = DetachPowerCommand(
            helperClient: helper,
            assertionController: assertion,
            childRunner: child,
            heartbeatRunner: heartbeat,
            clamshellLockRunner: ClamshellLockRunner(
                watcher: FailingClamshellWatcher(),
                requester: NoopScreenLockRequester()))

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ]))

        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "helper.release",
            "assertion.release",
        ])
    }

    func testReadyFileIsMarkedOnlyAfterBothProtectionsAreConfirmed() throws {
        let events = EventLog()
        let assertion = FakeAssertionController(events: events)
        let helper = FakeHelperClient(events: events)
        let child = FakeChildRunner(events: events)
        let heartbeat = FakeHeartbeatRunner(events: events)
        heartbeat.heartbeatCount = 0
        let readiness = FakeReadinessMarker(events: events)
        let command = DetachPowerCommand(
            helperClient: helper,
            assertionController: assertion,
            childRunner: child,
            heartbeatRunner: heartbeat,
            readinessMarker: readiness)

        let result = try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--ready-file", "/fixture/power-ready", "--",
            "/fixture/provider",
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(readiness.paths, ["/fixture/power-ready"])
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "ready.mark",
            "heartbeat.start",
            "child.run",
            "heartbeat.end",
            "helper.release",
            "assertion.release",
        ])
    }

    func testReadyFileFailureRefusesChildAndReleasesProtection() {
        let events = EventLog()
        let assertion = FakeAssertionController(events: events)
        let helper = FakeHelperClient(events: events)
        let child = FakeChildRunner(events: events)
        let heartbeat = FakeHeartbeatRunner(events: events)
        heartbeat.heartbeatCount = 0
        let readiness = FakeReadinessMarker(events: events)
        readiness.error = ExpectedFailure()
        let command = DetachPowerCommand(
            helperClient: helper,
            assertionController: assertion,
            childRunner: child,
            heartbeatRunner: heartbeat,
            readinessMarker: readiness)

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--ready-file", "/fixture/power-ready", "--",
            "/fixture/provider",
        ]))

        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "ready.mark",
            "helper.release",
            "assertion.release",
        ])
    }

    func testInvalidRunSyntaxHasNoSideEffects() {
        let (command, events, _, _, child, _) = fixture()

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--", "/fixture/provider",
        ])) { error in
            guard case .usage = error as? DetachPowerCommandError else {
                return XCTFail("expected usage error, got \(error)")
            }
        }

        XCTAssertTrue(events.values.isEmpty)
        XCTAssertTrue(child.commands.isEmpty)
    }

    func testOfflinePackagingSmokeHasNoHelperOrRuntimeSideEffects() {
        let (command, events, assertion, helper, child, _) = fixture()

        XCTAssertThrowsError(try command.execute(arguments: [
            "__detach-packaging-smoke__",
        ])) { error in
            guard case .usage = error as? DetachPowerCommandError else {
                return XCTFail("expected usage error, got \(error)")
            }
        }

        XCTAssertTrue(events.values.isEmpty)
        XCTAssertFalse(assertion.isActive)
        XCTAssertTrue(helper.acquired.isEmpty)
        XCTAssertTrue(helper.renewed.isEmpty)
        XCTAssertTrue(helper.released.isEmpty)
        XCTAssertEqual(helper.prepareCalls, 0)
        XCTAssertEqual(helper.cancelCalls, 0)
        XCTAssertTrue(child.commands.isEmpty)
    }

    func testHelperLifecycleCommandsUseNarrowXPCMethodsOnly() throws {
        let (command, events, _, helper, child, _) = fixture()

        XCTAssertEqual(
            try command.execute(arguments: [
                "helper", "prepare-unregistration",
            ]),
            .lifecycle)
        XCTAssertEqual(
            try command.execute(arguments: [
                "helper", "cancel-unregistration",
            ]),
            .lifecycle)

        XCTAssertEqual(helper.prepareCalls, 1)
        XCTAssertEqual(helper.cancelCalls, 1)
        XCTAssertEqual(events.values, [
            "helper.prepare-unregistration",
            "helper.cancel-unregistration",
        ])
        XCTAssertTrue(child.commands.isEmpty)
    }

    func testExplicitReleaseIsIdempotentStopFallback() throws {
        let (command, events, _, helper, child, _) = fixture()

        XCTAssertEqual(
            try command.execute(arguments: [
                "release", "--session", "detach-codex-work",
                "--run-token", "run-token",
            ]),
            .lifecycle)

        XCTAssertEqual(helper.released, [PowerLeaseIdentity(
            sessionName: "detach-codex-work", runToken: "run-token")])
        XCTAssertEqual(events.values, ["helper.release"])
        XCTAssertTrue(child.commands.isEmpty)
    }
}
