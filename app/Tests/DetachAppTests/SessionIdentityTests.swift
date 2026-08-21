import AppKit
import XCTest
import DetachKit
@testable import DetachApp

final class SessionIdentityTests: XCTestCase {
    func testActiveAndFailedSessionsKeepFullIdentityColor() {
        XCTAssertEqual(SessionIdentity.emphasis(for: .starting), 1)
        XCTAssertEqual(SessionIdentity.emphasis(for: .running), 1)
        XCTAssertEqual(SessionIdentity.emphasis(for: .recovering), 1)
        XCTAssertEqual(SessionIdentity.emphasis(for: .failed), 1)
    }

    func testFinishedAndInterruptedSessionsAreMuted() {
        XCTAssertLessThan(SessionIdentity.emphasis(for: .completed), 1)
        XCTAssertLessThan(SessionIdentity.emphasis(for: .stopped), 1)
        XCTAssertLessThan(SessionIdentity.emphasis(for: .interrupted), 1)
    }
}

final class SessionUUIDPresentationTests: XCTestCase {
    func testShortDisplayKeepsShortValuesAndTruncatesLongUUIDs() {
        XCTAssertEqual(SessionUUIDPresentation.shortDisplay("abc"), "abc")
        XCTAssertEqual(
            SessionUUIDPresentation.shortDisplay("a9f58f1d-1234-5678-9abc-def012342ed9"),
            "a9f58f1d…2ed9")
    }

    func testCopyWritesTheFullUUIDToThePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(
            SessionUUIDPresentation.copy(
                "a9f58f1d-1234-5678-9abc-def012342ed9",
                to: pasteboard))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "a9f58f1d-1234-5678-9abc-def012342ed9")
    }
}

final class SessionActionPresentationTests: XCTestCase {
    func testTerminalActionTitlesNameTheSelectedApplication() {
        XCTAssertEqual(
            SessionActionPresentation.terminalTitle(
                for: .attach,
                terminalDisplayName: "iTerm"),
            "Open in iTerm")
        XCTAssertEqual(
            SessionActionPresentation.terminalTitle(
                for: .resume,
                terminalDisplayName: "Warp"),
            "Resume in Warp")
        XCTAssertEqual(
            SessionActionPresentation.terminalTitle(
                for: .recover,
                terminalDisplayName: "Ghostty"),
            "Recover in Ghostty")
    }
}

@MainActor
final class ContextGaugeTests: XCTestCase {
    func testBuildsEveryContextUsageBand() {
        let sessions = [10, 80, 95].map(makeSession(contextUsedTokens:))

        XCTAssertEqual(sessions.compactMap(\.contextFraction), [0.1, 0.8, 0.95])
        for session in sessions {
            _ = ContextGauge(session: session).body
        }
    }

    private func makeSession(contextUsedTokens: Int) -> Session {
        let json = """
        {"schema":1,"provider":"codex","session_name":"work","name":"work",\
        "effective_status":"running","context_used_tokens":\(contextUsedTokens),\
        "context_window":100}
        """
        let parsed = SessionListParser.parse(json)
        precondition(!parsed.sessions.isEmpty, "fixture must parse")
        return parsed.sessions[0]
    }
}
