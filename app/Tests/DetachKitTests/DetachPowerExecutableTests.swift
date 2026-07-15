import Foundation
import XCTest
@testable import DetachKit

final class DetachPowerExecutableTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    private final class FakeCommand: DetachPowerCommandExecuting, @unchecked Sendable {
        var result: Result<DetachPowerCommandResult, Error>
        private(set) var arguments: [[String]] = []

        init(result: Result<DetachPowerCommandResult, Error>) {
            self.result = result
        }

        func execute(arguments: [String]) throws -> DetachPowerCommandResult {
            self.arguments.append(arguments)
            return try result.get()
        }
    }

    private final class FakeOutput: DetachPowerOutputWriting, @unchecked Sendable {
        private(set) var stdout = Data()
        private(set) var stderr = Data()

        func writeStandardOutput(_ data: Data) {
            stdout.append(data)
        }

        func writeStandardError(_ data: Data) {
            stderr.append(data)
        }
    }

    func testStatusWritesOneJSONLineAndReturnsZero() {
        let command = FakeCommand(result: .success(.statusJSON(Data(#"{"schema":1}"#.utf8))))
        let output = FakeOutput()
        let executable = DetachPowerExecutable(command: command, output: output)

        XCTAssertEqual(executable.run(arguments: ["status", "--json"]), 0)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), #"{"schema":1}"# + "\n")
        XCTAssertTrue(output.stderr.isEmpty)
        XCTAssertEqual(command.arguments, [["status", "--json"]])
    }

    func testChildExitCodeIsReturnedExactly() {
        let command = FakeCommand(result: .success(.child(ChildCommandResult(exitCode: 73))))
        let output = FakeOutput()

        XCTAssertEqual(
            DetachPowerExecutable(command: command, output: output).run(arguments: ["run"]),
            73)
        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testUsageErrorReturnsTwo() {
        let command = FakeCommand(result: .failure(
            DetachPowerCommandError.usage("usage: detach-power status --json")))
        let output = FakeOutput()

        XCTAssertEqual(
            DetachPowerExecutable(command: command, output: output).run(arguments: []),
            2)
        XCTAssertEqual(
            String(data: output.stderr, encoding: .utf8),
            "detach-power: usage: detach-power status --json\n")
    }

    func testRuntimeErrorReturnsOne() {
        let command = FakeCommand(result: .failure(ExpectedFailure()))
        let output = FakeOutput()

        XCTAssertEqual(
            DetachPowerExecutable(command: command, output: output).run(arguments: ["status"]),
            1)
        XCTAssertFalse(output.stderr.isEmpty)
    }

    func testActiveLeasesReturnTemporaryFailureForDeferredAppUpdate() {
        let command = FakeCommand(result: .failure(
            PowerHelperLifecycleError.activeLeases))
        let output = FakeOutput()

        XCTAssertEqual(
            DetachPowerExecutable(command: command, output: output).run(
                arguments: ["helper", "prepare-unregistration"]),
            DetachPowerExecutable.temporaryFailureExitCode)
        XCTAssertFalse(output.stderr.isEmpty)
    }
}
