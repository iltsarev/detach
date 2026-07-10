import SwiftUI
import DetachKit

enum AppSettings {
    static let defaultDetachPath = ("~/.local/bin/detach" as NSString).expandingTildeInPath
}

@main
struct DetachApp: App {
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0

    var body: some Scene {
        WindowGroup("Detach") {
            RootView(detachPath: detachPath, pollInterval: pollInterval)
                .id(detachPath) // rebuild the store when the CLI path changes
        }
        Settings {
            SettingsView()
        }
    }
}
