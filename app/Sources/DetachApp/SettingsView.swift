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
    @State private var confirmUninstall = false
    @State private var confirmPurge = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                generalSection
                terminalSection
                notificationsSection
                installationSection
                keepAwakeSection
                updatesSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .appFontSize(fontPointSize)
        .frame(
            minWidth: AppFontSize.settingsWidth(for: fontPointSize),
            idealWidth: AppFontSize.settingsWidth(for: fontPointSize),
            minHeight: AppFontSize.settingsMinimumHeight,
            idealHeight: AppFontSize.settingsIdealHeight)
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
            Task { await notifications.refreshAuthorizationStatus() }
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

    private var generalSection: some View {
        SettingsSectionView(L10n.string("General"), systemImage: "slider.horizontal.3") {
            if installation.hasDistributionPayload {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L10n.string("CLI"))
                    Spacer(minLength: 12)
                    Text(AppSettings.defaultDetachPath)
                        .appFont(.body, design: .monospaced)
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

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.format("Refresh interval: %d sec", Int(pollInterval)))
                Slider(value: $pollInterval, in: 1...10, step: 1) {
                    Text(L10n.string("Refresh interval"))
                }
                .labelsHidden()
            }

            HStack {
                Text(L10n.string("Font size"))
                Spacer()
                TextField(
                    L10n.string("Font size"),
                    value: normalizedFontPointSize,
                    format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 42)
                Text(L10n.string("pt")).foregroundStyle(.secondary)
                Stepper(
                    L10n.string("Font size"),
                    value: normalizedFontPointSize,
                    in: AppFontSize.allowedRange,
                    step: 1)
                    .labelsHidden()
            }
        }
    }

    private var terminalSection: some View {
        SettingsSectionView(L10n.string("Terminal"), systemImage: "terminal") {
            Picker(L10n.string("Open commands in"), selection: $terminalBundleIdentifier) {
                ForEach(terminalApplications) { application in
                    Text(application.displayName).tag(application.bundleIdentifier)
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

    private var notificationsSection: some View {
        SettingsSectionView(L10n.string("Notifications"), systemImage: "bell.badge") {
            Toggle(L10n.string(
                "Notify me when an agent response is ready or a session finishes"), isOn: Binding(
                get: { notificationsEnabled },
                set: { value in
                    notificationsEnabled = value
                    Task { await notifications.configure(enabled: value) }
                }))
                .fixedSize(horizontal: false, vertical: true)

            Text(notificationStatusText)
                .settingsMessage(color:
                    notificationsEnabled && notifications.authorizationStatus == .denied
                        ? .red : nil)

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

    private var installationSection: some View {
        SettingsSectionView(L10n.string("Installation"), systemImage: "shippingbox") {
            fullWidthButton(
                L10n.string("Reinstall command-line tools"),
                systemImage: "arrow.clockwise"
            ) {
                Task { await installation.repair() }
            }
            .disabled(installation.isBusy || !installation.isStableApplicationLocation)

            fullWidthButton(
                L10n.string("Remove installed components…"),
                systemImage: "trash",
                role: .destructive
            ) {
                confirmUninstall = true
            }
            .disabled(installation.isBusy)

            fullWidthButton(
                L10n.string("Remove everything, including checkpoints…"),
                systemImage: "trash.slash",
                role: .destructive
            ) {
                confirmPurge = true
            }
            .disabled(installation.isBusy)
        }
    }

    private var keepAwakeSection: some View {
        SettingsSectionView(L10n.string("Keep-awake"), systemImage: "moon.stars") {
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
    }

    private func requiredComponentStatus(id: String, label: String) -> some View {
        let status = installation.report?.checks.first { $0.id == id }?.status ?? .unknown
        return requiredComponentStatus(label: label, status: status)
    }

    private func requiredComponentStatus(
        label: String,
        status: DiagnosticCheck.Status
    ) -> some View {
        let healthy = status == .ok
        let description = healthy
            ? L10n.format("%@: ready", label)
            : L10n.format("%@: needs attention", label)
        return Label(
            description,
            systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(healthy ? Brand.teal : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var updatesSection: some View {
        SettingsSectionView(L10n.string("Updates"), systemImage: "arrow.triangle.2.circlepath") {
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

    @ViewBuilder
    private func fullWidthButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label {
                Text(title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
    }

    @MainActor
    private func refreshTerminalApplications() {
        terminalApplications = TerminalCatalog.installedApplications()
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

private struct SettingsSectionView<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(Brand.indigo)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Brand.indigo.opacity(0.12)))
                Text(title).appFont(.headline, weight: .semibold)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func settingsMessage(color: Color? = nil) -> some View {
        self
            .appFont(.caption)
            .foregroundStyle(color ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
