import AppKit
import SwiftUI
import DetachKit

struct OnboardingView: View {
    let store: InstallationStore
    @Environment(\.appFontPointSize) private var fontPointSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                primaryStatus
                actions
                technicalDetails
            }
            .frame(maxWidth: max(560, fontPointSize * 36), alignment: .leading)
            .padding(36)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: headerIcon)
                .appFont(.heroIcon)
                .foregroundStyle(Brand.gradient)
                .frame(width: max(52, AppFontRole.heroIcon.pointSize(base: fontPointSize)))
            VStack(alignment: .leading, spacing: 5) {
                Text(headerTitle).appFont(.title2, weight: .bold)
                Text(headerSubtitle).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var primaryStatus: some View {
        if store.isBusy {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Installing command-line tools and checking components…"))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else if store.distributionMatchesBundle
                    && store.powerHelperStatus == .requiresApproval {
            Label(
                L10n.string("Detach's native sleep protection needs one-time administrator approval."),
                systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        } else if store.distributionMatchesBundle
                    && (store.powerHelperStatus == .notRegistered
                        || store.powerHelperStatus == .unavailable) {
            Label(
                L10n.string("The bundled native power helper is not available yet."),
                systemImage: "exclamationmark.shield")
                .foregroundStyle(.secondary)
        } else if store.watchdogStatus == .requiresApproval {
            Label {
                Text(L10n.string(
                    "Allow Detach to record power health while the app is closed."))
            } icon: {
                Image(systemName: "gearshape.2")
            }
            .foregroundStyle(.secondary)
        } else if blocker == .chooseProvider {
            Label(L10n.string(
                "Install and authenticate Codex CLI or Claude CLI; Detach includes tmux, state handling, and sleep protection."),
                  systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        } else if case .other(let summary) = blocker {
            Label(localizedOtherSummary(fallback: summary),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else if case .failed = store.phase {
            Label(L10n.string("The installed CLI version will remain functional — retrying is safe."),
                  systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !store.isBusy {
            if !store.isStableApplicationLocation {
                Button(L10n.string("Open Applications")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
            } else if store.distributionMatchesBundle
                        && store.powerHelperStatus == .requiresApproval {
                Button(L10n.string("Open System Settings")) {
                    store.openPowerHelperApprovalSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
            } else if store.distributionMatchesBundle
                        && (store.powerHelperStatus == .notRegistered
                            || store.powerHelperStatus == .unavailable) {
                Button(L10n.string("Check Again")) {
                    Task { await store.refreshContext() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
            } else if store.watchdogStatus == .requiresApproval {
                Button(L10n.string("Open System Settings")) {
                    store.openLoginItemsSettings()
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
            } else {
                switch blocker {
                case .chooseProvider:
                    Menu(L10n.string("Install an AI Client")) {
                        Button(L10n.string("Codex CLI")) {
                            openWebPage("https://github.com/openai/codex#quickstart")
                        }
                        Button(L10n.string("Claude Code")) {
                            openWebPage("https://docs.anthropic.com/en/docs/claude-code/getting-started")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                case .other:
                    Button(L10n.string("Check Again")) {
                        Task { await store.refreshContext() }
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                case .repairInstallation, nil:
                    Button(buttonTitle) { Task { await store.repair() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                }
            }
        }
    }

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
        } ?? []
        return cliChecks + store.appContextChecks
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

    private var headerTitle: String {
        if store.isBusy { return L10n.string("Setting Up Detach…") }
        if !store.isStableApplicationLocation {
            return L10n.string("Move Detach to Applications")
        }
        if store.distributionMatchesBundle
            && store.powerHelperStatus == .requiresApproval
        {
            return L10n.string("Allow Native Sleep Protection")
        }
        if store.distributionMatchesBundle
            && (store.powerHelperStatus == .notRegistered
                || store.powerHelperStatus == .unavailable)
        {
            return L10n.string("Enable Native Sleep Protection")
        }
        if store.watchdogStatus == .requiresApproval {
            return L10n.string("Allow Background Activity")
        }
        if blocker == .chooseProvider { return L10n.string("Connect Codex or Claude") }
        if case .failed = store.phase { return L10n.string("Could Not Complete Setup") }
        return L10n.string("Complete Setup")
    }

    private var headerSubtitle: String {
        if store.isBusy { return L10n.string("This usually takes a few seconds.") }
        if !store.isStableApplicationLocation {
            return L10n.string("Detach must be in /Applications to update and run in the background.")
        }
        if store.distributionMatchesBundle
            && store.powerHelperStatus == .requiresApproval
        {
            return L10n.string(
                "Detach uses a narrowly scoped bundled helper so active agents can keep running with the lid closed.")
        }
        if store.distributionMatchesBundle
            && (store.powerHelperStatus == .notRegistered
                || store.powerHelperStatus == .unavailable)
        {
            return L10n.string(
                "The helper is bundled with Detach; no third-party keep-awake app is needed.")
        }
        if store.watchdogStatus == .requiresApproval {
            return L10n.string("macOS asks you once to allow Detach to monitor power in the background.")
        }
        if blocker == .chooseProvider {
            return L10n.string("Choose an AI client, install it using the official instructions, and return to Detach.")
        }
        return L10n.string("Click one button — Detach will check and repair the installation.")
    }

    private var headerIcon: String {
        if store.isBusy { return "shippingbox.and.arrow.backward" }
        if !store.isStableApplicationLocation { return "folder.badge.plus" }
        if store.distributionMatchesBundle && store.powerHelperStatus != .enabled {
            return "lock.shield"
        }
        if store.watchdogStatus == .requiresApproval {
            return "person.badge.key"
        }
        return "wrench.and.screwdriver"
    }

    private var buttonTitle: String {
        if case .failed = store.phase { return L10n.string("Retry Setup") }
        return L10n.string("Set Up Detach")
    }

    private var blocker: SetupBlocker? {
        SetupGuidance.blocker(
            distributionMatchesBundle: store.distributionMatchesBundle,
            checks: store.report?.checks ?? [])
    }

    private func openWebPage(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
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

    private func localizedOtherSummary(fallback: String) -> String {
        guard let check = store.report?.checks.first(where: {
            $0.section == .base && $0.required && $0.status != .ok
                && $0.summary == fallback
        }) else { return fallback }
        return localizedDiagnosticSummary(for: check)
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
