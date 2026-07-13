import XCTest
import DetachKit
@testable import DetachApp

final class EmptySessionsGuideTests: XCTestCase {
    func testGuideShowsBothSupportedProviders() {
        XCTAssertEqual(
            EmptySessionsGuide.examples.map(\.provider),
            [.codex, .claude])
    }

    func testGuideUsesCommandsThatStartFromTheProjectDirectory() {
        XCTAssertEqual(
            EmptySessionsGuide.examples,
            [
                EmptySessionExample(
                    provider: .codex,
                    directoryCommand: "cd ~/my/repo",
                    launchCommand: "detach codex"),
                EmptySessionExample(
                    provider: .claude,
                    directoryCommand: "cd ~/my/repo",
                    launchCommand: "detach claude"),
            ])
    }
}
