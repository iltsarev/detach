import AppKit
import DetachKit
import SwiftUI

struct SettingsView: View {
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
        .confirmationDialog(
            "Удалить установленные компоненты Detach?",
            isPresented: $confirmUninstall,
            titleVisibility: .visible
        ) {
            Button("Удалить, сохранив чекпойнты", role: .destructive) {
                Task { await installation.uninstall(purgeState: false) }
            }
        } message: {
            Text("Detach.app останется на месте и сможет установить CLI снова.")
        }
        .confirmationDialog(
            "Удалить CLI и все сохранённые сессии?",
            isPresented: $confirmPurge,
            titleVisibility: .visible
        ) {
            Button("Удалить безвозвратно", role: .destructive) {
                Task { await installation.uninstall(purgeState: true) }
            }
        } message: {
            Text("Будут удалены checkpoint/state-каталоги Detach. Хранилища ~/.codex и ~/.claude не затрагиваются.")
        }
    }

    private var generalSection: some View {
        SettingsSectionView("Основные", systemImage: "slider.horizontal.3") {
            if installation.hasDistributionPayload {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("CLI")
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
                    Text("Путь к detach")
                    TextField("Путь к detach", text: $detachPath)
                        .labelsHidden()
                        .appFont(.body, design: .monospaced)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Интервал обновления: \(Int(pollInterval)) с")
                Slider(value: $pollInterval, in: 1...10, step: 1) {
                    Text("Интервал обновления")
                }
                .labelsHidden()
            }

            HStack {
                Text("Размер шрифта")
                Spacer()
                TextField(
                    "Размер шрифта",
                    value: normalizedFontPointSize,
                    format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 42)
                Text("пт").foregroundStyle(.secondary)
                Stepper(
                    "Размер шрифта",
                    value: normalizedFontPointSize,
                    in: AppFontSize.allowedRange,
                    step: 1)
                    .labelsHidden()
            }
        }
    }

    private var terminalSection: some View {
        SettingsSectionView("Терминал", systemImage: "terminal") {
            Picker("Открывать команды в", selection: $terminalBundleIdentifier) {
                ForEach(terminalApplications) { application in
                    Text(application.displayName).tag(application.bundleIdentifier)
                }
                if selectedTerminalIsMissing {
                    Text("Недоступен — выберите другой")
                        .tag(terminalBundleIdentifier)
                }
            }
            .pickerStyle(.menu)
            .disabled(terminalApplications.isEmpty)

            if terminalApplications.isEmpty {
                Text("Не найдено ни одного установленного терминала, способного запускать .command-файлы.")
                    .settingsMessage(color: .red)
            } else if selectedTerminalIsMissing {
                Text("Ранее выбранное приложение удалено или больше не поддерживает запуск команд.")
                    .settingsMessage(color: .red)
            } else if let selectedTerminal {
                Text("Все интерактивные действия будут открываться в \(selectedTerminal.displayName).")
                    .settingsMessage()
            }

            Button {
                refreshTerminalApplications()
            } label: {
                Label("Обновить список терминалов", systemImage: "arrow.clockwise")
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSectionView("Уведомления", systemImage: "bell.badge") {
            Toggle("Сообщать о завершении и проблемах сессий", isOn: Binding(
                get: { notificationsEnabled },
                set: { value in
                    notificationsEnabled = value
                    Task { await notifications.configure(enabled: value) }
                }))
                .fixedSize(horizontal: false, vertical: true)

            Text(notificationStatusText)
                .settingsMessage(color: notifications.authorizationStatus == .denied ? .red : nil)

            if notifications.authorizationStatus == .denied {
                Button {
                    openNotificationSettings()
                } label: {
                    Label("Открыть настройки уведомлений", systemImage: "gearshape")
                }
            }
            if let errorMessage = notifications.errorMessage {
                Text(errorMessage).settingsMessage(color: .red)
            }
        }
    }

    private var installationSection: some View {
        SettingsSectionView("Установка", systemImage: "shippingbox") {
            fullWidthButton(
                "Переустановить командные инструменты",
                systemImage: "arrow.clockwise"
            ) {
                Task { await installation.repair() }
            }
            .disabled(installation.isBusy || !installation.isStableApplicationLocation)

            fullWidthButton(
                "Удалить установленные компоненты…",
                systemImage: "trash",
                role: .destructive
            ) {
                confirmUninstall = true
            }
            .disabled(installation.isBusy)

            fullWidthButton(
                "Удалить всё, включая чекпойнты…",
                systemImage: "trash.slash",
                role: .destructive
            ) {
                confirmPurge = true
            }
            .disabled(installation.isBusy)
        }
    }

    private var keepAwakeSection: some View {
        SettingsSectionView("Keep-awake", systemImage: "moon.stars") {
            Toggle("Amphetamine Closed-Display Mode", isOn: Binding(
                get: { installation.keepAwakeEnabled },
                set: { value in
                    Task { await installation.setKeepAwakeEnabled(value) }
                }))
                .disabled(installation.isBusy)
                .fixedSize(horizontal: false, vertical: true)
            Text("Опционально. Без этой настройки Detach продолжает использовать tmux, чекпойнты и caffeinate при открытой крышке.")
                .settingsMessage()
        }
    }

    private var updatesSection: some View {
        SettingsSectionView("Обновления", systemImage: "arrow.triangle.2.circlepath") {
            if updater.isAvailable {
                Toggle("Автоматически проверять обновления", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Проверки выполняет Sparkle в фоне по собственному расписанию.")
                    .settingsMessage()
            } else {
                Text("Автообновления недоступны")
                if let reason = updater.unavailableReason {
                    Text(reason).settingsMessage()
                }
            }
            if let errorMessage = updater.updateErrorMessage {
                Text(errorMessage).settingsMessage(color: .red)
            }
            if updater.shouldOfferManualDownload,
               let downloadURL = updater.manualDownloadURL {
                Link("Открыть страницу загрузки…", destination: downloadURL)
            }
        }
    }

    private var notificationStatusText: String {
        guard notificationsEnabled else { return "Уведомления выключены в Detach." }
        switch notifications.authorizationStatus {
        case .unknown:
            return "Проверяем системное разрешение…"
        case .notDetermined:
            return "macOS попросит разрешение на уведомления."
        case .denied:
            return "Уведомления запрещены в системных настройках macOS."
        case .authorized:
            return "Готово — сообщим, когда сессия завершится или потребует внимания."
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
