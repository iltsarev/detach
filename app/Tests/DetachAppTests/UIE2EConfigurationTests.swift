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
            XCTAssertEqual(configuration.scenario, "main")
            XCTAssertEqual(configuration.driverBudgetSeconds, 5)
        }
    }

    func testFromEnvironmentUsesValidatedBundleMetadata() throws {
        try withFixture { fixture in
            let bundle = try XCTUnwrap(Bundle(url: fixture.bundle))
            let configuration = try XCTUnwrap(UIE2EConfiguration.fromEnvironment(
                fixture.environment,
                bundle: bundle))

            XCTAssertEqual(
                configuration.root.path,
                fixture.root.resolvingSymlinksInPath().path)
            XCTAssertEqual(
                configuration.cli.path,
                fixture.cli.resolvingSymlinksInPath().path)
            XCTAssertEqual(configuration.driverBudgetSeconds, 5)
        }
    }

    func testAcceptsOnlyKnownScenarios() throws {
        try withFixture { fixture in
            for scenario in [
                "main", "failure", "settings", "onboarding-first-run",
                "onboarding-provider", "onboarding-approval",
            ] {
                var environment = fixture.environment
                environment["DETACH_UI_E2E_SCENARIO"] = scenario
                XCTAssertEqual(
                    try fixture.validate(environment).scenario, scenario)
            }
            var environment = fixture.environment
            environment["DETACH_UI_E2E_SCENARIO"] = "release"
            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsupported"))
            }
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

    func testRejectsMissingAndUnsafePaths() throws {
        try withFixture { fixture in
            var environment = fixture.environment
            environment.removeValue(forKey: "DETACH_UI_E2E_ROOT")
            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("missing"))
            }

            environment = fixture.environment
            environment["DETACH_UI_E2E_ROOT"] = "/private/tmp/not-detach-ui"
            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("process-private"))
            }

            XCTAssertThrowsError(try fixture.validate(
                bundleURL: fixture.root.deletingLastPathComponent())) { error in
                XCTAssertTrue(error.localizedDescription.contains("outside"))
            }

            environment = fixture.environment
            environment.removeValue(forKey: "DETACH_UI_E2E_RESULT")
            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("missing"))
            }

            environment = fixture.environment
            environment["DETACH_UI_E2E_RESULT"] = "/private/tmp/result.json"
            XCTAssertThrowsError(try fixture.validate(environment)) { error in
                XCTAssertTrue(error.localizedDescription.contains("lexical"))
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fixture.cli.path)
            XCTAssertThrowsError(try fixture.validate()) { error in
                XCTAssertTrue(error.localizedDescription.contains("not executable"))
            }
        }
    }

    func testRejectsMissingOrOutOfRangeDriverBudget() throws {
        try withFixture { fixture in
            for value in [nil, "0", "31", "later"] as [String?] {
                var environment = fixture.environment
                environment["DETACH_UI_E2E_DRIVER_BUDGET"] = value
                XCTAssertThrowsError(try fixture.validate(environment)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("from 1 through 30"))
                }
            }
        }
    }

    func testAppDelegateKeepsMenuBarApplicationAlive() {
        XCTAssertFalse(
            DetachAppDelegate().applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared))
    }

    func testOrdinaryProcessKeepsTheDefaultDetachPath() {
        XCTAssertNil(AppSettings.uiE2E)
        XCTAssertEqual(
            AppSettings.initialDetachPath,
            AppSettings.defaultDetachPath)
    }

    func testIsolatedAppDefaultsStayInTheirPrivateSuite() throws {
        try withFixture { fixture in
            let configuration = try fixture.validate()
            let bundleIdentifier = "dev.tsarev.detach.ui-e2e.defaults.\(UUID())"
            let defaults = AppSettings.makeDefaults(
                uiE2E: configuration,
                bundleIdentifier: bundleIdentifier)
            let suite = bundleIdentifier + ".preferences"
            defer { defaults.removePersistentDomain(forName: suite) }

            XCTAssertEqual(
                defaults.string(forKey: "detachPath"),
                fixture.cli.resolvingSymlinksInPath().path)
            XCTAssertNil(defaults.object(forKey: "pollInterval"))
            XCTAssertFalse(defaults.bool(forKey: AppSettings.notificationsEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: AppSettings.tipsEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: AppSettings.menuBarIconEnabledKey))
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
            at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "Detach",
            "CFBundleIdentifier": "dev.tsarev.detach.ui-e2e.unit",
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(fileManager.createFile(
            atPath: bundle.appendingPathComponent("Contents/MacOS/Detach").path,
            contents: Data("#!/bin/bash\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]))
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
            "DETACH_UI_E2E_DRIVER_BUDGET": "5",
        ]
    }

    func validate(
        _ environment: [String: String]? = nil,
        bundleURL: URL? = nil,
        bundleIdentifier: String? = "dev.tsarev.detach.ui-e2e.unit",
        isBackgroundApp: Bool = true
    ) throws -> UIE2EConfiguration {
        try UIE2EConfiguration.validated(
            environment ?? self.environment,
            bundleURL: bundleURL ?? bundle,
            bundleIdentifier: bundleIdentifier,
            isBackgroundApp: isBackgroundApp)
    }
}
