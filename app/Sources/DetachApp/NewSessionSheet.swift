import SwiftUI
import DetachKit

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontPointSize) private var fontPointSize

    let store: SessionStore
    @Binding var selectedID: String?
    let projectPickerRoot: URL

    @State private var projectDir: URL?
    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var prompt = ""
    @State private var showAdvanced = false
    @FocusState private var promptFocused: Bool
    @State private var launchFailure: String?
    @State private var isLaunching = false

    init(
        store: SessionStore,
        selectedID: Binding<String?> = .constant(nil),
        initialName: String = "",
        showsAdvanced: Bool = false,
        initialProjectDir: URL? = nil,
        initialLaunchFailure: String? = nil,
        projectPickerRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.projectPickerRoot = projectPickerRoot
        _selectedID = selectedID
        _name = State(initialValue: initialName)
        _showAdvanced = State(initialValue: showsAdvanced)
        _projectDir = State(initialValue: initialProjectDir)
        _launchFailure = State(initialValue: initialLaunchFailure)
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
        .overlay(alignment: .topLeading) {
            PinWindowTopEdge()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
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
            Text(L10n.string("Start a managed run in Detach."))
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var projectWell: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(L10n.string("Project"))
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

    private var providerAndName: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L10n.string("Provider"))
                Picker("", selection: $provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Brand.tint(for: provider))
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L10n.string("Name"))
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
                }
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("new-session-advanced")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                uiE2EGeometryProbe(
                    identifier: "new-session-advanced",
                    semanticLabel: L10n.string("Advanced"),
                    semanticRole: .button)
            }
#endif
// quality-coverage:end ui-e2e-instrumentation

            if showAdvanced {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(L10n.string("Initial prompt (optional)"))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $prompt)
                            .appFont(.body)
                            .scrollContentBackground(.hidden)
                            .focused($promptFocused)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                            .frame(height: max(84, fontPointSize * 5.4))
                            .accessibilityIdentifier("new-session-prompt")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                            .background {
                                uiE2EGeometryProbe(identifier: "new-session-prompt")
                            }
#endif
// quality-coverage:end ui-e2e-instrumentation
                        if prompt.isEmpty && !promptFocused {
                            Text(L10n.string("Leave empty and type in the embedded terminal."))
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

    @ViewBuilder
    private var launchFailureBanner: some View {
        if let launchFailure {
            Text(launchFailure).appFont(.caption).foregroundStyle(.red)
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
                    NewSessionLaunch.label(
                        isLaunching: isLaunching)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.tint(for: provider))
                    .disabled(!canLaunch)
                    .accessibilityIdentifier("new-session-launch")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(
                            identifier: "new-session-launch",
                            semanticLabel: L10n.string("Start"),
                            semanticRole: .button,
                            semanticEnabled: canLaunch)
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .appFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
    }

// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
    @ViewBuilder
    private func uiE2EGeometryProbe(
        identifier: String,
        semanticLabel: String? = nil,
        semanticRole: NSAccessibility.Role? = nil,
        semanticEnabled: Bool = true
    ) -> some View {
        if AppSettings.uiE2E != nil {
            UIE2EGeometryProbe(
                identifier: identifier,
                semanticLabel: semanticLabel,
                semanticRole: semanticRole,
                semanticEnabled: semanticEnabled)
        }
    }
#endif
// quality-coverage:end ui-e2e-instrumentation

// quality-coverage:begin sheet-appkit
    @MainActor
    private func presentProjectChooser() {
        ProjectDirectoryChooser.present(
            from: PanelHostWindow.current(),
            selectedProject: projectDir,
            defaultDirectory: projectPickerRoot
        ) { url in
            guard let url else { return }
            projectDir = url
        }
    }

    @MainActor
    @discardableResult
    func launch() async -> SessionStartResult? {
        guard !isLaunching, isNameValid, let projectDir else { return nil }
        isLaunching = true
        defer { isLaunching = false }
        let result = await store.startDetached(
            provider: provider,
            projectDirectory: projectDir,
            name: normalizedName,
            prompt: NewSessionLaunch.trimmedPrompt(prompt))
        launchFailure = nil
        if let message = result.message {
            launchFailure = message
        } else {
            if let sessionID = result.sessionID { selectedID = sessionID }
            dismiss()
        }
        return result
    }
}
// quality-coverage:end sheet-appkit

enum NewSessionLaunch {
    static func trimmedPrompt(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    static func label(isLaunching: Bool) -> some View {
        HStack(spacing: 7) {
            if isLaunching {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Starting…"))
            } else {
                Image(systemName: "terminal")
                Text(L10n.string("Start"))
            }
        }
    }
}
