import AppKit
import SwiftUI
import DetachKit

struct UIE2EConfiguration: Sendable {
    let root: URL
    let cli: URL
    let result: URL
    let fixtureState: URL

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> UIE2EConfiguration? {
        guard environment["DETACH_UI_E2E_ROOT"] != nil else { return nil }
        do {
            return try validated(
                environment,
                bundleURL: bundle.bundleURL,
                bundleIdentifier: bundle.bundleIdentifier,
                isBackgroundApp: bundle.object(
                    forInfoDictionaryKey: "LSUIElement") as? Bool == true)
        } catch {
            fatalError("unsafe Detach UI e2e configuration: \(error.localizedDescription)")
        }
    }

    static func validated(
        _ environment: [String: String],
        bundleURL: URL,
        bundleIdentifier: String?,
        isBackgroundApp: Bool,
        fileManager: FileManager = .default
    ) throws -> UIE2EConfiguration {
        guard let rawRoot = environment["DETACH_UI_E2E_ROOT"] else {
            throw UIE2EConfigurationError("missing DETACH_UI_E2E_ROOT")
        }
        func fail(_ message: String) throws -> Never {
            throw UIE2EConfigurationError(message)
        }
        func normalizedTemporaryPath(_ path: String) -> String {
            if path == "/private/tmp" { return "/tmp" }
            if path.hasPrefix("/private/tmp/") {
                return "/tmp/" + String(path.dropFirst("/private/tmp/".count))
            }
            return path
        }
        guard rawRoot.hasPrefix("/private/tmp/detach-ui-e2e.") else {
            try fail("root must be a process-private /private/tmp directory")
        }
        let lexicalRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
        let root = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let comparisonRoot = normalizedTemporaryPath(root.path)
        guard comparisonRoot.hasPrefix("/tmp/detach-ui-e2e.") else {
            try fail("root must be a process-private /private/tmp directory (resolved \(root.path))")
        }
        let comparisonBundle = normalizedTemporaryPath(
            bundleURL.resolvingSymlinksInPath().standardizedFileURL.path)
        guard comparisonBundle.hasPrefix(comparisonRoot + "/") else {
            try fail("app bundle is outside the private root")
        }
        guard bundleIdentifier?.hasPrefix("dev.tsarev.detach.ui-e2e.") == true,
              isBackgroundApp else {
            try fail("test app does not have an isolated background identity")
        }
        let payload = bundleURL.appendingPathComponent(
            "Contents/Resources/DetachCLI", isDirectory: true)
        guard !fileManager.fileExists(atPath: payload.path) else {
            try fail("test app still contains the production payload")
        }

        func requiredURL(_ key: String, directory: Bool = false) throws -> URL {
            guard let raw = environment[key], !raw.isEmpty else {
                try fail("missing \(key)")
            }
            guard raw.hasPrefix(rawRoot + "/") else {
                try fail("\(key) escapes the lexical private root")
            }
            let lexicalURL = URL(fileURLWithPath: raw, isDirectory: directory)
                .standardizedFileURL
            // Result and state files may not exist yet. Resolve their parent
            // explicitly so an existing symlink cannot hide behind a missing
            // final component.
            let resolvedParent = lexicalURL.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
            let url = resolvedParent.appendingPathComponent(
                lexicalURL.lastPathComponent, isDirectory: directory)
                .standardizedFileURL
            let parent = normalizedTemporaryPath(
                url.deletingLastPathComponent().path)
            guard parent == comparisonRoot
                    || parent.hasPrefix(comparisonRoot + "/") else {
                try fail("\(key) escapes the private root (resolved \(url.path))")
            }
            return url
        }

        for key in ["HOME", "CFFIXED_USER_HOME", "XDG_STATE_HOME",
                    "DETACH_STATE_ROOT", "DETACH_POWER_STATE_ROOT"] {
            _ = try requiredURL(key, directory: true)
        }
        let cli = try requiredURL("DETACH_UI_E2E_CLI")
        guard fileManager.isExecutableFile(atPath: cli.path) else {
            try fail("fake CLI is not executable")
        }
        return UIE2EConfiguration(
            root: root,
            cli: cli,
            result: try requiredURL("DETACH_UI_E2E_RESULT"),
            fixtureState: try requiredURL("DETACH_UI_E2E_FIXTURE_STATE"))
    }
}

private struct UIE2EConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AppSettings {
    static let defaultDetachPath = ("~/.local/bin/detach" as NSString).expandingTildeInPath
    static let uiE2E = UIE2EConfiguration.fromEnvironment()
    static let initialDetachPath = uiE2E?.cli.path ?? defaultDetachPath
    static let defaults: UserDefaults = {
        guard let uiE2E,
              let identifier = Bundle.main.bundleIdentifier,
              let defaults = UserDefaults(suiteName: identifier + ".preferences") else {
            return .standard
        }
        defaults.set(uiE2E.cli.path, forKey: "detachPath")
        defaults.set(0.5, forKey: "pollInterval")
        defaults.set(false, forKey: notificationsEnabledKey)
        defaults.set(false, forKey: tipsEnabledKey)
        defaults.set(false, forKey: menuBarIconEnabledKey)
        return defaults
    }()
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
    @AppStorage("detachPath", store: AppSettings.defaults)
    private var detachPath = AppSettings.initialDetachPath
    @AppStorage("pollInterval", store: AppSettings.defaults) private var pollInterval = 2.0
    @AppStorage(AppSettings.menuBarIconEnabledKey, store: AppSettings.defaults)
    private var menuBarIconEnabled = true
    @AppStorage(AppSettings.menuBarShowsSessionCountKey, store: AppSettings.defaults)
    private var menuBarShowsSessionCount = true
    @State private var installation = InstallationStore(
        detachPath: AppSettings.initialDetachPath,
        powerStateRoot: AppSettings.uiE2E?.root.appendingPathComponent("power"),
        defaults: AppSettings.defaults)
    @State private var sessionStore = SessionStore(
        cli: ProcessDetachCLI(executable: URL(
            fileURLWithPath: AppSettings.initialDetachPath)))
    @State private var storageStore = StorageStore(
        cli: ProcessDetachCLI(executable: URL(
            fileURLWithPath: AppSettings.initialDetachPath)))
    @StateObject private var updater = UpdaterService()
    @StateObject private var notifications = SessionNotificationService()
    @StateObject private var tips = TipSession(defaults: AppSettings.defaults)
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
