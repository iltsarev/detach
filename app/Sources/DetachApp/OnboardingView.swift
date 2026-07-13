import AppKit
import SwiftUI
import DetachKit

struct OnboardingView: View {
    let store: InstallationStore
    @Environment(\.appFontPointSize) private var fontPointSize
    @AppStorage(AppSettings.terminalBundleIdentifierKey) private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier
    @State private var terminalFailure: TerminalLaunchFailure?
    @State private var isLaunchingTerminal = false

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
        .alert(L10n.string("Could not open Terminal"), isPresented: .init(
            get: { terminalFailure != nil },
            set: { if !$0 { terminalFailure = nil } })) {
            if terminalFailure?.requiresTerminalSelection == true {
                SettingsLink {
                    Text(L10n.string("Choose Another Terminal"))
                }
            }
            Button(L10n.string("Close"), role: .cancel) {}
        } message: {
            Text(terminalFailure?.message ?? "")
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
        } else if case .installAmphetamine(let prerequisites) = blocker {
            Label(
                amphetamineStatusText(prerequisites),
                systemImage: "bolt.heart")
                .foregroundStyle(.secondary)
        } else if store.watchdogStatus == .requiresApproval {
            Label {
                Text(L10n.string("The background service is required: it restores keep-awake after failures, even when Detach.app is closed."))
            } icon: {
                Image(systemName: "gearshape.2")
            }
            .foregroundStyle(.secondary)
        } else if case .installTools(let tools) = blocker {
            Label(L10n.format(
                "Missing: %@. Detach can open a ready-to-run installation command.",
                tools.joined(separator: ", ")),
                  systemImage: "terminal")
                .foregroundStyle(.secondary)
        } else if blocker == .chooseProvider {
            Label(L10n.string("At least one installed and authenticated AI client is required."),
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
            } else if case .installAmphetamine(let prerequisites) = blocker {
                VStack(alignment: .leading, spacing: 10) {
                    if prerequisites.contains(.app) {
                        Button(L10n.string("Open Amphetamine in the Mac App Store")) {
                            openWebPage("https://apps.apple.com/app/amphetamine/id937984704")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                    }
                    if prerequisites.contains(.powerProtect) {
                        Button(L10n.string("Open the official Power Protect page")) {
                            openWebPage("https://x74353.github.io/Amphetamine-Power-Protect/")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                    }
                    Button(L10n.string("Check Again")) {
                        Task { await store.refreshContext() }
                    }
                        .buttonStyle(.bordered)
                }
            } else if store.watchdogStatus == .requiresApproval {
                Button(L10n.string("Open System Settings")) {
                    store.openLoginItemsSettings()
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
            } else {
                switch blocker {
                case .installAmphetamine:
                    EmptyView()
                case .installTools(let tools):
                    if let brewPath {
                        Button(L10n.format(
                            "Install %@",
                            ListFormatter.localizedString(byJoining: tools))) {
                            openInTerminal(
                                "\(shellQuoted(brewPath)) install "
                                    + tools.map(shellQuoted).joined(separator: " "))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                        .disabled(isLaunchingTerminal)
                    } else {
                        Button(L10n.string("Install Homebrew")) {
                            openWebPage("https://brew.sh")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                    }
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
        if case .installAmphetamine = blocker {
            return L10n.string("Install Amphetamine and Power Protect")
        }
        if store.watchdogStatus == .requiresApproval {
            return L10n.string("Allow Background Activity")
        }
        if case .installTools = blocker {
            return L10n.string("Install Required Components")
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
        if case .installAmphetamine = blocker {
            return L10n.string("Detach uses both components to keep agents running reliably with the lid closed.")
        }
        if store.watchdogStatus == .requiresApproval {
            return L10n.string("macOS asks you once to allow Detach to run in the background.")
        }
        if case .installTools = blocker {
            return L10n.string("tmux keeps sessions running, while jq helps save their state safely.")
        }
        if blocker == .chooseProvider {
            return L10n.string("Choose an AI client, install it using the official instructions, and return to Detach.")
        }
        return L10n.string("Click one button — Detach will check and repair the installation.")
    }

    private var headerIcon: String {
        if store.isBusy { return "shippingbox.and.arrow.backward" }
        if !store.isStableApplicationLocation { return "folder.badge.plus" }
        if case .installAmphetamine = blocker { return "bolt.heart" }
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

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func openInTerminal(_ command: String) {
        Task { @MainActor in
            guard !isLaunchingTerminal else { return }
            isLaunchingTerminal = true
            defer { isLaunchingTerminal = false }
            if let failure = await TerminalLauncher.open(
                command: command,
                terminalBundleIdentifier: terminalBundleIdentifier) {
                terminalFailure = failure
            }
        }
    }

    private func openWebPage(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private var technicalError: String? {
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
            L10n.string("tmux")
        case "jq":
            L10n.string("jq")
        case "provider":
            L10n.string("Provider CLI")
        case "sqlite":
            L10n.string("sqlite3")
        case "tar":
            L10n.string("tar")
        case "caffeinate":
            L10n.string("caffeinate")
        case "lockf":
            L10n.string("lockf")
        case "watchdog":
            L10n.string("Detach Background Service")
        case "amphetamine_app":
            L10n.string("Amphetamine.app")
        case "amphetamine_power_protect":
            L10n.string("Amphetamine Power Protect")
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
        case ("tmux", .ok), ("jq", .ok), ("sqlite", .ok), ("tar", .ok),
             ("caffeinate", .ok), ("lockf", .ok):
            guard let path = check.path, !path.isEmpty else { return check.summary }
            return L10n.format("Found: %@", path)
        case ("tmux", .error), ("jq", .error), ("sqlite", .error),
             ("tar", .error), ("caffeinate", .error), ("lockf", .error):
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
        case ("amphetamine_app", .ok):
            return L10n.string("Amphetamine is installed in Applications")
        case ("amphetamine_app", .error):
            return L10n.string("Install Amphetamine from the Mac App Store into Applications")
        case ("amphetamine_power_protect", .ok):
            return L10n.string("Power Protect is installed")
        case ("amphetamine_power_protect", .error):
            return L10n.string("Install Power Protect from the official Amphetamine website")
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
        case "tmux", "jq":
            L10n.string("Install the dependencies in Terminal: brew install tmux jq")
        case "provider":
            L10n.string("Install and authenticate Codex CLI or Claude CLI, then retry setup.")
        case "cli_path":
            L10n.string("Open a new Terminal window. Repair will configure the detach command for your shell again.")
        case "app_location":
            L10n.string("Running from a DMG or temporary copy is unreliable.")
        case "amphetamine_app":
            L10n.string("Install Amphetamine from the Mac App Store.")
        case "amphetamine_power_protect":
            L10n.string("After installing Amphetamine, install Power Protect from the official website.")
        default:
            nil
        }
    }

    private func amphetamineStatusText(
        _ prerequisites: [AmphetaminePrerequisite]
    ) -> String {
        switch (prerequisites.contains(.app), prerequisites.contains(.powerProtect)) {
        case (true, true):
            L10n.string("Two required components are missing: Amphetamine.app and Amphetamine Power Protect.")
        case (true, false):
            L10n.string("The required Amphetamine.app is missing.")
        case (false, true):
            L10n.string("The required Amphetamine Power Protect is missing.")
        case (false, false):
            L10n.string("Required Amphetamine components are missing.")
        }
    }
}
