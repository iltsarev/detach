import SwiftUI
import UniformTypeIdentifiers
import DetachKit

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath

    @State private var projectDir: URL?
    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var prompt = ""
    @State private var showPicker = false
    @State private var launchFailure: TerminalLaunchFailure?
    @State private var isLaunching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новая сессия").font(.title3.weight(.bold))

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
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            if let launchFailure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(launchFailure.message).font(.caption).foregroundStyle(.red)
                    if launchFailure.requiresAutomationPermission {
                        Button("Открыть настройки") { TerminalLauncher.openAutomationSettings() }
                            .font(.caption)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Запустить в терминале") { launch() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
                    .disabled(projectDir == nil || isLaunching)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { projectDir = url }
        }
    }

    @MainActor
    private func launch() {
        guard let projectDir else { return }
        let command = TerminalCommand.start(
            detachPath: detachPath,
            provider: provider,
            projectDir: projectDir.path,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt)
        launchFailure = nil
        isLaunching = true
        let failure = TerminalLauncher.open(command: command)
        isLaunching = false
        if let failure {
            launchFailure = failure
        } else {
            dismiss()
        }
    }
}
