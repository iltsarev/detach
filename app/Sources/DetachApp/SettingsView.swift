import AppKit
import DetachKit
import SwiftUI
import UniformTypeIdentifiers

struct MacPowerSettingsPresentation: Equatable {
    enum Action: Equatable {
        case approveHelper
        case approveBackground
        case setup
        case repair
        case refresh
    }

    /// Why the Mac is in its current sleep state. Derived from the effective
    /// heartbeat state first; the live session count only enriches the
    /// protected case and never contradicts the heartbeat.
    enum Reason: Equatable {
        case activeSessions(Int)
        case protectionActive
        case noActiveSessions
        case waitingSessions(Int)
        case sessionsNotHolding(Int)
        case lowBattery
        case temperature
        case confirming
        case helperUnreachable
        case noFreshReport
    }

    let state: PowerProtectionState
    let action: Action?
    let reason: Reason

    init(
        state: PowerProtectionState,
        helperStatus: PowerHelperRegistrationStatus,
        watchdogStatus: WatchdogStatus,
        distributionMatchesBundle: Bool,
        activeSessionCount: Int? = nil,
        workingSessionCount: Int? = nil
    ) {
        self.state = state
        if helperStatus == .requiresApproval {
            action = .approveHelper
        } else if watchdogStatus == .requiresApproval {
            action = .approveBackground
        } else if helperStatus != .enabled || watchdogStatus != .enabled {
            action = .setup
        } else if !distributionMatchesBundle || state == .unavailable {
            action = .repair
        } else if state == .unknown {
            action = .refresh
        } else {
            action = nil
        }
        switch state {
        case .protected:
            let protectedCount = workingSessionCount ?? activeSessionCount
            if let protectedCount, protectedCount > 0 {
                reason = .activeSessions(protectedCount)
            } else {
                reason = .protectionActive
            }
        case .allowed:
            // The heartbeat wins, but never claim "no sessions" while the
            // session poller can see live ones.
            if let activeSessionCount, activeSessionCount > 0 {
                if workingSessionCount == 0 {
                    reason = .waitingSessions(activeSessionCount)
                } else {
                    reason = .sessionsNotHolding(activeSessionCount)
                }
            } else {
                reason = .noActiveSessions
            }
        case .lowBattery:
            reason = .lowBattery
        case .temperature:
            reason = .temperature
        case .transitioning:
            reason = .confirming
        case .unavailable:
            reason = .helperUnreachable
        case .unknown:
            reason = .noFreshReport
        }
    }

    var stateLocalizationKey: String {
        switch state {
        case .protected: "Mac stays awake"
        case .allowed: "Mac can sleep"
        case .transitioning: "Enabling sleep protection"
        case .lowBattery: "Mac can sleep: low battery"
        case .temperature: "Mac can sleep: temperature"
        case .unavailable: "Sleep protection unavailable"
        case .unknown: "Sleep status unknown"
        }
    }
}

/// Sessions that Settings and the menu bar count as active work.
enum MacPowerActiveSessions {
    static func active(in sessions: [Session]) -> [Session] {
        sessions.filter {
            switch $0.effectiveStatus {
            case .starting, .running, .recovering: true
            case .hung, .completed, .failed, .interrupted, .stopped,
                 .recoverable, .orphaned, .corrupt, .collision, .unknown: false
            }
        }
    }

    static func counts(in sessions: [Session]) -> (active: Int, working: Int) {
        let active = active(in: sessions)
        return (active.count, active.filter { !$0.isWaitingForUser }.count)
    }
}

/// Heartbeat refresh for Settings → System. The SwiftUI `.task` wrapper
/// only calls this; XCTest cannot map that modifier.
enum SystemTabHeartbeatRefresh {
    static func run(
        refreshPower: () -> Void,
        refreshStorage: () async -> Void,
        sleepNanoseconds: UInt64 = 10_000_000_000
    ) async {
        refreshPower()
        async let storageRefresh: Void = refreshStorage()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                break
            }
            refreshPower()
        }
        await storageRefresh
    }
}

struct PowerHelperSettingsPresentation: Equatable {
    let status: DiagnosticCheck.Status
    let detailLocalizationKey: String?

    init(
        registrationStatus: PowerHelperRegistrationStatus,
        readinessConfirmed: Bool,
        isChecking: Bool = false
    ) {
        if registrationStatus == .enabled, readinessConfirmed {
            status = .ok
            detailLocalizationKey = nil
            return
        }

        if isChecking,
           registrationStatus == .enabled || registrationStatus == .unavailable {
            status = .unknown
            detailLocalizationKey = nil
            return
        }

        status = .error
        switch registrationStatus {
        case .enabled:
            detailLocalizationKey =
                "The native power helper is registered, but its live check failed."
        case .requiresApproval:
            detailLocalizationKey =
                "One-time administrator approval is required for native sleep protection."
        case .notRegistered:
            detailLocalizationKey = "The native power helper is not registered yet."
        case .unavailable:
            detailLocalizationKey = "The native power helper is unavailable."
        }
    }
}

private extension SettingsDestination {
    /// Content height measured at the default text size; the window follows
    /// the selected tab like classic AppKit preference panes.
    var baseHeight: CGFloat {
        switch self {
        case .general: 620
        case .terminal: 460
        case .notifications: 350
        case .system: 860
        case .updates: 420
        }
    }
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let installation: InstallationStore
    /// The app-level shared session poller. Settings can be the only open
    /// scene, so CLI path and cadence changes are applied here as well.
    let sessionStore: SessionStore
    let storageStore: StorageStore
    @ObservedObject var updater: UpdaterService
    @ObservedObject var notifications: SessionNotificationService
    @ObservedObject var navigation: SettingsNavigation

    @AppStorage("detachPath", store: AppSettings.defaults)
    private var detachPath = AppSettings.initialDetachPath
    @AppStorage("pollInterval", store: AppSettings.defaults) private var pollInterval = 2.0
    @AppStorage(AppFontSize.storageKey, store: AppSettings.defaults)
    private var fontPointSize = AppFontSize.defaultValue
    @AppStorage(AppSettings.terminalBundleIdentifierKey, store: AppSettings.defaults)
    private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier
    @AppStorage(AppSettings.notificationsEnabledKey, store: AppSettings.defaults)
    private var notificationsEnabled = false
    @AppStorage(AppSettings.tipsEnabledKey, store: AppSettings.defaults)
    private var tipsEnabled = true
    @AppStorage(AppSettings.menuBarIconEnabledKey, store: AppSettings.defaults)
    private var menuBarIconEnabled = true
    @AppStorage(AppSettings.menuBarShowsSessionCountKey, store: AppSettings.defaults)
    private var menuBarShowsSessionCount = true
    @AppStorage(AppSettings.defaultProjectsDirectoryKey, store: AppSettings.defaults)
    private var defaultProjectsDirectoryPath =
        AppSettings.defaultProjectsDirectoryPath
    @AppStorage(AppSettings.quickChatDirectoryKey, store: AppSettings.defaults)
    private var quickChatDirectoryPath = AppSettings.defaultQuickChatDirectoryPath
    @AppStorage(AppSettings.quickChatProviderKey, store: AppSettings.defaults)
    private var quickChatProvider = AppSettings.defaultQuickChatProvider

    @State private var terminalApplications: [TerminalApplication] = []
    @State private var terminalIcons: [String: NSImage] = [:]
    // The selected terminal when it is not in the auto-detected list — chosen
    // through the open panel or detected by an older Detach version.
    @State private var unlistedSelectedTerminal: TerminalApplication?
    @State private var isChoosingTerminalApplication = false
    @State private var terminalChoiceError: String?
    @State private var confirmUninstall = false
    @State private var confirmPurge = false
    @State private var tmuxStyle: TmuxStyle?
    @State private var isUpdatingTmuxStyle = false
    @State private var tmuxStyleError: String?
    @StateObject private var extendedKeys = TmuxExtendedKeysSettingsController()
    @State private var fontSizeDraft: AppFontSizeDraft?
    @State private var selectedStorageSessionIDs = Set<String>()
    @State private var pendingStorageCleanup: [StorageSession] = []
    @State private var confirmStorageCleanup = false
    @State private var storageCleanupError: String?

    private var selectedTerminal: TerminalApplication? {
        terminalApplications.first { $0.bundleIdentifier == terminalBundleIdentifier }
            ?? unlistedSelectedTerminal
    }

    private var selectedTerminalIsMissing: Bool {
        selectedTerminal == nil
    }

    private var activeDetachPath: String {
        installation.hasDistributionPayload ? AppSettings.defaultDetachPath : detachPath
    }

    private var previewFontPointSize: Double {
        fontSizeDraft?.previewValue ?? AppFontSize.clamped(fontPointSize)
    }

    private var previewFontPointSizeBinding: Binding<Double> {
        Binding(
            get: { previewFontPointSize },
            set: { value in
                var draft = fontSizeDraft ?? AppFontSizeDraft(appliedValue: fontPointSize)
                draft.updatePreview(value)
                fontSizeDraft = draft
            })
    }

    private var fontSizePreview: some View {
        ZStack(alignment: .topLeading) {
            // Reserve the largest preview's space so the controls below do
            // not move while the user drags the slider.
            SessionRowPreviewCard()
                .appFontSize(AppFontSize.allowedRange.upperBound)
                .accessibilityHidden(true)
                .hidden()
            SessionRowPreviewCard()
                .appFontSize(previewFontPointSize)
                .accessibilityValue(L10n.format("%d pt", Int(previewFontPointSize)))
        }
    }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            generalTab.tabItem {
                tabLabel(L10n.string("General"), systemImage: "gearshape.fill", color: .systemGray)
            }
            .tag(SettingsDestination.general)
            terminalTab.tabItem {
                tabLabel(L10n.string("Terminal"), systemImage: "terminal.fill",
                         color: NSColor(Brand.teal))
            }
            .tag(SettingsDestination.terminal)
            notificationsTab.tabItem {
                tabLabel(L10n.string("Notifications"), systemImage: "bell.badge.fill",
                         color: .systemRed)
            }
            .tag(SettingsDestination.notifications)
            systemTab.tabItem {
                tabLabel(L10n.string("System"), systemImage: "moon.stars.fill",
                         color: .systemOrange)
                    .accessibilityIdentifier("settings-tab-system")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        if AppSettings.uiE2E != nil {
                            UIE2EGeometryProbe(identifier: "settings-tab-system")
                        }
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
            .tag(SettingsDestination.system)
            updatesTab.tabItem {
                tabLabel(L10n.string("Updates"), systemImage: "arrow.triangle.2.circlepath",
                         color: NSColor(Brand.indigo))
            }
            .tag(SettingsDestination.updates)
        }
        .appFontSize(fontPointSize)
        .frame(width: AppFontSize.settingsWidth(for: fontPointSize))
        .background(SettingsWindowFrame(
            width: AppFontSize.settingsWidth(for: fontPointSize),
            baseHeight: navigation.selectedTab.baseHeight,
            fontPointSize: fontPointSize))
        .task {
            let clampedFontPointSize = AppFontSize.clamped(fontPointSize)
            if fontSizeDraft == nil {
                fontSizeDraft = AppFontSizeDraft(appliedValue: clampedFontPointSize)
            }
            if fontPointSize != clampedFontPointSize {
                fontPointSize = clampedFontPointSize
            }
            refreshTerminalApplications()
            await notifications.configure(enabled: notificationsEnabled)
            await installation.refreshContext()
        }
        .task(id: activeDetachPath) {
            await storageStore.configure(cli: ProcessDetachCLI(
                executable: URL(fileURLWithPath: activeDetachPath)))
            await loadTmuxStyle()
            await extendedKeys.load(detachPath: activeDetachPath)
        }
        .task(id: navigation.selectedTab) {
// quality-coverage:begin system-heartbeat
            guard navigation.selectedTab == .system else { return }
            await SystemTabHeartbeatRefresh.run(
                refreshPower: { installation.refreshPowerProtectionState() },
                refreshStorage: { await storageStore.refresh() })
// quality-coverage:end system-heartbeat
        }
        .onChange(of: fontPointSize) { _, value in
            let clamped = AppFontSize.clamped(value)
            if value != clamped {
                fontPointSize = clamped
                return
            }
            guard var draft = fontSizeDraft else { return }
            draft.synchronizeAppliedValue(clamped)
            fontSizeDraft = draft
        }
        .onChange(of: pollInterval) { _, value in
            sessionStore.startPolling(interval: value)
        }
        .onChange(of: detachPath) { _, _ in
            Task {
                await sessionStore.configure(cli: ProcessDetachCLI(
                    executable: URL(fileURLWithPath: activeDetachPath)))
                await storageStore.configure(cli: ProcessDetachCLI(
                    executable: URL(fileURLWithPath: activeDetachPath)))
            }
        }
        .onChange(of: storageStore.report) { _, report in
            let eligible = Set(report?.sessions.filter(\.deletable).map(\.id) ?? [])
            selectedStorageSessionIDs.formIntersection(eligible)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await notifications.refreshAuthorizationStatus()
                await installation.refreshContext()
                if !isUpdatingTmuxStyle {
                    await loadTmuxStyle()
                }
                if navigation.selectedTab == .system {
                    await storageStore.refresh()
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // A Settings scene can remain open without the main window. The
            // AppKit activation notification reliably fires after the user
            // returns from macOS Notification settings in that configuration.
            Task {
                await notifications.refreshAuthorizationStatus()
                await installation.refreshContext()
            }
        }
        .onDisappear {
            fontSizeDraft = nil
        }
        .confirmationDialog(
            L10n.string("Remove installed Detach components?"),
            isPresented: $confirmUninstall,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove, keeping checkpoints"), role: .destructive) {
                Task { await installation.uninstall(purgeState: false) }
            }
        } message: {
            Text(L10n.string("Detach.app will remain in place and can reinstall the CLI."))
        }
        .confirmationDialog(
            L10n.string("Remove the CLI and all saved sessions?"),
            isPresented: $confirmPurge,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove permanently"), role: .destructive) {
                Task { await installation.uninstall(purgeState: true) }
            }
        } message: {
            Text(L10n.string(
                "Detach checkpoint/state directories will be deleted. The ~/.codex and ~/.claude stores won't be affected."))
        }
        .confirmationDialog(
            L10n.string("Delete selected Detach session data?"),
            isPresented: $confirmStorageCleanup,
            titleVisibility: .visible
        ) {
            Button(
                L10n.format("Delete %@", storageSize(
                    storageTotal(pendingStorageCleanup))),
                role: .destructive
            ) {
                Task { await performStorageCleanup() }
            }
        } message: {
            Text(storageCleanupDescription)
        }
    }

    private func tabLabel(
        _ title: String,
        systemImage: String,
        color: NSColor
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: SettingsTabIcon.image(systemName: systemImage, color: color))
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(L10n.string("Interface")) {
                fontSizePreview
                HStack(spacing: 8) {
                    Text(L10n.string("Text size"))
                        .accessibilityHidden(true)
                    Spacer(minLength: 12)
                    Text(verbatim: "A")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(
                        value: previewFontPointSizeBinding,
                        in: AppFontSize.allowedRange,
                        step: 1
                    ) {
                        Text(L10n.string("Text size"))
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel(L10n.string("Text size"))
                    .accessibilityValue(L10n.format("%d pt", Int(previewFontPointSize)))
                    Text(verbatim: "A")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(L10n.format("%d pt", Int(previewFontPointSize)))
                        .appFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                        .accessibilityHidden(true)
                    Button(L10n.string("Apply")) {
                        applyFontPointSize()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                    .disabled(fontSizeDraft?.hasChanges != true)
                }
                HStack(spacing: 8) {
                    Text(L10n.string("Refresh interval"))
                    Spacer(minLength: 12)
                    Slider(value: $pollInterval, in: 1...10, step: 1) {
                        Text(L10n.string("Refresh interval"))
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text(L10n.format("%d sec", Int(pollInterval)))
                        .appFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                Toggle(L10n.string("Show tips"), isOn: $tipsEnabled)
// quality-coverage:begin ui-e2e-instrumentation
                    .accessibilityIdentifier("settings-show-tips")
#if !DEBUG
                    .overlay(alignment: .trailing) {
                        if AppSettings.uiE2E != nil {
                            UIE2EGeometryProbe(
                                identifier: "settings-show-tips",
                                semanticLabel: L10n.string("Show tips"),
                                semanticRole: .checkBox)
                                .frame(width: 38, height: 18)
                        }
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
            Section(L10n.string("Session defaults")) {
                directoryPreferenceRow(
                    title: L10n.string("Default project folder"),
                    path: $defaultProjectsDirectoryPath,
                    accessibilityIdentifier: "settings-default-project-folder")
                Picker(
                    L10n.string("Quick chat provider"),
                    selection: $quickChatProvider
                ) {
                    ForEach(Provider.allCases, id: \.self) { provider in
                        Text(verbatim: provider == .claude ? "Claude Code" : "Codex")
                            .tag(provider.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings-quick-chat-provider")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .overlay {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(
                            identifier: "settings-quick-chat-provider",
                            semanticLabel: L10n.string("Quick chat provider"),
                            semanticRole: .radioGroup)
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
                directoryPreferenceRow(
                    title: L10n.string("Quick chat folder"),
                    path: $quickChatDirectoryPath,
                    accessibilityIdentifier: "settings-quick-chat-folder")
                Text(L10n.string(
                    "⌘N opens New session. ⌘T starts Quick chat immediately."))
                    .settingsMessage()
            }
            Section(L10n.string("Menu Bar")) {
                Toggle(
                    L10n.string("Show Detach in the menu bar"),
                    isOn: $menuBarIconEnabled)
                Toggle(
                    L10n.string("Show active session count next to the icon"),
                    isOn: $menuBarShowsSessionCount)
                    .disabled(!menuBarIconEnabled)
                Text(L10n.string(
                    "You can close the window — the icon keeps showing sleep state. ⌘Q quits Detach; sessions and sleep protection continue on their own."))
                    .settingsMessage()
            }
            Section(L10n.string("Command line")) {
                if installation.hasDistributionPayload {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(L10n.string("CLI"))
                        Spacer(minLength: 12)
                        Text(AppSettings.defaultDetachPath)
                            .appFont(.body, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(AppSettings.defaultDetachPath)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("Path to detach"))
                        TextField(L10n.string("Path to detach"), text: $detachPath)
                            .labelsHidden()
                            .appFont(.body, design: .monospaced)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func directoryPreferenceRow(
        title: String,
        path: Binding<String>,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(path.wrappedValue)
                .appFont(.body, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path.wrappedValue)
            Button(L10n.string("Choose…")) {
                presentDirectoryChooser(path: path)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .overlay {
                if AppSettings.uiE2E != nil {
                    UIE2EGeometryProbe(
                        identifier: accessibilityIdentifier,
                        semanticLabel: title,
                        semanticRole: .button)
                }
            }
#endif
// quality-coverage:end ui-e2e-instrumentation
        }
    }

    @MainActor
    private func presentDirectoryChooser(path: Binding<String>) {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
        let start = DirectoryPreference.configuredOrFallback(
            path: path.wrappedValue,
            fallback: fallback)
        ProjectDirectoryChooser.present(
            from: PanelHostWindow.current(),
            selectedProject: nil,
            defaultDirectory: start
        ) { url in
            guard let url else { return }
            path.wrappedValue = url.standardizedFileURL.path
        }
    }

    private func applyFontPointSize() {
        guard var draft = fontSizeDraft, draft.hasChanges else { return }
        let appliedValue = draft.apply()
        fontSizeDraft = draft
        fontPointSize = appliedValue
    }

    // MARK: - Terminal

    private var terminalTab: some View {
        Form {
            Section(L10n.string("tmux status line")) {
                HStack(spacing: 18) {
                    Spacer(minLength: 0)
                    TmuxThemeThumbnail(
                        title: L10n.string("Detach colors"),
                        statusText: "● detach-claude · my-project",
                        detachStyled: true,
                        isSelected: tmuxStyle == .detach
                    ) {
                        Task { await saveTmuxStyle(.detach) }
                    }
                    TmuxThemeThumbnail(
                        title: L10n.string("My tmux theme"),
                        statusText: "[0] 0:codex*",
                        detachStyled: false,
                        isSelected: tmuxStyle == .inherit
                    ) {
                        Task { await saveTmuxStyle(.inherit) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .disabled(tmuxStyle == nil || isUpdatingTmuxStyle)

                if isUpdatingTmuxStyle && tmuxStyle == nil {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Reading the setting from detach…"))
                    }
                    .settingsMessage()
                } else {
                    Text(tmuxStyle == .inherit
                         ? L10n.string(
                            "Detach doesn't change the status bar of managed sessions — your tmux configuration is used.")
                         : L10n.string(
                            "Each session gets a stable color shared by tmux and the Detach interface."))
                        .settingsMessage()
                }

                if let tmuxStyleError {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(tmuxStyleError).settingsMessage(color: .red)
                        Spacer(minLength: 8)
                        Button(L10n.string("Try again")) {
                            Task { await loadTmuxStyle() }
                        }
                        .disabled(isUpdatingTmuxStyle)
                    }
                }
            }
            Section(L10n.string("Keyboard")) {
                Toggle(L10n.string("Insert newline with Shift+Return"), isOn: Binding(
                    get: { extendedKeys.isEnabled },
                    set: { newValue in
                        Task {
                            await extendedKeys.save(
                                newValue ? .on : .off, detachPath: activeDetachPath)
                        }
                    }))
                    .disabled(extendedKeys.setting == nil || extendedKeys.isUpdating)

                if extendedKeys.isUpdating && extendedKeys.setting == nil {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Reading the setting from detach…"))
                    }
                    .settingsMessage()
                } else {
                    Text(L10n.string(
                        "Makes managed tmux recognize Shift+Return and forward the same multiline input as Option+Return."))
                        .settingsMessage()
                }

                if let extendedKeysError = extendedKeys.errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(extendedKeysError).settingsMessage(color: .red)
                        Spacer(minLength: 8)
                        Button(L10n.string("Try again")) {
                            Task { await extendedKeys.load(detachPath: activeDetachPath) }
                        }
                        .disabled(extendedKeys.isUpdating)
                    }
                }
            }
            Section(L10n.string("Terminal")) {
                Picker(L10n.string("Open commands in"), selection: $terminalBundleIdentifier) {
                    ForEach(terminalApplications) { application in
                        Label {
                            Text(application.displayName)
                        } icon: {
                            if let icon = terminalIcons[application.bundleIdentifier] {
                                Image(nsImage: icon)
                            }
                        }
                        .tag(application.bundleIdentifier)
                    }
                    if let unlisted = unlistedSelectedTerminal {
                        Label {
                            Text(unlisted.displayName)
                        } icon: {
                            if let icon = terminalIcons[unlisted.bundleIdentifier] {
                                Image(nsImage: icon)
                            }
                        }
                        .tag(unlisted.bundleIdentifier)
                    } else if selectedTerminalIsMissing {
                        Text(L10n.string("Unavailable — choose another"))
                            .tag(terminalBundleIdentifier)
                    }
                }
                .pickerStyle(.menu)
                .disabled(terminalApplications.isEmpty && unlistedSelectedTerminal == nil)

                if let terminalChoiceError {
                    Text(terminalChoiceError).settingsMessage(color: .red)
                } else if terminalApplications.isEmpty && unlistedSelectedTerminal == nil {
                    Text(L10n.string(
                        "No installed terminal capable of opening .command files was found."))
                        .settingsMessage(color: .red)
                } else if selectedTerminalIsMissing {
                    Text(L10n.string(
                        "The previously selected app is no longer installed."))
                        .settingsMessage(color: .red)
                } else if let unlisted = unlistedSelectedTerminal {
                    Text(L10n.format(
                        "%@ was chosen manually. Detach will ask it to open command files.",
                        unlisted.displayName))
                        .settingsMessage()
                } else if let selectedTerminal {
                    Text(L10n.format(
                        "All interactive actions will open in %@.",
                        selectedTerminal.displayName))
                        .settingsMessage()
                }

                HStack(spacing: 12) {
                    Button {
                        terminalChoiceError = nil
                        isChoosingTerminalApplication = true
                    } label: {
                        Label(L10n.string("Choose Another App…"), systemImage: "plus.app")
                    }
                    Button {
                        refreshTerminalApplications()
                    } label: {
                        Label(L10n.string("Refresh terminal list"), systemImage: "arrow.clockwise")
                    }
                }
                .fileImporter(
                    isPresented: $isChoosingTerminalApplication,
                    allowedContentTypes: [.applicationBundle]
                ) { result in
                    guard case .success(let url) = result else { return }
                    chooseTerminalApplication(at: url)
                }
                .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
        }
        .formStyle(.grouped)
        .onChange(of: terminalBundleIdentifier) {
            terminalChoiceError = nil
            refreshTerminalApplications()
        }
    }

    // MARK: - Notifications

    private var notificationsTab: some View {
        Form {
            Section {
                NotificationBannerIllustration()
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle(L10n.string(
                    "Notify me when an agent response is ready or a session finishes"), isOn: Binding(
                    get: { notificationsEnabled },
                    set: { value in
                        notificationsEnabled = value
                        Task { await notifications.configure(enabled: value) }
                    }))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(notificationStatusColor)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 2 }
                    Text(notificationStatusText)
                        .settingsMessage(color:
                            notificationsEnabled && notifications.authorizationStatus == .denied
                                ? .red : nil)
                }

                if notificationsEnabled,
                   notifications.authorizationStatus == .notDetermined {
                    Button {
                        Task { await notifications.configure(enabled: true) }
                    } label: {
                        Label(L10n.string("Allow notifications"), systemImage: "bell.badge")
                    }
                } else if notificationsEnabled && notifications.authorizationStatus == .denied {
                    Button {
                        openNotificationSettings()
                    } label: {
                        Label(L10n.string("Open macOS Settings"), systemImage: "gearshape")
                    }
                }
                if let errorMessage = notifications.errorMessage {
                    Text(errorMessage).settingsMessage(color: .red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - System

    var systemTab: some View {
        Form {
            Section {
                NightSceneIllustration()
                    .listRowInsets(EdgeInsets())
                Text(L10n.string(
                    "Detach shows whether this Mac stays awake or can sleep while an agent is working."))
                    .settingsMessage()
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            Section(L10n.string("Mac Power")) {
                macPowerHeroRow
                requiredComponentStatus(
                    label: L10n.string("Sleep Protection Helper"),
                    status: powerHelperSettingsPresentation.status)
                requiredComponentStatus(
                    label: L10n.string("Background Power Monitor"),
                    status: installation.watchdogStatus == .enabled ? .ok : .error)
                if let detail = powerHelperSettingsPresentation
                    .detailLocalizationKey {
                    Text(L10n.string(detail))
                        .settingsMessage(color: .red)
                }
                macPowerAction
                if let error = installation.powerHelperError {
                    Text(error).settingsMessage(color: .red)
                }
                if let error = installation.watchdogError {
                    Text(error).settingsMessage(color: .red)
                }
                Picker(
                    L10n.string("Release sleep protection at"),
                    selection: lowBatteryThresholdBinding
                ) {
                    ForEach(PowerLowBatteryThreshold.allCases, id: \.self) { value in
                        Text("\(value.rawValue)%").tag(value)
                    }
                }
                .disabled(
                    !installation.powerHelperReadinessConfirmed
                        || installation.isBusy)
                .accessibilityIdentifier("settings-low-battery-threshold")
                Text(L10n.format(
                    "At %d%% battery or below, or during serious thermal pressure, Detach releases its sleep protection so the Mac can sleep.",
                    installation.lowBatteryThreshold.rawValue))
                    .settingsMessage()
            }
            Section(L10n.string("Bundled Runtime")) {
                requiredComponentStatus(
                    id: "tmux", label: L10n.string("tmux session runtime"))
                requiredComponentStatus(
                    id: "state_helper", label: L10n.string("Detach state runtime"))
                requiredComponentStatus(
                    id: "power_runtime", label: L10n.string("Detach power runtime"))
                Text(L10n.string(
                    "These components are included with Detach. Only Codex CLI or Claude CLI is installed and authenticated separately by you."))
                    .settingsMessage()
            }
            storageSection
            Section {
                Button(L10n.string("Reinstall command-line tools")) {
                    Task { await installation.repair() }
                }
                .disabled(installation.isBusy || !installation.isStableApplicationLocation)

                Button(L10n.string("Remove installed components…"), role: .destructive) {
                    confirmUninstall = true
                }
                .disabled(installation.isBusy)

                Button(L10n.string("Remove everything, including checkpoints…"), role: .destructive) {
                    confirmPurge = true
                }
                .disabled(installation.isBusy)
            } header: {
                settingsSectionHeader(
                    L10n.string("Installation"),
                    identifier: "settings-installation")
            }
            if let version = installation.report?.version {
                Section {
                    HStack(spacing: 6) {
                        TriColorDot()
                        Text(L10n.format("Detach CLI %@ · active", version))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var storageSection: some View {
        Section {
            if let report = storageStore.report {
                LabeledContent(L10n.string("Detach data"), value: storageSize(report.allocatedBytes))
                LabeledContent(
                    L10n.string("Checkpoints"),
                    value: storageSize(report.categories.checkpointBytes))
                LabeledContent(L10n.string("Logs"), value: storageSize(report.categories.logBytes))

                if !report.complete {
                    Text(L10n.string(
                        "Some entries could not be measured safely and are excluded from cleanup."))
                        .settingsMessage(color: .orange)
                }

                if report.sessions.isEmpty {
                    Text(L10n.string("No saved Detach sessions use disk space."))
                        .settingsMessage()
                } else {
                    Text(L10n.string("Largest sessions"))
                        .appFont(.caption, weight: .semibold)
                    ForEach(report.sessions.prefix(5)) { session in
                        HStack(spacing: 8) {
                            Toggle("", isOn: storageSelectionBinding(for: session))
                                .labelsHidden()
                                .disabled(!session.deletable)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.sessionName)
                                    .lineLimit(1)
                                Text(L10n.string(session.effectiveStatus.rawValue))
                                    .appFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(storageSize(session.allocatedBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if !session.deletable {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(L10n.string("Protected from cleanup"))
                            }
                        }
                    }
                }

                HStack {
                    Button(L10n.string("Refresh")) {
                        Task { await storageStore.refresh() }
                    }
                    Button(L10n.string("Show in Finder")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: report.stateRoot))
                    }
                    Spacer()
                    Button(L10n.string("Delete selected…"), role: .destructive) {
                        prepareStorageCleanup(report.sessions.filter {
                            $0.deletable && selectedStorageSessionIDs.contains($0.id)
                        })
                    }
                    .disabled(selectedStorageSessionIDs.isEmpty)
                    Button(L10n.string("Delete all safe…"), role: .destructive) {
                        prepareStorageCleanup(report.sessions.filter(\.deletable))
                    }
                    .disabled(!report.sessions.contains(where: \.deletable))
                }
            } else if storageStore.state == .loading {
                ProgressView(L10n.string("Measuring Detach storage…"))
            } else {
                Button(L10n.string("Measure Detach storage")) {
                    Task { await storageStore.refresh() }
                }
            }

            if let storageCleanupError {
                Text(storageCleanupError).settingsMessage(color: .red)
            } else if case .error(let message) = storageStore.state, !message.isEmpty {
                Text(message).settingsMessage(color: .red)
            } else if storageStore.state == .incompatible {
                Text(L10n.string("The installed Detach CLI returned incompatible storage data."))
                    .settingsMessage(color: .red)
            }
        } header: {
            settingsSectionHeader(
                L10n.string("Storage"),
                identifier: "settings-storage")
        }
    }

    private func settingsSectionHeader(
        _ title: String,
        identifier: String
    ) -> some View {
        Text(title)
            .accessibilityIdentifier(identifier)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                if AppSettings.uiE2E != nil {
                    UIE2EGeometryProbe(identifier: identifier)
                }
            }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    private func storageSelectionBinding(for session: StorageSession) -> Binding<Bool> {
        Binding(
            get: { selectedStorageSessionIDs.contains(session.id) },
            set: { selected in
                if selected {
                    selectedStorageSessionIDs.insert(session.id)
                } else {
                    selectedStorageSessionIDs.remove(session.id)
                }
            })
    }

    private func prepareStorageCleanup(_ sessions: [StorageSession]) {
        guard !sessions.isEmpty else { return }
        pendingStorageCleanup = sessions
        storageCleanupError = nil
        confirmStorageCleanup = true
    }

    private var storageCleanupDescription: String {
        let size = storageSize(storageTotal(pendingStorageCleanup))
        let names = pendingStorageCleanup.map(\.sessionName).joined(separator: ", ")
        return L10n.format(
            "%@ across %d stopped or orphaned sessions will be deleted: %@. Provider storage is not affected.",
            size, pendingStorageCleanup.count, names)
    }

    private func performStorageCleanup() async {
        let expected = pendingStorageCleanup
        let failures = await storageStore.cleanup(expected: expected)
        await sessionStore.refresh()
        let remainingIDs = Set(storageStore.report?.sessions.map(\.id) ?? [])
        selectedStorageSessionIDs.formIntersection(remainingIDs)
        pendingStorageCleanup = []
        storageCleanupError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func storageSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file)
    }

    private func storageTotal(_ sessions: [StorageSession]) -> UInt64 {
        sessions.reduce(0) { total, session in
            let (sum, overflow) = total.addingReportingOverflow(session.allocatedBytes)
            return overflow ? .max : sum
        }
    }

    var lowBatteryThresholdBinding: Binding<PowerLowBatteryThreshold> {
        Binding(
            get: { installation.lowBatteryThreshold },
            set: { newValue in
                Task { await installation.setLowBatteryThreshold(newValue) }
            })
    }

    var macPowerPresentation: MacPowerSettingsPresentation {
        let counts = MacPowerActiveSessions.counts(in: sessionStore.sessions)
        return MacPowerSettingsPresentation(
            state: installation.powerProtectionState,
            helperStatus: installation.powerHelperStatus,
            watchdogStatus: installation.watchdogStatus,
            distributionMatchesBundle: installation.distributionMatchesBundle,
            activeSessionCount: counts.active,
            workingSessionCount: counts.working)
    }

    private var macPowerHeroRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(macPowerStateColor.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: macPowerHeroSymbol)
                    .foregroundStyle(.white)
                    .appFont(.body, weight: .semibold)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(macPowerPresentation.stateLocalizationKey))
                    .appFont(.headline, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(macPowerDetailLine)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var macPowerHeroSymbol: String {
        switch macPowerPresentation.state {
        case .protected: "lock.shield.fill"
        case .allowed: "moon.zzz.fill"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .lowBattery: "battery.25"
        case .temperature: "thermometer.high"
        case .unavailable: "exclamationmark.shield.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var macPowerDetailLine: String {
        var parts = [macPowerReasonText]
        if let age = macPowerHeartbeatAgeText { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    private var macPowerReasonText: String {
        macPowerPresentation.reason.localizedText
    }

    private var macPowerHeartbeatAgeText: String? {
        let snapshot = installation.watchdogHeartbeat
        guard snapshot.healthy,
              let age = snapshot.age(relativeTo: Date()), age >= 0 else {
            return nil
        }
        return powerCheckedAgeText(seconds: Int(age))
    }

    private var macPowerStateColor: Color {
        switch macPowerPresentation.state {
        case .protected: Brand.teal
        case .allowed: .secondary
        case .transitioning, .lowBattery, .temperature: .orange
        case .unavailable: .red
        case .unknown: .secondary.opacity(0.6)
        }
    }

    @ViewBuilder
    private var macPowerAction: some View {
        switch macPowerPresentation.action {
        case .approveHelper:
            Button {
                installation.openPowerHelperApprovalSettings()
            } label: {
                Label(
                    L10n.string("Open System Settings"),
                    systemImage: "lock.shield")
            }
        case .approveBackground:
            Button {
                installation.openLoginItemsSettings()
            } label: {
                Label(
                    L10n.string("Open System Settings"),
                    systemImage: "gearshape.2")
            }
        case .setup:
            Button {
                Task { await installation.repair() }
            } label: {
                Label(
                    L10n.string("Set Up Power Protection"),
                    systemImage: "wrench.and.screwdriver")
            }
            .disabled(
                installation.isBusy
                    || !installation.isStableApplicationLocation)
        case .repair:
            Button {
                Task { await installation.repair() }
            } label: {
                Label(
                    L10n.string("Repair Power Protection"),
                    systemImage: "wrench.and.screwdriver")
            }
            .disabled(
                installation.isBusy
                    || !installation.isStableApplicationLocation)
        case .refresh:
            Button {
                Task { await installation.refreshContext() }
            } label: {
                Label(
                    L10n.string("Check Again"),
                    systemImage: "arrow.clockwise")
            }
            .disabled(installation.isBusy)
        case nil:
            EmptyView()
        }
    }

    private func requiredComponentStatus(id: String, label: String) -> some View {
        let status = installation.report?.checks.first { $0.id == id }?.status ?? .unknown
        return requiredComponentStatus(label: label, status: status)
    }

    private var powerHelperSettingsPresentation:
        PowerHelperSettingsPresentation
    {
        PowerHelperSettingsPresentation(
            registrationStatus: installation.powerHelperStatus,
            readinessConfirmed: installation.powerHelperReadinessConfirmed,
            isChecking: installation.phase == .idle || installation.isBusy)
    }

    private func requiredComponentStatus(
        label: String,
        status: DiagnosticCheck.Status
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            StatusIndicator(status: status)
        }
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 56, height: 56)
                    Text(applicationVersionTitle)
                        .appFont(.headline, weight: .semibold)
                    if updater.lastCheckFoundNoUpdate {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text(L10n.string("You're up to date"))
                        }
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(Brand.teal)
                    }
                    if let checked = updater.lastUpdateCheckDate {
                        Text(L10n.format(
                            "Last checked %@",
                            checked.formatted(date: .abbreviated, time: .shortened)))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                if updater.isAvailable {
                    Toggle(L10n.string("Automatically check for updates"), isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.string(
                        "Sparkle checks in the background on its own schedule."))
                        .settingsMessage()
                } else {
                    Text(L10n.string("Automatic updates are unavailable"))
                    if let reason = updater.unavailableReason {
                        Text(reason).settingsMessage()
                    }
                }
                if let errorMessage = updater.updateErrorMessage {
                    Text(errorMessage).settingsMessage(color: .red)
                }
                if updater.shouldOfferManualDownload,
                   let downloadURL = updater.manualDownloadURL {
                    Link(L10n.string("Open download page…"), destination: downloadURL)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var applicationVersionTitle: String {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "Detach"
        }
        return L10n.format("Detach %@", version)
    }

    private var notificationStatusColor: Color {
        guard notificationsEnabled else { return Color.secondary.opacity(0.5) }
        switch notifications.authorizationStatus {
        case .authorized: return Brand.teal
        case .denied: return .red
        case .unknown, .notDetermined: return .orange
        }
    }

    private var notificationStatusText: String {
        guard notificationsEnabled else {
            return L10n.string("Notifications are turned off in Detach.")
        }
        switch notifications.authorizationStatus {
        case .unknown:
            return L10n.string("Checking the system permission…")
        case .notDetermined:
            return L10n.string(
                "You can grant permission here — macOS will show a system prompt.")
        case .denied:
            return L10n.string(
                "macOS doesn't show the prompt again after a denial. Allow notifications for Detach in System Settings.")
        case .authorized:
            return L10n.string(
                "Ready — we'll notify you about ready responses, completed sessions, or session problems.")
        }
    }

    @MainActor
    private func loadTmuxStyle() async {
        let path = activeDetachPath
        isUpdatingTmuxStyle = true
        tmuxStyleError = nil
        defer {
            if path == activeDetachPath {
                isUpdatingTmuxStyle = false
            }
        }
        do {
            let style = try await TmuxStyleClient(
                cli: ProcessDetachCLI(executable: URL(fileURLWithPath: path)))
                .loadStyle()
            guard !Task.isCancelled, path == activeDetachPath else { return }
            tmuxStyle = style
        } catch {
            guard !Task.isCancelled, path == activeDetachPath else { return }
            tmuxStyle = nil
            tmuxStyleError = L10n.format(
                "Couldn't read the tmux setting: %@", error.localizedDescription)
        }
    }

    @MainActor
    private func saveTmuxStyle(_ style: TmuxStyle) async {
        guard !isUpdatingTmuxStyle, let previous = tmuxStyle, style != previous else { return }
        let path = activeDetachPath
        tmuxStyle = style
        isUpdatingTmuxStyle = true
        tmuxStyleError = nil
        defer {
            if path == activeDetachPath {
                isUpdatingTmuxStyle = false
            }
        }
        do {
            try await TmuxStyleClient(
                cli: ProcessDetachCLI(executable: URL(fileURLWithPath: path)))
                .setStyle(style)
        } catch {
            guard !Task.isCancelled, path == activeDetachPath else { return }
            tmuxStyle = previous
            tmuxStyleError = L10n.format(
                "Couldn't save the tmux setting: %@", error.localizedDescription)
        }
    }

    @MainActor
    private func refreshTerminalApplications() {
        terminalApplications = TerminalCatalog.installedApplications()
        if terminalApplications.contains(
            where: { $0.bundleIdentifier == terminalBundleIdentifier }) {
            unlistedSelectedTerminal = nil
        } else {
            unlistedSelectedTerminal = TerminalCatalog.application(
                bundleIdentifier: terminalBundleIdentifier)
        }
        var icons: [String: NSImage] = [:]
        var iconCandidates = terminalApplications
        if let unlistedSelectedTerminal {
            iconCandidates.append(unlistedSelectedTerminal)
        }
        for application in iconCandidates {
            guard let icon = NSWorkspace.shared
                .icon(forFile: application.applicationURL.path)
                .copy() as? NSImage else { continue }
            icon.size = NSSize(width: 16, height: 16)
            icons[application.bundleIdentifier] = icon
        }
        terminalIcons = icons
    }

    @MainActor
    private func chooseTerminalApplication(at url: URL) {
        guard let application = TerminalCatalog.application(at: url),
              !application.bundleIdentifier.isEmpty else {
            terminalChoiceError = L10n.format(
                "%@ can't be used as a terminal because it has no bundle identifier.",
                url.deletingPathExtension().lastPathComponent)
            return
        }
        terminalChoiceError = nil
        terminalBundleIdentifier = application.bundleIdentifier
        refreshTerminalApplications()
    }

    @MainActor
    private func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        guard let url = candidates.lazy.compactMap(URL.init(string:)).first else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Settings content may be taller than a laptop screen. The window stays
/// inside the hosting window's visible frame; the form scrolls.
private struct SettingsWindowFrame: NSViewRepresentable {
    var width: CGFloat
    var baseHeight: CGFloat
    var fontPointSize: Double

    func makeNSView(context: Context) -> SettingsWindowFrameView {
        let view = SettingsWindowFrameView()
        view.apply(width: width, baseHeight: baseHeight, fontPointSize: fontPointSize)
        return view
    }

    func updateNSView(_ view: SettingsWindowFrameView, context: Context) {
        view.apply(width: width, baseHeight: baseHeight, fontPointSize: fontPointSize)
    }
}

final class SettingsWindowFrameView: NSView {
    private var width: CGFloat = 0
    private var baseHeight: CGFloat = 0
    private var fontPointSize = AppFontSize.defaultValue

    func apply(width: CGFloat, baseHeight: CGFloat, fontPointSize: Double) {
        self.width = width
        self.baseHeight = baseHeight
        self.fontPointSize = fontPointSize
        pinToHostingScreen()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenDidChange),
                name: NSWindow.didChangeScreenNotification,
                object: window)
        }
        pinToHostingScreen()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenDidChange(_ notification: Notification) {
        pinToHostingScreen()
    }

    private func pinToHostingScreen() {
        guard let window, width > 0 else { return }
        let visibleHeight = window.screen?.visibleFrame.height ?? 720
        let size = CGSize(
            width: width,
            height: SettingsWindowLayout.contentHeight(
                base: baseHeight,
                fontPointSize: fontPointSize,
                visibleScreenHeight: visibleHeight))
        window.contentMinSize = size
        window.contentMaxSize = size
        let current = window.contentView?.bounds.size ?? .zero
        if abs(current.width - size.width) > 0.5
            || abs(current.height - size.height) > 0.5 {
            window.setContentSize(size)
        }
    }
}

extension View {
    func settingsMessage(color: Color? = nil) -> some View {
        self
            .appFont(.caption)
            .foregroundStyle(color ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
