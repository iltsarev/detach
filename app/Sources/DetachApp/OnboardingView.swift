import AppKit
import SwiftUI
import DetachKit

struct OnboardingView: View {
    let store: InstallationStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let report = store.report {
                    checks(report.checks.filter { $0.section == .base && $0.id != "watchdog" }
                        + store.appContextChecks)
                    if report.checks.contains(where: { $0.section == .keepAwake }) {
                        DisclosureGroup("Keep-awake (опционально)") {
                            checks(report.checks.filter { $0.section == .keepAwake })
                                .padding(.top, 8)
                        }
                    }
                } else {
                    checks(store.appContextChecks)
                }
                actions
                if let message = failureMessage {
                    Text(message).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(30)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 40)).foregroundStyle(Brand.gradient)
            VStack(alignment: .leading, spacing: 3) {
                Text("Настройка Detach").font(.title2.weight(.bold))
                Text("CLI устанавливается из приложения атомарно; живые сессии сохраняют свою версию.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checks(_ values: [DiagnosticCheck]) -> some View {
        VStack(spacing: 8) {
            ForEach(values) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: check.status))
                        .foregroundStyle(color(for: check.status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.label).fontWeight(.medium)
                        Text(check.summary).font(.caption).foregroundStyle(.secondary)
                        if let path = check.path, path.hasPrefix("/") {
                            Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        if check.status == .error, let hint = remediation(for: check.id) {
                            Text(hint).font(.caption).foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch store.phase {
            case .syncing:
                ProgressView().controlSize(.small)
                Text("Проверяем установку…").foregroundStyle(.secondary)
            default:
                if !store.isStableApplicationLocation {
                    Button("Открыть /Applications") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.indigo)
                } else {
                    if store.watchdogStatus == .notRegistered && store.distributionMatchesBundle {
                        Button("Включить watchdog") { Task { await store.enableWatchdog() } }
                            .buttonStyle(.borderedProminent).tint(Brand.indigo)
                    }
                    if store.watchdogStatus == .requiresApproval {
                        Button("Открыть Login Items") { store.openLoginItemsSettings() }
                            .buttonStyle(.borderedProminent).tint(Brand.indigo)
                        Button("Перепроверить") { Task { await store.refreshContext() } }
                    }
                    switch store.automationStatus {
                    case .notChecked:
                        Button("Проверить Terminal") {
                            Task { await store.checkTerminalAutomation() }
                        }
                    case .denied:
                        Button("Открыть Automation Settings") { store.openAutomationSettings() }
                        Button("Перепроверить Terminal") {
                            Task { await store.refreshContext() }
                        }
                    case .allowed:
                        EmptyView()
                    }
                    Button("Repair") { Task { await store.repair() } }
                }
            }
            SettingsLink { Text("Настройки") }
        }
    }

    private var failureMessage: String? {
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
            "Установи зависимости в Terminal: brew install tmux jq"
        case "provider":
            "Установи и авторизуй Codex CLI или Claude CLI, затем нажми Repair."
        case "cli_path":
            "Добавь ~/.local/bin в PATH интерактивного shell."
        case "app_location":
            "Запуск из DMG/App Translocation ненадёжен для Login Item."
        default:
            nil
        }
    }
}
