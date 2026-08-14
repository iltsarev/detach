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

    func testLaunchTitleNamesTheSelectedApplication() {
        XCTAssertEqual(
            TerminalLaunchPresentation.title(terminalDisplayName: "iTerm2"),
            "Launch in iTerm2")
    }
}
