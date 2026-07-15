import XCTest
@testable import DetachKit

final class PowerHelperPlatformTests: XCTestCase {
    private final class FakeCommandRunner: RootCommandRunning, @unchecked Sendable {
        var results: [RootCommandResult] = []
        private(set) var commands: [RootCommand] = []

        func run(_ command: RootCommand) throws -> RootCommandResult {
            commands.append(command)
            return results.removeFirst()
        }
    }

    func testRootCommandRunnerTerminatesHungProcess() {
        let runner = RootProcessCommandRunner(
            timeout: 0.05, terminationGrace: 0.05)

        XCTAssertThrowsError(try runner.run(RootCommand(
            executable: "/bin/sleep", arguments: ["5"]))) { error in
            XCTAssertEqual(
                error as? PowerHelperPlatformError,
                .commandTimedOut(executable: "/bin/sleep"))
        }
    }

    func testRootCommandRunnerDrainsButBoundsCapturedOutput() throws {
        let runner = RootProcessCommandRunner(
            timeout: 2, maximumOutputBytes: 1_024)

        let result = try runner.run(RootCommand(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 100000"]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThanOrEqual(result.standardOutput.utf8.count, 1_024)
    }

    func testPMSetBackendReadsAndMutatesOnlyDisableSleepSetting() throws {
        let runner = FakeCommandRunner()
        runner.results = [
            RootCommandResult(exitCode: 0, standardOutput: "System-wide power settings:\n SleepDisabled 1\n"),
            RootCommandResult(exitCode: 0),
        ]
        let backend = PMSetClosedLidProtectionController(runner: runner)

        XCTAssertTrue(try backend.protectionIsEnabled())
        try backend.setProtectionEnabled(false)

        XCTAssertEqual(runner.commands, [
            RootCommand(executable: "/usr/bin/pmset", arguments: ["-g"]),
            RootCommand(
                executable: "/usr/bin/pmset",
                arguments: ["-a", "disablesleep", "0"]),
        ])
    }

    func testPMSetBackendTreatsNeverConfiguredDisableSleepAsOff() throws {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 0,
            standardOutput: "System-wide power settings:\n sleep 1\n")]

        XCTAssertFalse(try PMSetClosedLidProtectionController(runner: runner)
            .protectionIsEnabled())
    }

    func testPMSetBackendRejectsMalformedDisableSleepStatus() {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 0,
            standardOutput: "System-wide power settings:\n SleepDisabled maybe\n")]

        XCTAssertThrowsError(try PMSetClosedLidProtectionController(runner: runner)
            .protectionIsEnabled())
    }

    func testPMSetBackendSurfacesCommandFailure() {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 1,
            standardError: "operation not permitted")]

        XCTAssertThrowsError(
            try PMSetClosedLidProtectionController(runner: runner)
                .setProtectionEnabled(true))
    }

    func testBatterySafetyTripsOnlyOnLowBatteryPower() throws {
        let runner = FakeCommandRunner()
        runner.results = [
            RootCommandResult(
                exitCode: 0,
                standardOutput: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t9%; discharging"),
            RootCommandResult(
                exitCode: 0,
                standardOutput: "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t4%; charging"),
            RootCommandResult(
                exitCode: 0,
                standardOutput: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t42%; discharging"),
        ]
        let reader = PMSetBatterySafetyReader(thresholdPercent: 10, runner: runner)

        XCTAssertTrue(try reader.isLowBattery())
        XCTAssertFalse(try reader.isLowBattery())
        XCTAssertFalse(try reader.isLowBattery())
        XCTAssertEqual(
            runner.commands,
            Array(repeating: RootCommand(
                executable: "/usr/bin/pmset", arguments: ["-g", "batt"]),
                  count: 3))
    }

    func testBatterySafetyFailsClosedOnUnparseableBatteryOutput() {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 0,
            standardOutput: "Now drawing from 'Battery Power'\n unknown")]

        XCTAssertThrowsError(
            try PMSetBatterySafetyReader(runner: runner).isLowBattery())
    }

    func testSecureFileStoreRoundTripsStateWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = SecureFilePowerHelperStateStore(fileURL: url)
        let state = PowerHelperPersistentState(
            ownsClosedLidProtection: true,
            leases: [PowerLease(
                id: "lease", sessionName: "session", runToken: "run",
                renewedAt: Date(timeIntervalSince1970: 123),
                assertionActive: true)])

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
    }

    func testSecureFileStoreRejectsSymlinkStatePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: target.path)

        XCTAssertThrowsError(
            try SecureFilePowerHelperStateStore(fileURL: link).load())
    }

    func testClientCodeRequirementPinsAppleAnchorIdentifierAndTeam() {
        XCTAssertEqual(
            PowerHelperCodeSigningRequirement.client(
                teamIdentifier: "AB12CD34EF"),
            "anchor apple generic and identifier \"dev.tsarev.detach.power\" "
                + "and certificate leaf[subject.OU] = \"AB12CD34EF\"")

        XCTAssertNil(PowerHelperCodeSigningRequirement.client(
            teamIdentifier: "lowercase1"))
        XCTAssertNil(PowerHelperCodeSigningRequirement.client(
            teamIdentifier: "TOO-SHORT"))
        XCTAssertNil(PowerHelperCodeSigningRequirement.client(
            teamIdentifier: "AB12CD34E\""))
    }
}
