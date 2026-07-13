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
        .alert("Не удалось открыть терминал", isPresented: .init(
            get: { terminalFailure != nil },
            set: { if !$0 { terminalFailure = nil } })) {
            if terminalFailure?.requiresTerminalSelection == true {
                SettingsLink {
                    Text("Выбрать другой терминал")
                }
            }
            Button("Закрыть", role: .cancel) {}
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
                Text("Устанавливаем командные инструменты и проверяем компоненты…")
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
                Text("Фоновая служба обязательна: она восстанавливает keep-awake после сбоев, даже когда Detach.app закрыт.")
            } icon: {
                Image(systemName: "gearshape.2")
            }
            .foregroundStyle(.secondary)
        } else if case .installTools(let tools) = blocker {
            Label("Не хватает: \(tools.joined(separator: ", ")). Detach может открыть готовую команду установки.",
                  systemImage: "terminal")
                .foregroundStyle(.secondary)
        } else if blocker == .chooseProvider {
            Label("Нужен хотя бы один установленный и авторизованный AI-клиент.",
                  systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        } else if case .other(let summary) = blocker {
            Label(summary, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else if case .failed = store.phase {
            Label("Установленная версия CLI останется рабочей — повторная попытка безопасна.",
                  systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !store.isBusy {
            if !store.isStableApplicationLocation {
                Button("Открыть Applications") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
            } else if case .installAmphetamine(let prerequisites) = blocker {
                VStack(alignment: .leading, spacing: 10) {
                    if prerequisites.contains(.app) {
                        Button("Открыть Amphetamine в Mac App Store") {
                            openWebPage("https://apps.apple.com/app/amphetamine/id937984704")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                    }
                    if prerequisites.contains(.powerProtect) {
                        Button("Открыть официальную страницу Power Protect") {
                            openWebPage("https://x74353.github.io/Amphetamine-Power-Protect/")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                    }
                    Button("Перепроверить") { Task { await store.refreshContext() } }
                        .buttonStyle(.bordered)
                }
            } else if store.watchdogStatus == .requiresApproval {
                Button("Открыть системные настройки") { store.openLoginItemsSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
            } else {
                switch blocker {
                case .installAmphetamine:
                    EmptyView()
                case .installTools(let tools):
                    if let brewPath {
                        Button("Установить \(tools.joined(separator: " и "))") {
                            openInTerminal(
                                "\(shellQuoted(brewPath)) install "
                                    + tools.map(shellQuoted).joined(separator: " "))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                        .disabled(isLaunchingTerminal)
                    } else {
                        Button("Установить Homebrew") {
                            openWebPage("https://brew.sh")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                    }
                case .chooseProvider:
                    Menu("Установить AI-клиент") {
                        Button("Codex CLI") {
                            openWebPage("https://github.com/openai/codex#quickstart")
                        }
                        Button("Claude Code") {
                            openWebPage("https://docs.anthropic.com/en/docs/claude-code/getting-started")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                case .other:
                    Button("Перепроверить") { Task { await store.refreshContext() } }
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
        DisclosureGroup("Технические детали") {
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
                        Text(check.label).fontWeight(.medium).foregroundStyle(.primary)
                        Text(check.summary).appFont(.caption)
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
        if store.isBusy { return "Настраиваем Detach…" }
        if !store.isStableApplicationLocation { return "Переместите Detach в Applications" }
        if case .installAmphetamine = blocker { return "Установите Amphetamine и Power Protect" }
        if store.watchdogStatus == .requiresApproval {
            return "Разрешите фоновую работу"
        }
        if case .installTools = blocker { return "Установите необходимые компоненты" }
        if blocker == .chooseProvider { return "Подключите Codex или Claude" }
        if case .failed = store.phase { return "Не получилось завершить настройку" }
        return "Завершите настройку"
    }

    private var headerSubtitle: String {
        if store.isBusy { return "Обычно это занимает несколько секунд." }
        if !store.isStableApplicationLocation {
            return "Detach должен находиться в /Applications, чтобы обновляться и работать в фоне."
        }
        if case .installAmphetamine = blocker {
            return "Detach использует оба компонента для надёжной работы агентов при закрытой крышке."
        }
        if store.watchdogStatus == .requiresApproval {
            return "macOS просит один раз подтвердить работу Detach в фоне."
        }
        if case .installTools = blocker {
            return "tmux держит сессии запущенными, а jq помогает безопасно сохранять их состояние."
        }
        if blocker == .chooseProvider {
            return "Выберите AI-клиент, установите его по официальной инструкции и вернитесь в Detach."
        }
        return "Нажмите одну кнопку — Detach сам проверит и восстановит установку."
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
        if case .failed = store.phase { return "Повторить настройку" }
        return "Настроить Detach"
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

    private func remediation(for id: String) -> String? {
        switch id {
        case "tmux", "jq":
            "Установите зависимости в Terminal: brew install tmux jq"
        case "provider":
            "Установите и авторизуйте Codex CLI или Claude CLI, затем повторите настройку."
        case "cli_path":
            "Добавьте ~/.local/bin в PATH интерактивного shell."
        case "app_location":
            "Запуск из DMG или временной копии ненадёжен."
        case "amphetamine_app":
            "Установите Amphetamine из Mac App Store."
        case "amphetamine_power_protect":
            "После Amphetamine установите Power Protect с официального сайта."
        default:
            nil
        }
    }

    private func amphetamineStatusText(
        _ prerequisites: [AmphetaminePrerequisite]
    ) -> String {
        switch (prerequisites.contains(.app), prerequisites.contains(.powerProtect)) {
        case (true, true):
            "Нужны два обязательных компонента: Amphetamine.app и Amphetamine Power Protect."
        case (true, false):
            "Нужен обязательный Amphetamine.app."
        case (false, true):
            "Нужен обязательный Amphetamine Power Protect."
        case (false, false):
            "Нужны обязательные компоненты Amphetamine."
        }
    }
}
