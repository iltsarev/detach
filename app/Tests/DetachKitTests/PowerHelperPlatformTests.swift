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

    func testRootCommandRunnerBoundsBothStreamsAndUsesFixedEnvironment() throws {
        let runner = RootProcessCommandRunner(
            timeout: 2, maximumOutputBytes: 5)

        let result = try runner.run(RootCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$PATH|$LC_ALL\"; printf 123456789 >&2"]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "/usr/")
        XCTAssertEqual(result.standardError, "12345")
    }

    func testRootCommandRunnerCanDiscardAllOutput() throws {
        let result = try RootProcessCommandRunner(
            timeout: 2, maximumOutputBytes: -1
        ).run(RootCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf output; printf error >&2"]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError, "")
    }

    func testRootCommandRunnerReturnsNonzeroProcessStatus() throws {
        let result = try RootProcessCommandRunner(timeout: 2).run(RootCommand(
            executable: "/bin/sh", arguments: ["-c", "exit 23"]))

        XCTAssertEqual(result.exitCode, 23)
    }

    func testRootCommandRunnerSurfacesLaunchFailure() {
        let missingExecutable = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-missing-root-command-\(UUID().uuidString)")
        XCTAssertThrowsError(try RootProcessCommandRunner(timeout: 2).run(
            RootCommand(executable: missingExecutable.path, arguments: [])))
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

    func testPMSetBackendAcceptsLegacyNameAndExplicitOff() throws {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 0,
            standardOutput: "System-wide power settings:\n disablesleep 0\n")]

        XCTAssertFalse(try PMSetClosedLidProtectionController(runner: runner)
            .protectionIsEnabled())
    }

    func testPMSetBackendRejectsMalformedDisableSleepStatus() {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 0,
            standardOutput: "System-wide power settings:\n SleepDisabled maybe\n")]

        XCTAssertThrowsError(try PMSetClosedLidProtectionController(runner: runner)
            .protectionIsEnabled()) { error in
                XCTAssertEqual(
                    error as? PowerHelperPlatformError,
                    .unrecognizedPMSetOutput)
            }
    }

    func testPMSetBackendRejectsAmbiguousAndExtraFieldStatus() {
        for output in [
            "SleepDisabled 1\ndisablesleep 0\n",
            "SleepDisabled 1 trailing\n",
        ] {
            let runner = FakeCommandRunner()
            runner.results = [RootCommandResult(
                exitCode: 0, standardOutput: output)]

            XCTAssertThrowsError(
                try PMSetClosedLidProtectionController(runner: runner)
                    .protectionIsEnabled()
            ) { error in
                XCTAssertEqual(
                    error as? PowerHelperPlatformError,
                    .unrecognizedPMSetOutput)
            }
        }
    }

    func testPMSetBackendSurfacesCommandFailure() {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 1,
            standardError: "operation not permitted")]

        XCTAssertThrowsError(
            try PMSetClosedLidProtectionController(runner: runner)
                .setProtectionEnabled(true)) { error in
                    XCTAssertEqual(
                        error as? PowerHelperPlatformError,
                        .commandFailed(
                            executable: "/usr/bin/pmset",
                            exitCode: 1,
                            message: "operation not permitted"))
                }
    }

    func testPMSetBackendBoundsAndTrimsFailureDetails() {
        let runner = FakeCommandRunner()
        runner.results = [RootCommandResult(
            exitCode: 7,
            standardError: "  " + String(repeating: "x", count: 600) + "  \n")]

        XCTAssertThrowsError(
            try PMSetClosedLidProtectionController(runner: runner)
                .setProtectionEnabled(false)
        ) { error in
            guard case let .commandFailed(executable, exitCode, message) =
                    error as? PowerHelperPlatformError else {
                return XCTFail("expected command failure")
            }
            XCTAssertEqual(executable, "/usr/bin/pmset")
            XCTAssertEqual(exitCode, 7)
            XCTAssertEqual(message.utf8.count, 510)
            XCTAssertFalse(message.hasPrefix(" "))
            XCTAssertFalse(message.hasSuffix(" "))
        }
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
            try PMSetBatterySafetyReader(runner: runner).isLowBattery()) { error in
                XCTAssertEqual(
                    error as? PowerHelperPlatformError,
                    .unrecognizedPMSetOutput)
            }
    }

    func testBatterySafetyUsesLowestBatteryAndClampsThreshold() throws {
        let runner = FakeCommandRunner()
        runner.results = [
            RootCommandResult(
                exitCode: 0,
                standardOutput: "Now drawing from 'Battery Power'\n A 80%; B 0%;"),
            RootCommandResult(
                exitCode: 0,
                standardOutput: "Now drawing from 'Battery Power'\n A 100%;"),
        ]

        XCTAssertTrue(try PMSetBatterySafetyReader(
            thresholdPercent: -20, runner: runner).isLowBattery())
        XCTAssertTrue(try PMSetBatterySafetyReader(
            thresholdPercent: 120, runner: runner).isLowBattery())
    }

    func testBatterySafetyRejectsUnknownPowerSourceAndCommandFailure() {
        let runner = FakeCommandRunner()
        runner.results = [
            RootCommandResult(exitCode: 0, standardOutput: "No power source"),
            RootCommandResult(exitCode: 9, standardError: " denied \n"),
        ]

        XCTAssertThrowsError(
            try PMSetBatterySafetyReader(runner: runner).isLowBattery()
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperPlatformError,
                .unrecognizedPMSetOutput)
        }
        XCTAssertThrowsError(
            try PMSetBatterySafetyReader(runner: runner).isLowBattery()
        ) { error in
            XCTAssertEqual(
                error as? PowerHelperPlatformError,
                .commandFailed(
                    executable: "/usr/bin/pmset",
                    exitCode: 9,
                    message: "denied"))
        }
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
            try SecureFilePowerHelperStateStore(fileURL: link).load()) { error in
                XCTAssertEqual(
                    error as? PowerHelperPlatformError,
                    .insecureStatePath)
            }
    }

    func testSecureFileStoreReturnsNilForMissingState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(try SecureFilePowerHelperStateStore(
            fileURL: root.appendingPathComponent("state.json")).load())
    }

    func testSecureFileStoreRejectsDirectoryAsStateFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try SecureFilePowerHelperStateStore(fileURL: state).load()
        ) { error in
            XCTAssertEqual(error as? PowerHelperPlatformError, .insecureStatePath)
        }
    }

    func testSecureFileStoreRejectsOversizedStateBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: state.path,
            contents: Data(count: SecureFilePowerHelperStateStore.maximumBytes + 1)))

        XCTAssertThrowsError(
            try SecureFilePowerHelperStateStore(fileURL: state).load()
        ) { error in
            XCTAssertEqual(error as? PowerHelperPlatformError, .stateTooLarge)
        }
    }

    func testSecureFileStoreRejectsOversizedEncodedStateBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        let state = PowerHelperPersistentState(leases: [PowerLease(
            id: "lease",
            sessionName: String(
                repeating: "x",
                count: SecureFilePowerHelperStateStore.maximumBytes),
            runToken: "run",
            renewedAt: Date(timeIntervalSince1970: 0),
            assertionActive: true)])

        XCTAssertThrowsError(
            try SecureFilePowerHelperStateStore(fileURL: stateURL).save(state)
        ) { error in
            XCTAssertEqual(error as? PowerHelperPlatformError, .stateTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testSecureFileStoreRejectsSymlinkDirectoryOnSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let realDirectory = root.appendingPathComponent("real")
        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(
            at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: linkedDirectory.path,
            withDestinationPath: realDirectory.path)

        XCTAssertThrowsError(try SecureFilePowerHelperStateStore(
            fileURL: linkedDirectory.appendingPathComponent("state.json"))
            .save(PowerHelperPersistentState())) { error in
                XCTAssertEqual(error as? PowerHelperPlatformError, .insecureStatePath)
            }
    }

    func testSecureFileStoreSurfacesMalformedJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        try Data("not-json".utf8).write(to: stateURL)

        XCTAssertThrowsError(
            try SecureFilePowerHelperStateStore(fileURL: stateURL).load()
        ) { XCTAssertTrue($0 is DecodingError) }
    }

    func testSecureFileStoreRejectsInsecureDirectoryShapesOnSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let ordinaryFile = root.appendingPathComponent("not-a-directory")
        try Data().write(to: ordinaryFile)
        let stateURL = ordinaryFile.appendingPathComponent("state.json")

        XCTAssertThrowsError(try SecureFilePowerHelperStateStore(
            fileURL: stateURL).save(PowerHelperPersistentState())) { error in
                XCTAssertEqual(error as? PowerHelperPlatformError, .insecureStatePath)
            }
    }

    func testSecureFileStoreRepairsExistingDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-power-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let stateURL = root.appendingPathComponent("state.json")

        try SecureFilePowerHelperStateStore(fileURL: stateURL)
            .save(PowerHelperPersistentState())

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: root.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o700)
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

    func testPlatformErrorsHaveActionableStableDescriptions() {
        let cases: [(PowerHelperPlatformError, String)] = [
            (.commandFailed(executable: "/bin/tool", exitCode: 2, message: ""),
             "/bin/tool failed with status 2"),
            (.unrecognizedPMSetOutput, "pmset returned an unrecognized power status"),
            (.insecureStatePath, "power helper state path is not secure"),
            (.stateTooLarge, "power helper state file is too large"),
            (.fileSystem(operation: "write", code: 5),
             "power helper state write failed with errno 5"),
            (.bootSessionUnavailable(code: 6),
             "boot session lookup failed with errno 6"),
            (.unrecognizedBootSession,
             "macOS returned an invalid boot session identifier"),
            (.commandTimedOut(executable: "/bin/tool"), "/bin/tool timed out"),
            (.insecureLifetimeLock,
             "power helper lifetime lock is not secure"),
            (.lifetimeLockBusy,
             "another power helper process still holds the lifetime lock"),
            (.lifetimeLockFileSystem(operation: "open", code: 7),
             "power helper lifetime lock open failed with errno 7"),
            (.insecureSystemHandoffLock,
             "power helper system handoff lock is not secure"),
            (.systemHandoffLockBusy,
             "another user is already updating the power helper"),
            (.systemHandoffLockFileSystem(operation: "lock", code: 8),
             "power helper system handoff lock lock failed with errno 8"),
        ]

        for (error, description) in cases {
            XCTAssertEqual(error.localizedDescription, description)
        }
    }
}
