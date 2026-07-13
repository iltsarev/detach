import SwiftUI
import DetachKit

enum AppSettings {
    static let defaultDetachPath = ("~/.local/bin/detach" as NSString).expandingTildeInPath
}

@main
struct DetachApp: App {
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @State private var installation = InstallationStore(
        detachPath: AppSettings.defaultDetachPath)
    @StateObject private var updater = UpdaterService()

    var body: some Scene {
        WindowGroup("Detach") {
            let activeDetachPath = installation.hasDistributionPayload
                ? AppSettings.defaultDetachPath : detachPath
            RootView(detachPath: activeDetachPath, pollInterval: pollInterval,
                     installation: installation)
                .id(activeDetachPath) // rebuild the store when the CLI path changes
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }
        Settings {
            SettingsView(installation: installation, updater: updater)
        }
    }
}
