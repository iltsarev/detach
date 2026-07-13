import SwiftUI
import AppKit
import DetachKit

struct SessionDetailView: View {
    let session: Session
    let store: SessionStore
    let detachPath: String

    @State private var logPoller: LogPoller?
    @State private var actionError: String?
    @State private var terminalFailure: TerminalLaunchFailure?
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
        .alert("Не получилось", isPresented: .init(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .alert("Не удалось открыть Terminal", isPresented: .init(
            get: { terminalFailure != nil },
            set: { if !$0 { terminalFailure = nil } })) {
            if terminalFailure?.requiresAutomationPermission == true {
                Button("Открыть настройки") { TerminalLauncher.openAutomationSettings() }
            }
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(terminalFailure?.message ?? "")
        }
        .confirmationDialog("Удалить сессию «\(session.displayTitle)»?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { run(.delete) }
        } message: {
            Text("State-каталог и чекпойнты harness удаляются безвозвратно. Транскрипт провайдера в ~/.claude (~/.codex) не трогается.")
        }
    }

    private var providerTint: Color {
        Brand.tint(for: session.provider)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(session.displayTitle).font(.title2.weight(.bold))
            Text(session.effectiveStatus.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
            if let model = session.model {
                Text(model)
                    .font(.caption.weight(.semibold))
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
                MetaRow(label: "Проект", value: projectDir)
            }
            MetaRow(label: "Провайдер", value: session.provider.rawValue)
            if let uuid = session.agentSessionId {
                HStack(spacing: 4) {
                    MetaRow(label: "UUID", value: uuid)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uuid, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let created = session.createdAt {
                MetaRow(label: "Создана", value: created.formatted())
            }
            if let checkpoint = session.lastCheckpointAt {
                MetaRow(label: "Чекпойнт", value: checkpoint.formatted())
            }
            if let exit = session.exitStatus {
                MetaRow(label: "Код выхода", value: "\(exit)")
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
                Label("Имя занято чужой tmux-сессией", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func actionButton(_ action: SessionAction) -> some View {
        switch action {
        case .attach:
            Button("Открыть в терминале") { openInTerminal(TerminalCommand.attach(detachPath: detachPath, session: session)) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
        case .resume:
            Button("Resume в терминале") {
                if let command = TerminalCommand.resume(detachPath: detachPath, session: session) {
                    openInTerminal(command)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.indigo)
        case .recover:
            Button("Recover в терминале") { openInTerminal(TerminalCommand.recover(detachPath: detachPath, session: session)) }
                .buttonStyle(.borderedProminent)
                .tint(Brand.indigo)
        case .stop:
            Button("Stop", role: .destructive) { run(.stop) }
        case .delete:
            Button("Удалить", role: .destructive) { confirmDelete = true }
        }
    }

    @MainActor
    private func openInTerminal(_ command: String) {
        // NSAppleScript is main-thread-only. Invoke it just in time from the
        // explicit user action, including the first Automation prompt.
        if let failure = TerminalLauncher.open(command: command) {
            terminalFailure = failure
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
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("Занятый контекст модели")
    }
}

struct MetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}
