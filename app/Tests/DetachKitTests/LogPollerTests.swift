import XCTest
@testable import DetachKit

@MainActor
final class LogPollerTests: XCTestCase {
    func testFetchTrimsToTailLimit() async {
        let cli = FakeCLI()
        let lines = (1...700).map { "line \($0)" }.joined(separator: "\n")
        cli.responses["claude logs --ansi detach-claude-x-1"] =
            .success(CLIResult(exitCode: 0, stdout: lines, stderr: "", timedOut: false))
        let poller = LogPoller(cli: cli, provider: .claude, sessionName: "detach-claude-x-1")
        await poller.fetchOnce()
        XCTAssertEqual(poller.lines.count, 500)
        XCTAssertEqual(poller.lines.first, "line 201")
        XCTAssertEqual(poller.lines.last, "line 700")
        XCTAssertNil(poller.errorText)
    }

    func testFetchFailureSetsError() async {
        let cli = FakeCLI()
        cli.responses["claude logs --ansi detach-claude-x-1"] =
            .success(CLIResult(exitCode: 1, stdout: "", stderr: "no logs found", timedOut: false))
        let poller = LogPoller(cli: cli, provider: .claude, sessionName: "detach-claude-x-1")
        await poller.fetchOnce()
        XCTAssertEqual(poller.errorText, "no logs found")
    }
}
