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
        var onAcquire: (() -> Void)?
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
            onAcquire?()
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

    private final class NonLifecycleHelperClient:
        PowerHelperClient, @unchecked Sendable
    {
        func status() throws -> PowerProtectionStatus {
            PowerProtectionStatus(
                state: .unavailable,
                leaseCount: 0,
                assertionActive: false,
                closedLidProtectionActive: false,
                helperReachable: false,
                transitionInProgress: false,
                lowBattery: false)
        }

        func acquireLease(
            _ identity: PowerLeaseIdentity,
            assertionActive: Bool
        ) throws -> Bool { false }

        func renewLease(
            _ identity: PowerLeaseIdentity,
            assertionActive: Bool
        ) throws -> Bool { false }

        func releaseLease(_ identity: PowerLeaseIdentity) throws {}
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
        var beforeHeartbeat: (() -> Void)?

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
                beforeHeartbeat?()
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

    func testResultAndErrorContractsHaveStableExitCodesAndDescriptions() {
        XCTAssertEqual(DetachPowerCommandResult.lifecycle.exitCode, 0)
        XCTAssertEqual(
            DetachPowerCommandError.usage("specific usage").localizedDescription,
            "specific usage")
        XCTAssertEqual(
            DetachPowerCommandError.assertionUnavailable.localizedDescription,
            "idle-sleep protection could not be acquired")
        XCTAssertEqual(
            DetachPowerCommandError.helperLeaseUnavailable.localizedDescription,
            "closed-lid protection lease could not be confirmed")
    }

    func testReadinessMarkerAtomicallyCreatesEmptyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let readyFile = directory.appendingPathComponent("ready")

        try FilePowerRunReadinessMarker().markReady(atPath: readyFile.path)

        XCTAssertEqual(try Data(contentsOf: readyFile), Data())
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

    func testAssertionLostDuringHelperAcquireFailsBeforeReadinessOrChild() {
        let (command, events, assertion, helper, child, _) = fixture()
        helper.onAcquire = { _ = try? assertion.release() }

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])) { error in
            XCTAssertEqual(error as? DetachPowerCommandError, .assertionUnavailable)
        }

        XCTAssertTrue(child.commands.isEmpty)
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "assertion.release",
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

    func testHeartbeatWithAlreadyReleasedAssertionReportsLowBatteryWithoutReacquire() throws {
        let (command, events, assertion, helper, child, heartbeat) = fixture()
        heartbeat.heartbeatCount = 1
        heartbeat.beforeHeartbeat = { _ = try? assertion.release() }
        helper.statusValue = PowerProtectionStatus.derive(
            leaseCount: 1,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: true,
            transitionInProgress: false,
            lowBattery: true)
        child.result = ChildCommandResult(exitCode: 17)

        let result = try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])

        XCTAssertEqual(result.exitCode, 17)
        XCTAssertEqual(helper.renewed.map(\.1), [false])
        XCTAssertEqual(events.values, [
            "assertion.acquire",
            "helper.acquire",
            "heartbeat.start",
            "assertion.release",
            "helper.status",
            "helper.renew",
            "child.run",
            "heartbeat.end",
            "helper.release",
            "assertion.release",
        ])
    }

    func testHeartbeatReacquiresLostAssertionBeforeRenewingLease() throws {
        let (command, events, assertion, helper, _, heartbeat) = fixture()
        heartbeat.heartbeatCount = 1
        heartbeat.beforeHeartbeat = { _ = try? assertion.release() }

        _ = try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])

        XCTAssertEqual(helper.renewed.map(\.1), [true])
        XCTAssertEqual(events.values.filter { $0 == "assertion.acquire" }.count, 2)
        XCTAssertEqual(events.values.filter { $0 == "helper.status" }.count, 1)
    }

    func testHeartbeatFailsWhenLostAssertionCannotBeReacquired() {
        let (command, _, assertion, helper, child, heartbeat) = fixture()
        heartbeat.heartbeatCount = 1
        helper.onAcquire = { assertion.acquisitionActivates = false }
        heartbeat.beforeHeartbeat = { _ = try? assertion.release() }

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])) { error in
            XCTAssertEqual(error as? DetachPowerCommandError, .assertionUnavailable)
        }

        XCTAssertTrue(helper.renewed.isEmpty)
        XCTAssertTrue(child.commands.isEmpty)
    }

    func testUnconfirmedRenewalFailsClosedWhenBatteryIsNotLow() {
        let (command, _, _, helper, child, heartbeat) = fixture()
        heartbeat.heartbeatCount = 1
        helper.renewConfirmed = false

        XCTAssertThrowsError(try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])) { error in
            XCTAssertEqual(error as? DetachPowerCommandError, .helperLeaseUnavailable)
        }

        XCTAssertTrue(child.commands.isEmpty)
    }

    func testCleanupFailuresDoNotReplaceSuccessfulChildResult() throws {
        let (command, _, assertion, helper, child, heartbeat) = fixture()
        heartbeat.heartbeatCount = 0
        helper.releaseError = ExpectedFailure()
        assertion.releaseError = ExpectedFailure()
        child.result = ChildCommandResult(exitCode: 41)

        let result = try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--", "/fixture/provider",
        ])

        XCTAssertEqual(result.exitCode, 41)
        XCTAssertEqual(helper.released.count, 1)
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

    func testRunPassesValidatedPIDFileToTheProviderLauncher() throws {
        let (command, _, _, _, child, _) = fixture()

        _ = try command.execute(arguments: [
            "run", "--session", "session", "--run-token", "token",
            "--pid-file", "/fixture/provider.pid", "--",
            "/fixture/provider",
        ])

        XCTAssertEqual(child.commands, [ChildCommand(
            executable: "/fixture/provider",
            arguments: [],
            pidFile: "/fixture/provider.pid")])
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

    func testEveryRunParserFailureIsSpecificAndSideEffectFree() {
        let cases: [([String], String)] = [
            (["run", "--"], "run requires a child command after --"),
            (["run", "--", "/bin/true"], "run requires --session NAME"),
            (["run", "--session", "s", "--", "/bin/true"],
             "run requires --run-token TOKEN"),
            (["run", "--session"], "run requires one --session NAME"),
            (["run", "--session", "a", "--session", "b"],
             "run requires one --session NAME"),
            (["run", "--run-token"], "run requires one --run-token TOKEN"),
            (["run", "--run-token", "a", "--run-token", "b"],
             "run requires one --run-token TOKEN"),
            (["run", "--ready-file", "relative"],
             "--ready-file requires one absolute path"),
            (["run", "--ready-file", "/a", "--ready-file", "/b"],
             "--ready-file requires one absolute path"),
            (["run", "--pid-file", "relative"],
             "--pid-file requires one absolute path"),
            (["run", "--pid-file", "/a", "--pid-file", "/b"],
             "--pid-file requires one absolute path"),
            (["run", "--mystery"], "unknown run option: --mystery"),
            (["run", "--session", "s", "--run-token", "t"],
             "run requires -- COMMAND [ARGS...]"),
        ]

        for (arguments, expectedMessage) in cases {
            let (command, events, _, _, child, _) = fixture()
            XCTAssertThrowsError(try command.execute(arguments: arguments)) { error in
                XCTAssertEqual(
                    (error as? DetachPowerCommandError)?.localizedDescription,
                    expectedMessage,
                    "arguments: \(arguments)")
            }
            XCTAssertTrue(events.values.isEmpty, "arguments: \(arguments)")
            XCTAssertTrue(child.commands.isEmpty, "arguments: \(arguments)")
        }
    }

    func testStatusHelperAndReleaseParserFailuresAreSpecific() {
        let cases: [([String], String)] = [
            (["status"], "usage: detach-power status --json"),
            (["helper", "unknown"],
             "usage: detach-power helper prepare-unregistration|cancel-unregistration"),
            (["release", "--session"],
             "release requires --session NAME and --run-token TOKEN"),
            (["release", "--unknown", "value"],
             "unknown or duplicate release option: --unknown"),
            (["release", "--session", "a", "--session", "b"],
             "unknown or duplicate release option: --session"),
            (["release", "--session", "", "--run-token", "token"],
             "release requires --session NAME and --run-token TOKEN"),
        ]

        for (arguments, expectedMessage) in cases {
            let (command, events, _, _, _, _) = fixture()
            XCTAssertThrowsError(try command.execute(arguments: arguments)) { error in
                XCTAssertEqual(
                    (error as? DetachPowerCommandError)?.localizedDescription,
                    expectedMessage,
                    "arguments: \(arguments)")
            }
            XCTAssertTrue(events.values.isEmpty, "arguments: \(arguments)")
        }
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

    func testHelperLifecycleRequiresTheNarrowLifecycleCapability() {
        let command = DetachPowerCommand(helperClient: NonLifecycleHelperClient())

        XCTAssertThrowsError(try command.execute(arguments: [
            "helper", "prepare-unregistration",
        ])) { error in
            XCTAssertEqual(
                (error as? DetachPowerCommandError)?.localizedDescription,
                "power helper lifecycle client is unavailable")
        }
    }

    func testHelperLifecycleFailuresAreNotSwallowed() {
        let (command, _, _, helper, _, _) = fixture()
        helper.prepareError = ExpectedFailure()
        helper.cancelError = ExpectedFailure()

        XCTAssertThrowsError(try command.execute(arguments: [
            "helper", "prepare-unregistration",
        ])) { XCTAssertTrue($0 is ExpectedFailure) }
        XCTAssertThrowsError(try command.execute(arguments: [
            "helper", "cancel-unregistration",
        ])) { XCTAssertTrue($0 is ExpectedFailure) }
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
