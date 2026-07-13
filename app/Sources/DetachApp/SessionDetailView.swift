import SwiftUI
import AppKit
import DetachKit

struct SessionDetailView: View {
    let session: Session
    let store: SessionStore
    let detachPath: String
    @AppStorage(AppSettings.terminalBundleIdentifierKey) private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier

    @State private var logPoller: LogPoller?
    @State private var actionError: String?
    @State private var terminalFailure: TerminalLaunchFailure?
    @State private var isLaunchingTerminal = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metadata
            logView
            actionBar
        }
        .padding(16)
        .task(id: session.effectiveStatus) {
            let poller = LogPoller(
                cli: ProcessDetachCLI(executable: URL(fileURLWithPath: detachPath)),
                provider: session.provider, sessionName: session.sessionName)
            logPoller = poller
            await poller.fetchOnce()
            while !Task.isCancelled && session.section == .active {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                await poller.fetchOnce()
            }
        }
        .alert(L10n.string("Something went wrong"), isPresented: .init(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .alert(L10n.string("Could not open Terminal"), isPresented: .init(
            get: { terminalFailure != nil },
            set: { if !$0 { terminalFailure = nil } })) {
            if terminalFailure?.requiresTerminalSelection == true {
                SettingsLink {
                    Text(L10n.string("Choose another terminal"))
                }
            }
            Button(L10n.string("Close"), role: .cancel) {}
        } message: {
            Text(terminalFailure?.message ?? "")
        }
        .confirmationDialog(L10n.format("Delete session “%@”?", session.displayTitle),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.string("Delete"), role: .destructive) { run(.delete) }
        } message: {
            Text(L10n.string("The harness state directory and checkpoints will be permanently deleted. The provider transcript in ~/.claude (~/.codex) will not be affected."))
        }
    }

    private var providerTint: Color {
        Brand.tint(for: session.provider)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(session.displayTitle).appFont(.title2, weight: .bold)
            Text(session.displayStatus)
                .appFont(.caption, weight: .semibold)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
            if let model = session.model {
                Text(model)
                    .appFont(.caption, weight: .semibold)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(providerTint.opacity(0.16)))
                    .foregroundStyle(providerTint)
            }
            if session.contextSummary != nil {
                ContextGauge(session: session)
            }
            Spacer()
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let projectDir = session.projectDir {
                MetaRow(label: L10n.string("Project"), value: projectDir)
            }
            MetaRow(label: L10n.string("Provider"), value: session.provider.rawValue)
            if let uuid = session.agentSessionId {
                HStack(spacing: 4) {
                    MetaRow(label: L10n.string("UUID"), value: uuid)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uuid, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string("Copy session UUID"))
                }
            }
            if let created = session.createdAt {
                MetaRow(label: L10n.string("Created"), value: created.formatted())
            }
            if let checkpoint = session.lastCheckpointAt {
                MetaRow(label: L10n.string("Checkpoint"), value: checkpoint.formatted())
            }
            if let exit = session.exitStatus {
                MetaRow(label: L10n.string("Exit code"), value: "\(exit)")
            }
        }
    }

    private static let placeholderAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(white: 0.85, alpha: 1),
    ]

    private var logContent: NSAttributedString {
        if let error = logPoller?.errorText {
            var attributes = Self.placeholderAttributes
            attributes[.foregroundColor] = NSColor.systemOrange
            return NSAttributedString(string: "⚠︎ \(error)", attributes: attributes)
        }
        if let attributed = logPoller?.attributed, attributed.length > 0 {
            return attributed
        }
        return NSAttributedString(string: "…", attributes: Self.placeholderAttributes)
    }

    private var logView: some View {
        LogTextView(text: logContent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            ForEach(session.availableActions, id: \.self) { action in
                actionButton(action)
            }
            if session.effectiveStatus == .collision {
                Label(L10n.string("The name is used by another tmux session"), systemImage: "exclamationmark.triangle")
                    .appFont(.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SessionAction) -> some View {
        switch action {
        case .attach:
            Button(L10n.string("Open in Terminal")) {
                openInTerminal(TerminalCommand.attach(detachPath: detachPath, session: session))
            }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
                .disabled(isLaunchingTerminal)
        case .resume:
            Button(L10n.string("Resume in Terminal")) {
                if let command = TerminalCommand.resume(detachPath: detachPath, session: session) {
                    openInTerminal(command)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.indigo)
            .disabled(isLaunchingTerminal)
        case .recover:
            Button(L10n.string("Recover in Terminal")) {
                openInTerminal(TerminalCommand.recover(detachPath: detachPath, session: session))
            }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
                .disabled(isLaunchingTerminal)
        case .stop:
            Button(L10n.string("Stop"), role: .destructive) { run(.stop) }
        case .delete:
            Button(L10n.string("Delete"), role: .destructive) { confirmDelete = true }
        }
    }

    @MainActor
    private func openInTerminal(_ command: String) {
        Task {
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

    private func run(_ action: SessionAction) {
        Task {
            if let message = await store.perform(action, on: session) {
                actionError = message
            }
        }
    }
}

struct ContextGauge: View {
    let session: Session

    private var gaugeColor: Color {
        guard let fraction = session.contextFraction else { return .secondary }
        if fraction < 0.7 { return Brand.teal }
        if fraction < 0.9 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = session.contextFraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 56, height: 6)
                    Capsule().fill(gaugeColor).frame(width: max(4, 56 * fraction), height: 6)
                }
            }
            if let summary = session.contextSummary {
                Text(summary).appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .help(L10n.string("Model context used"))
    }
}

struct MetaRow: View {
    @Environment(\.appFontPointSize) private var fontPointSize
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).appFont(.caption).foregroundStyle(.secondary)
                .frame(width: max(80, fontPointSize * 6), alignment: .trailing)
            Text(value).appFont(.caption).textSelection(.enabled)
        }
    }
}
