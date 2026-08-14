import SwiftUI
import DetachKit

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontPointSize) private var fontPointSize
    @AppStorage(AppSettings.terminalBundleIdentifierKey, store: AppSettings.defaults)
    private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier

    let detachPath: String

    @State private var projectDir: URL?
    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var prompt = ""
    @State private var showAdvanced = false
    @FocusState private var promptFocused: Bool
    @State private var launchFailure: TerminalLaunchFailure?
    @State private var isLaunching = false

    init(detachPath: String, initialName: String = "") {
        self.detachPath = detachPath
        _name = State(initialValue: initialName)
    }

    private var normalizedName: String? {
        SessionNameValidator.normalizedCustomName(name)
    }

    private var isNameValid: Bool {
        SessionNameValidator.isValidInput(name, provider: provider)
    }

    private var canLaunch: Bool {
        projectDir != nil && isNameValid && !isLaunching
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            projectWell
            providerAndName
            advancedOptions
            launchFailureBanner
            footer
        }
        .padding(22)
        .frame(width: max(520, fontPointSize * 34))
        .background(PinWindowTopEdge())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-session-sheet")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .background {
            uiE2EGeometryProbe(identifier: "new-session-sheet")
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("New session"))
                .appFont(.title3, weight: .bold)
            Text(L10n.string("Start a managed run in your terminal."))
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var projectWell: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Project")
            Button { presentProjectChooser() } label: {
                HStack(spacing: 8) {
                    Image(systemName: projectDir == nil
                          ? "folder.badge.plus"
                          : "folder.fill")
                        .foregroundStyle(projectDir == nil
                                         ? .secondary
                                         : Brand.tint(for: provider))
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(projectDir?.lastPathComponent ?? L10n.string("not selected"))
                        .foregroundStyle(projectDir == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text(projectDir?.path
                         ?? L10n.string("The agent starts in this folder."))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(L10n.string("Choose…"))
                        .foregroundStyle(.secondary)
                }
                .appFont(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var selectedTerminalDisplayName: String {
        TerminalLaunchPresentation.displayName(for: terminalBundleIdentifier)
    }

    private var providerAndName: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Provider")
                Picker("", selection: $provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Brand.tint(for: provider))
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Name")
                TextField(L10n.string("optional, for example Rev (ai)"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("new-session-name")
                if !isNameValid {
                    Text(L10n.string("Use printable text up to 100 UTF-8 bytes."))
                        .appFont(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("new-session-name-validation")
                }
            }
        }
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                promptFocused = false
                showAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text(L10n.string("Advanced"))
                    Spacer(minLength: 0)
                }
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Terminal")
                        TerminalPreferencePicker(
                            bundleIdentifier: $terminalBundleIdentifier,
                            accessibilityIdentifier: "new-session-terminal")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Initial prompt (optional)")
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $prompt)
                                .appFont(.body)
                                .scrollContentBackground(.hidden)
                                .focused($promptFocused)
                                .padding(.horizontal, 6)
                                .padding(.top, 6)
                                .padding(.bottom, 10)
                                .frame(height: max(84, fontPointSize * 5.4))
                            if prompt.isEmpty && !promptFocused {
                                Text(L10n.string("Leave empty and type in the terminal."))
                                    .appFont(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor)))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var launchFailureBanner: some View {
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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.08)))
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !canLaunch, !isLaunching, projectDir == nil, isNameValid {
                Text(L10n.string("Choose a project to launch."))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-session-cancel")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "new-session-cancel")
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
                Button {
                    Task { await launch() }
                } label: {
                    HStack(spacing: 7) {
                        if isLaunching {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.string("Launching…"))
                        } else {
                            Image(systemName: "terminal")
                            Text(TerminalLaunchPresentation.title(
                                terminalDisplayName: selectedTerminalDisplayName))
                        }
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.tint(for: provider))
                    .disabled(!canLaunch)
                    .accessibilityIdentifier("new-session-launch")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "new-session-launch")
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
        }
    }

    private func fieldLabel(_ key: String) -> some View {
        Text(L10n.string(key))
            .appFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
    }

// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
    @ViewBuilder
    private func uiE2EGeometryProbe(identifier: String) -> some View {
        if AppSettings.uiE2E != nil {
            UIE2EGeometryProbe(identifier: identifier)
        }
    }
#endif
// quality-coverage:end ui-e2e-instrumentation

    @MainActor
    private func presentProjectChooser() {
        ProjectDirectoryChooser.present(
            from: PanelHostWindow.current(),
            selectedProject: projectDir
        ) { url in
            guard let url else { return }
            projectDir = url
        }
    }

    @MainActor
    private func launch() async {
        guard !isLaunching, isNameValid, let projectDir else { return }
        isLaunching = true
        defer { isLaunching = false }
        let command = TerminalCommand.start(
            detachPath: detachPath,
            provider: provider,
            projectDir: projectDir.path,
            name: normalizedName,
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
