import XCTest
import DetachKit
@testable import DetachApp

final class EmptySessionsGuideTests: XCTestCase {
    func testGuideShowsBothSupportedProviders() {
        XCTAssertEqual(
            EmptySessionsGuide.examples(detachCommand: "~/.local/bin/detach").map(\.provider),
            [.codex, .claude])
    }

    func testGuideUsesCommandsThatStartFromTheProjectDirectory() {
        XCTAssertEqual(
            EmptySessionsGuide.examples(detachCommand: "~/.local/bin/detach"),
            [
                EmptySessionExample(
                    provider: .codex,
                    directoryCommand: "cd ~/my/repo",
                    launchCommand: "~/.local/bin/detach codex"),
                EmptySessionExample(
                    provider: .claude,
                    directoryCommand: "cd ~/my/repo",
                    launchCommand: "~/.local/bin/detach claude"),
            ])
    }
}
