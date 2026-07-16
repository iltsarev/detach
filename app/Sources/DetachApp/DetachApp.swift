import AppKit
import SwiftUI
import DetachKit

enum AppSettings {
    static let defaultDetachPath = ("~/.local/bin/detach" as NSString).expandingTildeInPath
    static let terminalBundleIdentifierKey = "terminalBundleIdentifier"
    static let notificationsEnabledKey = "sessionNotificationsEnabled"
    static let tipsEnabledKey = "tipsEnabled"
    static let lastShownTipIdentifierKey = "lastShownTipIdentifier"
    static let menuBarIconEnabledKey = "menuBarIconEnabled"
    static let menuBarShowsSessionCountKey = "menuBarShowsSessionCount"
}

/// App-level navigation requests from surfaces that live outside the main
/// window (the menu bar item).
final class MainNavigation: ObservableObject {
    @Published var requestedSessionID: String?
    @Published var requestsNewSession = false
}

/// Closing the last window must not terminate the app while the menu bar item
/// is the persistent surface. ⌘Q and Quit remain honest termination.
final class DetachAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}

@main
struct DetachApp: App {
    @NSApplicationDelegateAdaptor(DetachAppDelegate.self)
    private var appDelegate
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @AppStorage(AppSettings.menuBarIconEnabledKey)
    private var menuBarIconEnabled = true
    @AppStorage(AppSettings.menuBarShowsSessionCountKey)
    private var menuBarShowsSessionCount = true
    @State private var installation = InstallationStore(
        detachPath: AppSettings.defaultDetachPath)
    @State private var sessionStore = SessionStore(
        cli: ProcessDetachCLI(executable: URL(
            fileURLWithPath: AppSettings.defaultDetachPath)))
    @State private var storageStore = StorageStore(
        cli: ProcessDetachCLI(executable: URL(
            fileURLWithPath: AppSettings.defaultDetachPath)))
    @StateObject private var updater = UpdaterService()
    @StateObject private var notifications = SessionNotificationService()
    @StateObject private var tips = TipSession()
    @StateObject private var settingsNavigation = SettingsNavigation()
    @StateObject private var mainNavigation = MainNavigation()

    var body: some Scene {
        Window("Detach", id: "main") {
            let activeDetachPath = installation.hasDistributionPayload
                ? AppSettings.defaultDetachPath : detachPath
            RootView(detachPath: activeDetachPath, pollInterval: pollInterval,
                     installation: installation, store: sessionStore,
                     navigation: mainNavigation,
                     notifications: notifications,
                     tips: tips, settingsNavigation: settingsNavigation)
                .id(activeDetachPath) // reattach tasks when the CLI path changes
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }
        Settings {
            SettingsView(
                installation: installation,
                sessionStore: sessionStore,
                storageStore: storageStore,
                updater: updater,
                notifications: notifications,
                navigation: settingsNavigation)
        }
        .windowResizability(.contentSize)

        // The insertion binding is our own Settings toggle. Removing the item
        // by dragging it off the menu bar flips the same toggle — safe while
        // the app keeps its regular activation policy (Dock icon stays); an
        // accessory-mode v2 must revisit this before shipping.
        MenuBarExtra(isInserted: $menuBarIconEnabled) {
            MenuBarMenu(
                installation: installation,
                sessionStore: sessionStore,
                showsSessionCount: menuBarShowsSessionCount,
                navigation: mainNavigation)
        } label: {
            MenuBarLabel(
                installation: installation,
                sessionStore: sessionStore,
                showsSessionCount: menuBarShowsSessionCount)
        }
    }
}
