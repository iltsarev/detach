import SwiftUI
import DetachKit

enum AppSettings {
    static let defaultDetachPath = ("~/.local/bin/detach" as NSString).expandingTildeInPath
    static let terminalBundleIdentifierKey = "terminalBundleIdentifier"
    static let notificationsEnabledKey = "sessionNotificationsEnabled"
    static let tipsEnabledKey = "tipsEnabled"
    static let lastShownTipIdentifierKey = "lastShownTipIdentifier"
}

@main
struct DetachApp: App {
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @State private var installation = InstallationStore(
        detachPath: AppSettings.defaultDetachPath)
    @StateObject private var updater = UpdaterService()
    @StateObject private var notifications = SessionNotificationService()
    @StateObject private var tips = TipSession()
    @StateObject private var settingsNavigation = SettingsNavigation()

    var body: some Scene {
        Window("Detach", id: "main") {
            let activeDetachPath = installation.hasDistributionPayload
                ? AppSettings.defaultDetachPath : detachPath
            RootView(detachPath: activeDetachPath, pollInterval: pollInterval,
                     installation: installation, notifications: notifications,
                     tips: tips, settingsNavigation: settingsNavigation)
                .id(activeDetachPath) // rebuild the store when the CLI path changes
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }
        Settings {
            SettingsView(
                installation: installation,
                updater: updater,
                notifications: notifications,
                navigation: settingsNavigation)
        }
        .windowResizability(.contentSize)
    }
}
