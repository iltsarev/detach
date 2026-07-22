import XCTest
@testable import DetachKit

final class TmuxStyleClientTests: XCTestCase {
    func testErrorDescriptionsCoverTimeoutCommandAndEmptyResponse() {
        XCTAssertEqual(
            TmuxStyleClientError.timedOut.errorDescription,
            L10n.string("detach config timed out"))
        XCTAssertEqual(
            TmuxStyleClientError.commandFailed("denied").errorDescription,
            "denied")
        XCTAssertEqual(
            TmuxStyleClientError.invalidResponse("").errorDescription,
            L10n.format(
                "detach returned an unsupported tmux style: %@",
                L10n.string("<empty>")))
        XCTAssertEqual(
            TmuxStyleClientError.invalidResponse("custom").errorDescription,
            L10n.format("detach returned an unsupported tmux style: %@", "custom"))
    }

    func testLoadsStyleThroughConfigGetter() async throws {
        let cli = FakeCLI()
        cli.responses["config tmux-style"] = .success(CLIResult(
            exitCode: 0, stdout: "inherit\n", stderr: "", timedOut: false))

        let style = try await TmuxStyleClient(cli: cli).loadStyle()

        XCTAssertEqual(style, .inherit)
        XCTAssertEqual(cli.calls, [["config", "tmux-style"]])
    }

    func testSavesStyleThroughConfigSetter() async throws {
        let cli = FakeCLI()

        try await TmuxStyleClient(cli: cli).setStyle(.detach)

        XCTAssertEqual(cli.calls, [["config", "tmux-style", "detach"]])
    }

    func testRejectsUnsupportedGetterOutput() async {
        let cli = FakeCLI()
        cli.responses["config tmux-style"] = .success(CLIResult(
            exitCode: 0, stdout: "sometimes\n", stderr: "", timedOut: false))

        do {
            _ = try await TmuxStyleClient(cli: cli).loadStyle()
            XCTFail("expected invalid response")
        } catch {
            XCTAssertEqual(error as? TmuxStyleClientError, .invalidResponse("sometimes"))
        }
    }

    func testReportsCLIErrorAndTimeout() async {
        let failing = FakeCLI()
        failing.responses["config tmux-style inherit"] = .success(CLIResult(
            exitCode: 2, stdout: "", stderr: "config is read-only\n", timedOut: false))
        do {
            try await TmuxStyleClient(cli: failing).setStyle(.inherit)
            XCTFail("expected command failure")
        } catch {
            XCTAssertEqual(
                error as? TmuxStyleClientError,
                .commandFailed("config is read-only"))
        }

        let timedOut = FakeCLI()
        timedOut.responses["config tmux-style"] = .success(CLIResult(
            exitCode: 15, stdout: "", stderr: "", timedOut: true))
        do {
            _ = try await TmuxStyleClient(cli: timedOut).loadStyle()
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? TmuxStyleClientError, .timedOut)
        }
    }

    func testCommandFailureWithoutStderrFallsBackToExitStatus() async {
        let cli = FakeCLI()
        cli.responses["config tmux-style detach"] = .success(CLIResult(
            exitCode: 23, stdout: "", stderr: " \n", timedOut: false))

        do {
            try await TmuxStyleClient(cli: cli).setStyle(.detach)
            XCTFail("expected command failure")
        } catch {
            XCTAssertEqual(
                error as? TmuxStyleClientError,
                .commandFailed(L10n.format("detach config exited with status %d", 23)))
        }
    }
}
