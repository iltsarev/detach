import AppKit
import SwiftUI
import DetachKit

struct UIE2EConfiguration: Sendable {
    let root: URL
    let cli: URL
    let result: URL
    let fixtureState: URL
    let scenario: String
    let driverBudgetSeconds: Int

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
        let scenario = environment["DETACH_UI_E2E_SCENARIO"] ?? "main"
        guard [
            "main", "failure", "settings", "onboarding-first-run",
            "onboarding-provider", "onboarding-approval",
        ].contains(scenario) else {
            try fail("DETACH_UI_E2E_SCENARIO is unsupported")
        }
        guard let rawDriverBudget = environment["DETACH_UI_E2E_DRIVER_BUDGET"],
              let driverBudgetSeconds = Int(rawDriverBudget),
              (1...30).contains(driverBudgetSeconds) else {
            try fail("DETACH_UI_E2E_DRIVER_BUDGET must be from 1 through 30 seconds")
        }
        return UIE2EConfiguration(
            root: root,
            cli: cli,
            result: try requiredURL("DETACH_UI_E2E_RESULT"),
            fixtureState: try requiredURL("DETACH_UI_E2E_FIXTURE_STATE"),
            scenario: scenario,
            driverBudgetSeconds: driverBudgetSeconds)
    }
}

private struct UIE2EConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AppSettings {
    static let defaultDetachPath = ("~/.local/bin/detach" as NSString).expandingTildeInPath
    static let defaultProjectsDirectoryPath =
        FileManager.default.homeDirectoryForCurrentUser.path
    static let defaultQuickChatDirectoryPath = "/tmp"
    static let defaultQuickChatProvider = Provider.claude.rawValue
    static let uiE2E = UIE2EConfiguration.fromEnvironment()
    static let initialDetachPath = uiE2E?.cli.path ?? defaultDetachPath
    static let defaults = makeDefaults(
        uiE2E: uiE2E,
        bundleIdentifier: Bundle.main.bundleIdentifier)

    static func makeDefaults(
        uiE2E: UIE2EConfiguration?,
        bundleIdentifier: String?
    ) -> UserDefaults {
        guard let uiE2E,
              let bundleIdentifier,
              let defaults = UserDefaults(
                suiteName: bundleIdentifier + ".preferences") else {
            return .standard
        }
        defaults.set(uiE2E.cli.path, forKey: "detachPath")
        defaults.set(false, forKey: notificationsEnabledKey)
        defaults.set(false, forKey: tipsEnabledKey)
        defaults.set(false, forKey: menuBarIconEnabledKey)
        return defaults
    }
    static let terminalBundleIdentifierKey = "terminalBundleIdentifier"
    static let notificationsEnabledKey = "sessionNotificationsEnabled"
    static let tipsEnabledKey = "tipsEnabled"
    static let lastShownTipIdentifierKey = "lastShownTipIdentifier"
    static let menuBarIconEnabledKey = "menuBarIconEnabled"
    static let menuBarShowsSessionCountKey = "menuBarShowsSessionCount"
    static let defaultProjectsDirectoryKey = "defaultProjectsDirectory"
    static let quickChatDirectoryKey = "quickChatDirectory"
    static let quickChatProviderKey = "quickChatProvider"
}

/// App-level navigation requests from surfaces that live outside the main
/// window (the menu bar item).
final class MainNavigation: ObservableObject {
    @Published var requestedSessionID: String?
    @Published var requestsNewSession = false
    @Published var quickChatRequestID: UUID?

    func requestNewSession() {
        requestsNewSession = true
    }

    func requestQuickChat() {
        quickChatRequestID = UUID()
    }

    func requestSession(_ sessionID: String) {
        requestedSessionID = sessionID
    }
}

struct SessionCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var navigation: MainNavigation
    let store: SessionStore
    let shortcuts: SessionShortcutRegistry

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.string("New session")) {
                navigation.requestNewSession()
                showMainWindow()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(L10n.string("Quick chat")) {
                navigation.requestQuickChat()
                showMainWindow()
            }
            .keyboardShortcut("t", modifiers: .command)
        }

        CommandMenu(L10n.string("Sessions")) {
            ForEach(Array(SessionShortcutRegistry.slots), id: \.self) { slot in
                Button(L10n.format("Session %d", slot)) {
                    shortcuts.reconcile(store.sessions)
                    guard let sessionID = shortcuts.sessionID(
                        for: slot) else { return }
                    navigation.requestSession(sessionID)
                    showMainWindow()
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(slot))),
                    modifiers: .command)
            }
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
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
    @StateObject private var sessionShortcuts = SessionShortcutRegistry()

    var body: some Scene {
        Window("Detach", id: "main") {
            let activeDetachPath = installation.hasDistributionPayload
                ? AppSettings.defaultDetachPath : detachPath
            RootView(detachPath: activeDetachPath,
                     installation: installation, store: sessionStore,
                     navigation: mainNavigation,
                     shortcuts: sessionShortcuts,
                     notifications: notifications,
                     tips: tips, settingsNavigation: settingsNavigation)
                .id(activeDetachPath) // reattach tasks when the CLI path changes
        }
        .commands {
            SessionCommands(
                navigation: mainNavigation,
                store: sessionStore,
                shortcuts: sessionShortcuts)
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
