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
                Text(L10n.string("New session")).appFont(.title3, weight: .bold)

                LabeledContent(L10n.string("Project")) {
                    HStack {
                        Text(projectDir?.path ?? L10n.string("not selected"))
                            .foregroundStyle(projectDir == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L10n.string("Choose…")) { showPicker = true }
                    }
                }

                LabeledContent(L10n.string("Provider")) {
                    Picker("", selection: $provider) {
                        ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent(L10n.string("Name")) {
                    TextField(L10n.string("optional, for example migration"), text: $name)
                }

                Text(L10n.string("Initial prompt (optional)"))
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
                                Text(L10n.string("Choose another terminal"))
                            }
                            .appFont(.caption)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(L10n.string("Cancel")) { dismiss() }
                    Button(L10n.string("Launch in Terminal")) {
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
