import AppKit
import DetachKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let installation: InstallationStore
    @ObservedObject var updater: UpdaterService
    @ObservedObject var notifications: SessionNotificationService

    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @AppStorage(AppFontSize.storageKey) private var fontPointSize = AppFontSize.defaultValue
    @AppStorage(AppSettings.terminalBundleIdentifierKey) private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = false

    @State private var terminalApplications: [TerminalApplication] = []
    @State private var terminalIcons: [String: NSImage] = [:]
    @State private var confirmUninstall = false
    @State private var confirmPurge = false
    @State private var tmuxStyle: TmuxStyle?
    @State private var isUpdatingTmuxStyle = false
    @State private var tmuxStyleError: String?

    private var selectedTerminal: TerminalApplication? {
        terminalApplications.first { $0.bundleIdentifier == terminalBundleIdentifier }
    }

    private var selectedTerminalIsMissing: Bool {
        selectedTerminal == nil
    }

    private var activeDetachPath: String {
        installation.hasDistributionPayload ? AppSettings.defaultDetachPath : detachPath
    }

    private var normalizedFontPointSize: Binding<Double> {
        Binding(
            get: { AppFontSize.clamped(fontPointSize) },
            set: { fontPointSize = AppFontSize.clamped($0) })
    }

    var body: some View {
        TabView {
            generalTab.tabItem {
                tabLabel(L10n.string("General"), systemImage: "gearshape.fill", color: .systemGray)
            }
            terminalTab.tabItem {
                tabLabel(L10n.string("Terminal"), systemImage: "terminal.fill",
                         color: NSColor(Brand.teal))
            }
            notificationsTab.tabItem {
                tabLabel(L10n.string("Notifications"), systemImage: "bell.badge.fill",
                         color: .systemRed)
            }
            systemTab.tabItem {
                tabLabel(L10n.string("System"), systemImage: "moon.stars.fill",
                         color: .systemOrange)
            }
            updatesTab.tabItem {
                tabLabel(L10n.string("Updates"), systemImage: "arrow.triangle.2.circlepath",
                         color: NSColor(Brand.indigo))
            }
        }
        .appFontSize(fontPointSize)
        .frame(
            width: AppFontSize.settingsWidth(for: fontPointSize),
            height: AppFontSize.settingsMinimumHeight)
        .task {
            let clampedFontPointSize = AppFontSize.clamped(fontPointSize)
            if fontPointSize != clampedFontPointSize {
                fontPointSize = clampedFontPointSize
            }
            refreshTerminalApplications()
            notifications.configureMonitoring(
                detachPath: activeDetachPath,
                interval: pollInterval)
            await notifications.configure(enabled: notificationsEnabled)
        }
        .task(id: activeDetachPath) {
            await loadTmuxStyle()
        }
        .onChange(of: fontPointSize) { _, value in
            let clamped = AppFontSize.clamped(value)
            if value != clamped { fontPointSize = clamped }
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
            Task { await notifications.refreshAuthorizationStatus() }
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
                SessionRowPreviewCard()
                HStack(spacing: 8) {
                    Text(L10n.string("Text size"))
                    Spacer(minLength: 12)
                    Text(verbatim: "A")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: normalizedFontPointSize,
                        in: AppFontSize.allowedRange,
                        step: 1
                    ) {
                        Text(L10n.string("Text size"))
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text(verbatim: "A")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text(L10n.format("%d pt", Int(AppFontSize.clamped(fontPointSize))))
                        .appFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
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
                        .frame(width: 44, alignment: .trailing)
                }
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
                    if selectedTerminalIsMissing {
                        Text(L10n.string("Unavailable — choose another"))
                            .tag(terminalBundleIdentifier)
                    }
                }
                .pickerStyle(.menu)
                .disabled(terminalApplications.isEmpty)

                if terminalApplications.isEmpty {
                    Text(L10n.string(
                        "No installed terminal capable of opening .command files was found."))
                        .settingsMessage(color: .red)
                } else if selectedTerminalIsMissing {
                    Text(L10n.string(
                        "The previously selected app was removed or no longer supports opening commands."))
                        .settingsMessage(color: .red)
                } else if let selectedTerminal {
                    Text(L10n.format(
                        "All interactive actions will open in %@.",
                        selectedTerminal.displayName))
                        .settingsMessage()
                }

                Button {
                    refreshTerminalApplications()
                } label: {
                    Label(L10n.string("Refresh terminal list"), systemImage: "arrow.clockwise")
                }
            }
        }
        .formStyle(.grouped)
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
                    "The Mac won't sleep with the lid closed while an agent is working."))
                    .settingsMessage()
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            Section(L10n.string("Keep-awake")) {
                requiredComponentStatus(
                    id: "amphetamine_app", label: L10n.string("Amphetamine.app"))
                requiredComponentStatus(
                    id: "amphetamine_power_protect",
                    label: L10n.string("Amphetamine Power Protect"))
                requiredComponentStatus(
                    label: L10n.string("Detach background service"),
                    status: installation.watchdogStatus == .enabled ? .ok : .error)
                Text(L10n.string(
                    "Amphetamine.app, Power Protect, and the background service are required. Detach automatically starts keep-awake for active sessions and stops it after the last one."))
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

    private func requiredComponentStatus(id: String, label: String) -> some View {
        let status = installation.report?.checks.first { $0.id == id }?.status ?? .unknown
        return requiredComponentStatus(label: label, status: status)
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
        var icons: [String: NSImage] = [:]
        for application in terminalApplications {
            guard let icon = NSWorkspace.shared
                .icon(forFile: application.applicationURL.path)
                .copy() as? NSImage else { continue }
            icon.size = NSSize(width: 16, height: 16)
            icons[application.bundleIdentifier] = icon
        }
        terminalIcons = icons
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
