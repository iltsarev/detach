import XCTest
@testable import DetachApp

final class UIE2EConfigurationTests: XCTestCase {
    func testAcceptsOnlyContainedStrippedBackgroundBundle() throws {
        try withFixture { fixture in
            let configuration = try fixture.validate()

            XCTAssertEqual(
                configuration.cli.resolvingSymlinksInPath().path,
                fixture.cli.resolvingSymlinksInPath().path)
            XCTAssertEqual(
                configuration.result.deletingLastPathComponent().path,
                configuration.root.path)
            XCTAssertEqual(configuration.result.lastPathComponent, "result.json")
        }
    }

    func testRejectsLexicalPathEscape() throws {
        try withFixture { fixture in
            var environment = fixture.environment
            environment["DETACH_UI_E2E_RESULT"] = fixture.root.path + "/../result.json"

            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("escapes"))
            }
        }
    }

    func testRejectsSymlinkPathEscape() throws {
        try withFixture { fixture in
            let outside = URL(fileURLWithPath:
                "/private/tmp/detach-ui-e2e-outside.\(UUID().uuidString)",
                isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(
                at: outside, withIntermediateDirectories: true)
            let link = fixture.root.appendingPathComponent("escape")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: outside)
            var environment = fixture.environment
            environment["DETACH_UI_E2E_RESULT"] = link
                .appendingPathComponent("result.json").path

            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("escapes"))
            }
        }
    }

    func testRejectsProductionPayload() throws {
        try withFixture { fixture in
            try FileManager.default.createDirectory(
                at: fixture.bundle.appendingPathComponent(
                    "Contents/Resources/DetachCLI", isDirectory: true),
                withIntermediateDirectories: true)

            XCTAssertThrowsError(try fixture.validate()) { error in
                XCTAssertTrue(error.localizedDescription.contains("production payload"))
            }
        }
    }

    func testRejectsForegroundOrProductionIdentity() throws {
        try withFixture { fixture in
            XCTAssertThrowsError(try fixture.validate(
                bundleIdentifier: "dev.tsarev.detach", isBackgroundApp: true))
            XCTAssertThrowsError(try fixture.validate(isBackgroundApp: false))
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try body(fixture)
    }
}

private struct Fixture {
    let root: URL
    let bundle: URL
    let cli: URL
    let result: URL
    let environment: [String: String]

    init() throws {
        root = URL(fileURLWithPath:
            "/private/tmp/detach-ui-e2e.unit.\(UUID().uuidString)",
            isDirectory: true)
        bundle = root.appendingPathComponent("Detach-UI-E2E.app", isDirectory: true)
        cli = root.appendingPathComponent("fake/detach")
        result = root.appendingPathComponent("result.json")
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(
            atPath: cli.path,
            contents: Data("#!/bin/bash\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]))
        environment = [
            "DETACH_UI_E2E_ROOT": root.path,
            "HOME": root.appendingPathComponent("home").path,
            "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "DETACH_STATE_ROOT": root.appendingPathComponent("state/detach").path,
            "DETACH_POWER_STATE_ROOT": root.appendingPathComponent("power").path,
            "DETACH_UI_E2E_CLI": cli.path,
            "DETACH_UI_E2E_RESULT": result.path,
            "DETACH_UI_E2E_FIXTURE_STATE": root.appendingPathComponent("fake/state").path,
        ]
    }

    func validate(
        _ environment: [String: String]? = nil,
        bundleIdentifier: String? = "dev.tsarev.detach.ui-e2e.unit",
        isBackgroundApp: Bool = true
    ) throws -> UIE2EConfiguration {
        try UIE2EConfiguration.validated(
            environment ?? self.environment,
            bundleURL: bundle,
            bundleIdentifier: bundleIdentifier,
            isBackgroundApp: isBackgroundApp)
    }
}
