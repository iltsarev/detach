import Foundation
import XCTest
import DetachKit
@testable import DetachApp

private struct RootViewNoopCLI: DetachCLIRunning {
    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

@MainActor
private final class RootViewNotificationCenter: SessionNotificationCenterBackend {
    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        .denied
    }

    func requestAuthorization() async throws -> Bool { false }

    func deliver(_ payload: SessionNotificationPayload) async throws {}
}

@MainActor
final class RootViewTests: XCTestCase {
    func testBuildsInitialDashboardFromTypedStores() {
        let suiteName = "RootViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cli = RootViewNoopCLI()
        let powerStateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-root-view-test-\(UUID().uuidString)")
        let root = RootView(
            detachPath: "/tmp/detach-test",
            installation: InstallationStore(
                detachPath: "/tmp/detach-test",
                powerStateRoot: powerStateRoot,
                defaults: defaults),
            store: SessionStore(cli: cli),
            sessionLogSnapshots: SessionLogSnapshotCache(
                cli: cli,
                configurationID: "root-view-test"),
            terminalScreens: SessionTerminalScreenCache(),
            navigation: MainNavigation(),
            shortcuts: SessionShortcutRegistry(),
            notifications: SessionNotificationService(
                center: RootViewNotificationCenter()),
            tips: TipSession(defaults: defaults),
            settingsNavigation: SettingsNavigation())

        _ = root.body
    }
}
