import AppKit
import SwiftUI
import DetachKit

/// Guided install target. Detach never bundles a provider: the command is the
/// official installer, launched visibly in the user's own terminal.
private enum GuidedProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex CLI"
        case .claude: "Claude Code"
        }
    }

    /// Official installer commands, verbatim from provider documentation.
    /// Re-verify against the documentation before every release.
    var installCommand: String {
        switch self {
        case .codex: "npm install -g @openai/codex"
        case .claude: "npm install -g @anthropic-ai/claude-code"
        }
    }

    var documentationURL: URL {
        switch self {
        case .codex:
            URL(string: "https://github.com/openai/codex#quickstart")!
        case .claude:
            URL(string:
                "https://docs.anthropic.com/en/docs/claude-code/getting-started")!
        }
    }
}

struct OnboardingView: View {
    let store: InstallationStore
    @State private var poller: OnboardingLivePoller
    @AppStorage(AppSettings.terminalBundleIdentifierKey)
    private var terminalBundleIdentifier = TerminalCatalog.defaultBundleIdentifier
    @State private var selectedProvider: GuidedProvider = .claude
    @State private var guidedInstallMessage: String?
    @State private var guidedInstallStartedAt: Date?
    @State private var showsPermissionsExplainer = false
    @Environment(\.appFontPointSize) private var fontPointSize

    init(store: InstallationStore) {
        self.store = store
        _poller = State(initialValue: OnboardingLivePoller(store: store))
    }

    private var step: OnboardingStep { store.onboardingStep }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if step != .moveToApplications {
                    progressDots
                        .padding(.bottom, 34)
                }
                heroIcon
                    .padding(.bottom, 22)
                Text(title)
                    .appFont(.largeTitle, weight: .bold)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: onboardingFontSize * 26)
                    .padding(.top, 12)
                stepContent
                    .padding(.top, 28)
                actions
                    .padding(.top, 30)
                technicalDetails
                    .padding(.top, 38)
            }
            .appFontSize(onboardingFontSize)
            .frame(maxWidth: max(620, onboardingFontSize * 40))
            .padding(44)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: step) { poller.update(for: step) }
        .onDisappear { poller.stop() }
    }

    /// The one-time onboarding is deliberately larger than the in-app body so
    /// the hero art and headline read as a proper welcome. It scales with — but
    /// stays a step above — the user's chosen in-app text size.
    private var onboardingFontSize: CGFloat {
        CGFloat(AppFontSize.clamped(Double(fontPointSize) + 5))
    }

    /// Enlargement factor for the fixed-width secondary rows, relative to the
    /// default in-app text size.
    private var scale: CGFloat {
        onboardingFontSize / CGFloat(AppFontSize.defaultValue)
    }

    // MARK: - Progress

    private var stepIndex: Int {
        switch step {
        case .moveToApplications, .autoSetup: 0
        case .permissions: 1
        case .provider: 2
        case .done, .mainApp: 3
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(dotColor(index))
                    .frame(width: 7, height: 7)
                    .overlay {
                        if index == stepIndex && step != .done {
                            Circle()
                                .stroke(Brand.indigo.opacity(0.3), lineWidth: 3)
                                .frame(width: 13, height: 13)
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func dotColor(_ index: Int) -> Color {
        if step == .done { return Brand.teal }
        if index < stepIndex { return Brand.teal }
        if index == stepIndex { return Brand.indigo }
        return Color.secondary.opacity(0.25)
    }

    // MARK: - Hero

    private var heroSize: CGFloat { onboardingFontSize * 5.9 }
    private var heroCornerRadius: CGFloat { heroSize * 0.23 }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: heroCornerRadius, style: .continuous)
                .fill(heroGradient)
                .frame(width: heroSize, height: heroSize)
                .shadow(color: heroShadow, radius: 16, y: 8)
            Image(systemName: heroSymbol)
                .appFont(.heroIcon, weight: .semibold)
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var heroGradient: LinearGradient {
        let colors: [Color]
        switch step {
        case .moveToApplications: colors = [Color(.systemGray), Color(.darkGray)]
        case .autoSetup(let failure):
            colors = failure == nil
                ? [Brand.indigo, Brand.indigo.opacity(0.75)]
                : [Color.red, Color.red.opacity(0.75)]
        case .permissions: colors = [Brand.indigo, Color.purple.opacity(0.85)]
        case .provider: colors = [Brand.teal, Brand.teal.opacity(0.7)]
        case .done, .mainApp: colors = [Brand.teal, Color.green.opacity(0.7)]
        }
        return LinearGradient(
            colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var heroShadow: Color {
        switch step {
        case .done, .mainApp, .provider: Brand.teal.opacity(0.35)
        default: Brand.indigo.opacity(0.3)
        }
    }

    private var heroSymbol: String {
        switch step {
        case .moveToApplications: "folder.badge.plus"
        case .autoSetup(let failure):
            failure == nil ? "shippingbox.and.arrow.backward" : "wrench.and.screwdriver"
        case .permissions: "moon.stars.fill"
        case .provider: "terminal.fill"
        case .done, .mainApp: "checkmark"
        }
    }

    // MARK: - Copy

    private var title: String {
        switch step {
        case .moveToApplications:
            L10n.string("Move Detach to Applications")
        case .autoSetup(let failure):
            failure == nil
                ? L10n.string("Setting Up Detach…")
                : L10n.string("Could Not Complete Setup")
        case .permissions:
            L10n.string("Allow Detach to Work in the Background")
        case .provider:
            L10n.string("Connect Codex or Claude")
        case .done, .mainApp:
            L10n.string("Detach Is Ready")
        }
    }

    private var subtitle: String {
        switch step {
        case .moveToApplications:
            L10n.string(
                "Drag Detach.app to the Applications folder, then open the installed copy.")
        case .autoSetup(let failure):
            failure == nil
                ? L10n.string("This usually takes a few seconds. Nothing to do here.")
                : L10n.string("The installed CLI version will remain functional — retrying is safe.")
        case .permissions:
            L10n.string(
                "macOS asks once. Enable Detach in the list that opens — it may show one or two switches. This screen updates automatically.")
        case .provider:
            L10n.string(
                "Detach manages Codex CLI and Claude Code sessions. Install at least one — it stays yours; Detach never bundles or replaces it.")
        case .done, .mainApp:
            L10n.string(
                "Start long sessions, close the terminal and the lid — the agent keeps working with a checkpoint every 5 minutes.")
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .moveToApplications:
            if poller.installedCopyPresent {
                statusRow(
                    icon: "checkmark.circle.fill", tint: Brand.teal,
                    text: L10n.string(
                        "Detach is now in Applications — close this window and open the installed copy."))
            }

        case .autoSetup(let failure):
            VStack(spacing: 10) {
                if let failure {
                    statusRow(
                        icon: "xmark.circle.fill", tint: .red, text: failure)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                        .padding(.bottom, 6)
                    liveRow(
                        label: L10n.string("Command-line runtime"),
                        done: store.distributionMatchesBundle)
                    liveRow(
                        label: L10n.string("Background helpers registration"),
                        done: store.powerHelperStatus == .enabled
                            && store.watchdogStatus == .enabled)
                }
            }

        case .permissions:
            VStack(spacing: 8) {
                permissionRow(
                    symbol: "moon.fill",
                    name: L10n.string("Sleep protection — Detach Power Helper"),
                    status: store.powerHelperStatus == .enabled
                        ? .enabled
                        : (store.powerHelperStatus == .requiresApproval
                            ? .waitingAdmin : .registering))
                permissionRow(
                    symbol: "gearshape.2.fill",
                    name: L10n.string("Background power monitor — Detach"),
                    status: store.watchdogStatus == .enabled
                        ? .enabled
                        : (store.watchdogStatus == .requiresApproval
                            ? .waiting : .registering))
                if store.powerHelperStatus == .enabled,
                   store.watchdogStatus == .enabled,
                   !store.powerHelperReadinessConfirmed {
                    statusRow(
                        icon: "arrow.triangle.2.circlepath", tint: .orange,
                        text: L10n.string("Confirming protection readiness…"))
                }
                if let error = store.powerHelperError {
                    statusRow(icon: "xmark.circle.fill", tint: .red, text: error)
                }
                if let error = store.watchdogError {
                    statusRow(icon: "xmark.circle.fill", tint: .red, text: error)
                }
                if showsPermissionsExplainer {
                    Text(L10n.string(
                        "A narrowly scoped helper keeps the Mac awake with the lid closed while an agent works. At 10% battery, protection is released so the Mac can sleep. No Apple Events or third-party tools are used."))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400 * scale)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 420 * scale)

        case .provider:
            VStack(spacing: 12) {
                Picker("", selection: $selectedProvider) {
                    ForEach(GuidedProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320 * scale)

                if poller.providerAvailability.any {
                    statusRow(
                        icon: "checkmark.circle.fill", tint: Brand.teal,
                        text: L10n.string("Detected — verifying…"))
                } else if let startedAt = guidedInstallStartedAt,
                          Date().timeIntervalSince(startedAt) > 120 {
                    statusRow(
                        icon: "clock", tint: .orange,
                        text: L10n.string(
                            "Not detected yet. Check the Terminal output — network, npm permissions — then try again."))
                } else {
                    statusRow(
                        icon: "magnifyingglass", tint: .secondary,
                        text: L10n.string(
                            "Looking for codex and claude in PATH — this screen updates automatically"))
                }
                if let message = guidedInstallMessage {
                    statusRow(icon: "xmark.circle.fill", tint: .red, text: message)
                }
            }

        case .done, .mainApp:
            VStack(spacing: 8) {
                if poller.heartbeatHealthy {
                    statusRow(
                        icon: "checkmark.circle.fill", tint: Brand.teal,
                        text: L10n.string("Background monitor is reporting"))
                } else if poller.heartbeatWaitIsLong {
                    statusRow(
                        icon: "clock", tint: .orange,
                        text: L10n.string(
                            "The monitor has not reported yet. Retry it before opening the dashboard."))
                } else {
                    statusRow(
                        icon: "arrow.triangle.2.circlepath", tint: .secondary,
                        text: L10n.string("Checking the background monitor…"))
                }
                statusRow(
                    icon: "person.badge.key", tint: .secondary,
                    text: L10n.string(
                        "Remember to authenticate: run codex login or claude → /login before the first session."))
            }
            .frame(maxWidth: 440 * scale)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        switch step {
        case .moveToApplications:
            Button(L10n.string("Open the Applications Folder")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.indigo)

        case .autoSetup(let failure):
            if failure != nil {
                Button(L10n.string("Retry Setup")) {
                    Task { await store.repair() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
            }

        case .permissions:
            VStack(spacing: 10) {
                if needsPermissionRepair {
                    Button(L10n.string("Retry Setup")) {
                        Task { await store.repair() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                    .disabled(store.isBusy)
                    Button(L10n.string("Open System Settings")) {
                        store.openPowerHelperApprovalSettings()
                    }
                    .buttonStyle(.link)
                } else {
                    Button(L10n.string("Open System Settings")) {
                        store.openPowerHelperApprovalSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                }
                Button(L10n.string("What exactly is enabled and why?")) {
                    showsPermissionsExplainer.toggle()
                }
                .buttonStyle(.link)
                .appFont(.caption)
            }

        case .provider:
            VStack(spacing: 10) {
                Button(L10n.string("Install via Terminal")) {
                    launchGuidedInstall()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
                HStack(spacing: 14) {
                    Button(L10n.string("Official instructions")) {
                        NSWorkspace.shared.open(
                            selectedProvider.documentationURL)
                    }
                    .buttonStyle(.link)
                    Button(L10n.string("I already installed it")) {
                        Task { await store.refreshContext() }
                    }
                    .buttonStyle(.link)
                }
                .appFont(.caption)
            }

        case .done:
            if poller.heartbeatWaitIsLong && !poller.heartbeatHealthy {
                Button(L10n.string("Retry Background Monitor")) {
                    Task { await store.repair() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
            } else {
                Button(L10n.string("Open Dashboard")) {
                    store.markOnboardingCompleted()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.teal)
                .disabled(!poller.heartbeatHealthy)
            }

        case .mainApp:
            Button(L10n.string("Open Dashboard")) {
                store.markOnboardingCompleted()
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.teal)
        }
    }

    private func launchGuidedInstall() {
        guidedInstallMessage = nil
        guidedInstallStartedAt = Date()
        let command = selectedProvider.installCommand
        let terminal = terminalBundleIdentifier
        Task {
            if let failure = await TerminalLauncher.open(
                command: command,
                terminalBundleIdentifier: terminal) {
                guidedInstallMessage = failure.message
            }
        }
    }

    // MARK: - Rows

    private enum PermissionStatus {
        case enabled
        case waiting
        case waitingAdmin
        case registering
    }

    private func permissionRow(
        symbol: String,
        name: String,
        status: PermissionStatus
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Brand.indigo)
                .frame(width: 20)
            Text(name)
                .appFont(.body, weight: .medium)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle()
                    .fill(status == .enabled ? Brand.teal : Color.orange)
                    .frame(width: 7, height: 7)
                Text(permissionStatusText(status))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(.quaternary.opacity(0.45)))
        .accessibilityElement(children: .combine)
    }

    private func permissionStatusText(_ status: PermissionStatus) -> String {
        switch status {
        case .enabled: L10n.string("enabled")
        case .waiting: L10n.string("waiting for approval")
        case .waitingAdmin: L10n.string("waiting for approval · admin password")
        case .registering: L10n.string("registering…")
        }
    }

    private func liveRow(label: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? Brand.teal : Color.secondary)
                .frame(width: 18)
            Text(label)
            Spacer(minLength: 0)
        }
        .appFont(.body)
        .frame(maxWidth: 360 * scale)
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440 * scale)
    }

    // MARK: - Technical details (diagnostics)

    private var technicalDetails: some View {
        DisclosureGroup(L10n.string("Technical Details")) {
            VStack(alignment: .leading, spacing: 12) {
                checks(allChecks)
                if let error = technicalError {
                    Text(error)
                        .appFont(.caption, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 10)
        }
        .foregroundStyle(.secondary)
    }

    private var allChecks: [DiagnosticCheck] {
        let cliChecks = store.report?.checks.filter {
            $0.section == .base && $0.id != "watchdog"
                && $0.id != "power_helper"
        } ?? []
        return cliChecks + store.appContextChecks
    }

    private var needsPermissionRepair: Bool {
        if store.powerHelperError != nil || store.watchdogError != nil {
            return true
        }
        return !store.isBusy
            && store.powerHelperStatus == .enabled
            && store.watchdogStatus == .enabled
            && !store.powerHelperReadinessConfirmed
    }

    private func checks(_ values: [DiagnosticCheck]) -> some View {
        VStack(spacing: 8) {
            ForEach(values) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: check.status))
                        .foregroundStyle(color(for: check.status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedDiagnosticLabel(for: check))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        Text(localizedDiagnosticSummary(for: check)).appFont(.caption)
                        if let path = check.path, path.hasPrefix("/") {
                            Text(path).appFont(.caption2, design: .monospaced)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        if check.status == .error, let hint = remediation(for: check.id) {
                            Text(hint).appFont(.caption).foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
            }
        }
    }

    private var technicalError: String? {
        if let powerHelperError = store.powerHelperError { return powerHelperError }
        if let watchdogError = store.watchdogError { return watchdogError }
        if case .failed(let message) = store.phase { return message }
        return nil
    }

    private func icon(for status: DiagnosticCheck.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(for status: DiagnosticCheck.Status) -> Color {
        switch status {
        case .ok: Brand.teal
        case .warning: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }

    private func localizedDiagnosticLabel(for check: DiagnosticCheck) -> String {
        switch check.id {
        case "integrity":
            L10n.string("CLI Integrity")
        case "cli":
            L10n.string("detach CLI")
        case "cli_path":
            L10n.string("CLI in PATH")
        case "manifest":
            L10n.string("Install Manifest")
        case "tmux":
            L10n.string("Bundled tmux")
        case "state_helper":
            L10n.string("Detach state runtime")
        case "power_runtime":
            L10n.string("Detach power runtime")
        case "power_helper":
            L10n.string("Native Sleep Protection")
        case "provider":
            L10n.string("Provider CLI")
        case "sqlite":
            L10n.string("sqlite3")
        case "tar":
            L10n.string("tar")
        case "lockf":
            L10n.string("lockf")
        case "watchdog":
            L10n.string("Detach Background Power Monitor")
        default:
            check.label
        }
    }

    private func localizedDiagnosticSummary(for check: DiagnosticCheck) -> String {
        switch (check.id, check.status) {
        case ("integrity", .ok):
            return L10n.string("Payload hashes match")
        case ("integrity", .error):
            return L10n.string("The payload is damaged or its metadata does not match")
        case ("cli", .ok):
            guard let version = store.report?.version else { return check.summary }
            return L10n.format("Version %@ is installed", version)
        case ("cli", .error):
            return L10n.string("The public CLI does not point to the current immutable version")
        case ("cli_path", .ok):
            return L10n.string("Terminal can find the installed detach")
        case ("cli_path", .error):
            guard let path = check.path, !path.isEmpty else { return check.summary }
            return L10n.format("Add %@ to PATH", path)
        case ("manifest", .ok):
            return L10n.string("The manifest matches the CLI")
        case ("manifest", .error):
            return L10n.string("The manifest is missing, damaged, or contains a different version")
        case ("tmux", .ok), ("state_helper", .ok), ("power_runtime", .ok),
             ("sqlite", .ok), ("tar", .ok), ("lockf", .ok):
            guard let path = check.path, !path.isEmpty else { return check.summary }
            return L10n.format("Found: %@", path)
        case ("tmux", .error), ("state_helper", .error), ("power_runtime", .error):
            return L10n.string(
                "A bundled runtime component is missing or damaged; run Repair.")
        case ("power_helper", .ok):
            return L10n.string("The native power helper is reachable")
        case ("power_helper", .error):
            return L10n.string(
                "The native power helper is unavailable or needs approval")
        case ("sqlite", .error), ("tar", .error), ("lockf", .error):
            return L10n.format(
                "%@ was not found in PATH",
                localizedDiagnosticLabel(for: check))
        case ("provider", .ok):
            let hasCodex = check.summary.localizedCaseInsensitiveContains("Codex")
            let hasClaude = check.summary.localizedCaseInsensitiveContains("Claude")
            switch (hasCodex, hasClaude) {
            case (true, true): return L10n.string("Available: Codex and Claude")
            case (true, false): return L10n.string("Available: Codex")
            case (false, true): return L10n.string("Available: Claude")
            case (false, false): return check.summary
            }
        case ("provider", .error):
            return L10n.string("Neither Codex CLI nor Claude CLI was found")
        case ("watchdog", .ok):
            return L10n.string("Background checks are active")
        case ("watchdog", .error):
            return L10n.string("The required background check is not registered or needs approval")
        default:
            return check.summary
        }
    }

    private func remediation(for id: String) -> String? {
        switch id {
        case "tmux", "state_helper", "power_runtime":
            L10n.string("Run Repair to restore Detach's bundled runtime.")
        case "provider":
            L10n.string("Install and authenticate Codex CLI or Claude CLI, then retry setup.")
        case "cli_path":
            L10n.string("Open a new Terminal window. Repair will configure the detach command for your shell again.")
        case "app_location":
            L10n.string("Running from a DMG or temporary copy is unreliable.")
        default:
            nil
        }
    }
}
