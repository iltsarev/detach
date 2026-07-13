import SwiftUI

struct SettingsView: View {
    let installation: InstallationStore
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0
    @State private var confirmUninstall = false
    @State private var confirmPurge = false

    var body: some View {
        Form {
            Section("Основные") {
                if installation.hasDistributionPayload {
                    LabeledContent("CLI", value: AppSettings.defaultDetachPath)
                } else {
                    TextField("Путь к detach", text: $detachPath)
                }
                Slider(value: $pollInterval, in: 1...10, step: 1) {
                    Text("Интервал обновления: \(Int(pollInterval)) с")
                }
            }
            Section("Установка") {
                Button("Repair CLI") { Task { await installation.repair() } }
                    .disabled(installation.isBusy || !installation.isStableApplicationLocation)
                Button("Удалить CLI и watchdog…", role: .destructive) {
                    confirmUninstall = true
                }
                .disabled(installation.isBusy)
                Button("Удалить всё, включая чекпойнты…", role: .destructive) {
                    confirmPurge = true
                }
                .disabled(installation.isBusy)
            }
            Section("Keep-awake") {
                Toggle("Amphetamine Closed-Display Mode", isOn: Binding(
                    get: { installation.keepAwakeEnabled },
                    set: { value in
                        Task { await installation.setKeepAwakeEnabled(value) }
                    }))
                    .disabled(installation.isBusy)
                Text("Опционально. Без этой настройки Detach продолжает использовать tmux, чекпойнты и caffeinate при открытой крышке.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog("Удалить установленные компоненты Detach?",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Удалить, сохранив чекпойнты", role: .destructive) {
                Task { await installation.uninstall(purgeState: false) }
            }
        } message: {
            Text("Detach.app останется на месте и сможет установить CLI снова.")
        }
        .confirmationDialog("Удалить CLI и все сохранённые сессии?",
                            isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Удалить безвозвратно", role: .destructive) {
                Task { await installation.uninstall(purgeState: true) }
            }
        } message: {
            Text("Будут удалены checkpoint/state-каталоги Detach. Хранилища ~/.codex и ~/.claude не затрагиваются.")
        }
    }
}
