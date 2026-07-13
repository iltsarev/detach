import SwiftUI
import UniformTypeIdentifiers
import DetachKit

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontPointSize) private var fontPointSize
    @AppStorage(AppSettings.terminalBundleIdentifierKey) private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier

    let detachPath: String

    @State private var projectDir: URL?
    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var prompt = ""
    @State private var showPicker = false
    @State private var launchFailure: TerminalLaunchFailure?
    @State private var isLaunching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Новая сессия").appFont(.title3, weight: .bold)

                LabeledContent("Проект") {
                    HStack {
                        Text(projectDir?.path ?? "не выбран")
                            .foregroundStyle(projectDir == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Выбрать…") { showPicker = true }
                    }
                }

                LabeledContent("Провайдер") {
                    Picker("", selection: $provider) {
                        ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("Имя") {
                    TextField("опционально, например migration", text: $name)
                }

                Text("Стартовый промпт (опционально)")
                    .appFont(.caption).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .appFont(.body)
                    .frame(height: max(70, fontPointSize * 5.5))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

                if let launchFailure {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(launchFailure.message).appFont(.caption).foregroundStyle(.red)
                        if launchFailure.requiresTerminalSelection {
                            SettingsLink {
                                Text("Выбрать другой терминал")
                            }
                            .appFont(.caption)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Отмена") { dismiss() }
                    Button("Запустить в терминале") {
                        Task { await launch() }
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.indigo)
                        .disabled(projectDir == nil || isLaunching)
                }
            }
            .padding(20)
        }
        .frame(
            minWidth: max(460, fontPointSize * 32),
            idealWidth: max(460, fontPointSize * 32),
            minHeight: 400)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { projectDir = url }
        }
    }

    @MainActor
    private func launch() async {
        guard !isLaunching, let projectDir else { return }
        isLaunching = true
        defer { isLaunching = false }
        let command = TerminalCommand.start(
            detachPath: detachPath,
            provider: provider,
            projectDir: projectDir.path,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt)
        launchFailure = nil
        let failure = await TerminalLauncher.open(
            command: command,
            terminalBundleIdentifier: terminalBundleIdentifier)
        if let failure {
            launchFailure = failure
        } else {
            dismiss()
        }
    }
}
