import AppKit
import XCTest
import SwiftUI
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

    func testDetailIdentityMarkerCannotReadAsAStatusDot() {
        XCTAssertLessThan(
            SessionDetailSignalPresentation.identityMarkerWidth,
            SessionDetailSignalPresentation.identityMarkerHeight)
        XCTAssertGreaterThanOrEqual(
            SessionDetailSignalPresentation.identityMarkerHeight,
            SessionDetailSignalPresentation.identityMarkerWidth * 3)
    }

    func testPreviewUsesTheRuntimeTintStrengths() {
        XCTAssertEqual(
            SessionDetailSignalPresentation.identityTintPercent(for: .running),
            55)
        XCTAssertEqual(
            SessionDetailSignalPresentation.identityTintPercent(for: .completed),
            25)
        XCTAssertEqual(
            SessionDetailSignalPresentation.identityTintPercent(for: .recoverable),
            45)
    }

    func testEveryTypedPowerStateHasItsOwnExpectedSignalColor() throws {
        try assertColorsEqual(
            SessionDetailSignalPresentation.powerColor(for: .protected),
            Brand.teal)
        for state in [
            PowerProtectionState.transitioning,
            .lowBattery,
            .temperature,
        ] {
            try assertColorsEqual(
                SessionDetailSignalPresentation.powerColor(for: state),
                .orange)
        }
        try assertColorsEqual(
            SessionDetailSignalPresentation.powerColor(for: .unavailable),
            .red)
        for state in [
            PowerProtectionState.allowed,
            .unknown,
            nil,
        ] {
            try assertColorsEqual(
                SessionDetailSignalPresentation.powerColor(for: state),
                Color.white.opacity(0.70))
        }
    }

    private func assertColorsEqual(
        _ actual: Color,
        _ expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actualRGB = try XCTUnwrap(
            NSColor(actual).usingColorSpace(.deviceRGB),
            file: file, line: line)
        let expectedRGB = try XCTUnwrap(
            NSColor(expected).usingColorSpace(.deviceRGB),
            file: file, line: line)
        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.alphaComponent, expectedRGB.alphaComponent,
                       accuracy: 0.001, file: file, line: line)
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
        let pasteboard = RecordingSessionUUIDPasteboard()
        XCTAssertTrue(
            SessionUUIDPresentation.copy(
                "a9f58f1d-1234-5678-9abc-def012342ed9",
                to: pasteboard))
        XCTAssertTrue(pasteboard.didClear)
        XCTAssertEqual(
            pasteboard.strings[.string],
            "a9f58f1d-1234-5678-9abc-def012342ed9")
    }

    @MainActor
    func testChipBuildsTheWholeCopyControl() {
        _ = SessionUUIDChip(
            uuid: "a9f58f1d-1234-5678-9abc-def012342ed9").body
    }
}

private final class RecordingSessionUUIDPasteboard: SessionUUIDPasteboardWriting {
    private(set) var didClear = false
    private(set) var strings: [NSPasteboard.PasteboardType: String] = [:]

    func clearContents() -> Int {
        didClear = true
        strings.removeAll()
        return 1
    }

    func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool {
        strings[dataType] = string
        return true
    }
}

final class SessionActionPresentationTests: XCTestCase {
    func testInAppActionTitlesDoNotNameAnOuterTerminal() {
        XCTAssertEqual(SessionActionPresentation.inAppTitle(for: .attach), "Reconnect")
        XCTAssertEqual(SessionActionPresentation.inAppTitle(for: .resume), "Resume")
        XCTAssertEqual(SessionActionPresentation.inAppTitle(for: .recover), "Recover")
    }

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
