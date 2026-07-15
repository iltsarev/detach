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

    let state: PowerProtectionState
    let action: Action?

    init(
        state: PowerProtectionState,
        helperStatus: PowerHelperRegistrationStatus,
        watchdogStatus: WatchdogStatus,
        distributionMatchesBundle: Bool
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
    }

    var stateLocalizationKey: String {
        switch state {
        case .protected: "Mac stays awake"
        case .allowed: "Mac can sleep"
        case .transitioning: "Enabling sleep protection"
        case .lowBattery: "Mac can sleep: low battery"
        case .unavailable: "Sleep protection unavailable"
        case .unknown: "Sleep status unknown"
        }
    }
}

private extension SettingsDestination {
    /// Content height measured at the default text size; the window follows
    /// the selected tab like classic AppKit preference panes.
    var baseHeight: CGFloat {
        switch self {
        case .general: 450
        case .terminal: 460
        case .notifications: 350
        case .system: 660
        case .updates: 420
        }
    }
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let installation: InstallationStore
    @ObservedObject var updater: UpdaterService
    @ObservedObject var notifications: SessionNotificationService
    @ObservedObject var navigation: SettingsNavigation

    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @AppStorage(AppFontSize.storageKey) private var fontPointSize = AppFontSize.defaultValue
    @AppStorage(AppSettings.terminalBundleIdentifierKey) private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = false
    @AppStorage(AppSettings.tipsEnabledKey) private var tipsEnabled = true

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
    @State private var fontSizeDraft: AppFontSizeDraft?

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
            }
            .tag(SettingsDestination.system)
            updatesTab.tabItem {
                tabLabel(L10n.string("Updates"), systemImage: "arrow.triangle.2.circlepath",
                         color: NSColor(Brand.indigo))
            }
            .tag(SettingsDestination.updates)
        }
        .appFontSize(fontPointSize)
        .frame(
            width: AppFontSize.settingsWidth(for: fontPointSize),
            height: AppFontSize.settingsHeight(
                base: navigation.selectedTab.baseHeight, for: fontPointSize))
        .task {
            let clampedFontPointSize = AppFontSize.clamped(fontPointSize)
            if fontSizeDraft == nil {
                fontSizeDraft = AppFontSizeDraft(appliedValue: clampedFontPointSize)
            }
            if fontPointSize != clampedFontPointSize {
                fontPointSize = clampedFontPointSize
            }
            refreshTerminalApplications()
            notifications.configureMonitoring(
                detachPath: activeDetachPath,
                interval: pollInterval)
            await notifications.configure(enabled: notificationsEnabled)
            await installation.refreshContext()
        }
        .task(id: activeDetachPath) {
            await loadTmuxStyle()
        }
        .task(id: navigation.selectedTab) {
            guard navigation.selectedTab == .system else { return }
            while !Task.isCancelled {
                installation.refreshPowerProtectionState()
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
            }
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
            notifications.configureMonitoring(detachPath: activeDetachPath, interval: value)
        }
        .onChange(of: detachPath) { _, _ in
            notifications.configureMonitoring(
                detachPath: activeDetachPath,
                interval: pollInterval)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await notifications.refreshAuthorizationStatus()
                await installation.refreshContext()
                if !isUpdatingTmuxStyle {
                    await loadTmuxStyle()
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
                        "%@ was chosen manually. Detach will verify it can run commands the first time one opens.",
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

    private var systemTab: some View {
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
                macPowerStateRow
                requiredComponentStatus(
                    label: L10n.string("Sleep Protection Helper"),
                    status: installation.powerHelperStatus == .enabled ? .ok : .error)
                requiredComponentStatus(
                    label: L10n.string("Background Power Monitor"),
                    status: installation.watchdogStatus == .enabled ? .ok : .error)
                Text(powerHelperStatusText)
                    .settingsMessage(color:
                        installation.powerHelperStatus == .enabled ? nil : .red)
                macPowerAction
                if let error = installation.powerHelperError {
                    Text(error).settingsMessage(color: .red)
                }
                if let error = installation.watchdogError {
                    Text(error).settingsMessage(color: .red)
                }
                Text(L10n.string(
                    "Detach automatically protects active sessions and restores normal sleep after the last one. No third-party keep-awake app is required."))
                    .settingsMessage()
                Text(L10n.string(
                    "At 10% battery or below, Detach releases its sleep protection so the Mac can sleep."))
                    .settingsMessage()
                Text(L10n.string(
                    "The current sleep state comes from the latest background power check."))
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
            Section(L10n.string("Installation")) {
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

    private var macPowerPresentation: MacPowerSettingsPresentation {
        MacPowerSettingsPresentation(
            state: installation.powerProtectionState,
            helperStatus: installation.powerHelperStatus,
            watchdogStatus: installation.watchdogStatus,
            distributionMatchesBundle: installation.distributionMatchesBundle)
    }

    private var macPowerStateRow: some View {
        HStack(spacing: 12) {
            Text(L10n.string("Current Sleep State"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle()
                    .fill(macPowerStateColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(L10n.string(macPowerPresentation.stateLocalizationKey))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var macPowerStateColor: Color {
        switch macPowerPresentation.state {
        case .protected: Brand.teal
        case .allowed: .secondary
        case .transitioning, .lowBattery: .orange
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

    private var powerHelperStatusText: String {
        switch installation.powerHelperStatus {
        case .enabled:
            L10n.string("The native power helper is enabled.")
        case .requiresApproval:
            L10n.string(
                "One-time administrator approval is required for native sleep protection.")
        case .notRegistered:
            L10n.string("The native power helper is not registered yet.")
        case .unavailable:
            L10n.string("The native power helper is unavailable.")
        }
    }

    private func requiredComponentStatus(
        label: String,
        status: DiagnosticCheck.Status
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            StatusIndicator(healthy: status == .ok)
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

extension View {
    func settingsMessage(color: Color? = nil) -> some View {
        self
            .appFont(.caption)
            .foregroundStyle(color ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
