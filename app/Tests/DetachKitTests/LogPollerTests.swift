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

    func testUnchangedSuccessfulTailClearsAnEarlierErrorWithoutReparsing() async {
        let cli = FakeCLI()
        let key = "codex logs --ansi detach-codex-x-1"
        cli.responses[key] = .success(CLIResult(
            exitCode: 0, stdout: "\u{001B}[1mbold\u{001B}[0m\nplain", stderr: "", timedOut: false))
        let poller = LogPoller(cli: cli, provider: .codex, sessionName: "detach-codex-x-1")
        await poller.fetchOnce()
        let firstAttributed = poller.attributed
        XCTAssertEqual(firstAttributed.string, "bold\nplain")

        cli.responses[key] = .success(CLIResult(
            exitCode: 1, stdout: "", stderr: " temporary failure \n", timedOut: false))
        await poller.fetchOnce()
        XCTAssertEqual(poller.errorText, "temporary failure")

        cli.responses[key] = .success(CLIResult(
            exitCode: 0, stdout: "\u{001B}[1mbold\u{001B}[0m\nplain", stderr: "", timedOut: false))
        await poller.fetchOnce()

        XCTAssertNil(poller.errorText)
        XCTAssertTrue(poller.attributed === firstAttributed)
    }

    func testThrownCLIFailurePublishesLocalizedError() async {
        let cli = FakeCLI()
        cli.responses["claude logs --ansi detach-claude-x-1"] = .failure(FakeError())
        let poller = LogPoller(
            cli: cli, provider: .claude, sessionName: "detach-claude-x-1")

        await poller.fetchOnce()

        XCTAssertFalse(poller.errorText?.isEmpty ?? true)
    }
}
