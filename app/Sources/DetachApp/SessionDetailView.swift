import SwiftUI
import AppKit
import DetachKit

struct SessionDetailView: View {
    let session: Session
    let store: SessionStore
    let detachPath: String

    @State private var logPoller: LogPoller?
    @State private var actionError: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metadata
            logView
            actionBar
        }
        .padding(16)
        .task(id: session.id) {
            let poller = LogPoller(
                cli: ProcessDetachCLI(executable: URL(fileURLWithPath: detachPath)),
                provider: session.provider, sessionName: session.sessionName)
            logPoller = poller
            await poller.fetchOnce()
            while !Task.isCancelled && session.section == .active {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await poller.fetchOnce()
            }
        }
        .alert("Не получилось", isPresented: .init(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("Удалить сессию «\(session.displayTitle)»?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { run(.delete) }
        } message: {
            Text("State-каталог и чекпойнты harness удаляются безвозвратно. Транскрипт провайдера в ~/.claude (~/.codex) не трогается.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(session.displayTitle).font(.title2.weight(.bold))
            Text(session.effectiveStatus.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
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

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text((logPoller?.errorText).map { "⚠︎ \($0)" }
                     ?? (logPoller?.lines.joined(separator: "\n") ?? "…"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("log-bottom")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
            .foregroundStyle(Color.green.opacity(0.9))
            .onChange(of: logPoller?.lines) {
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
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
        case .resume:
            Button("Resume в терминале") {
                if let command = TerminalCommand.resume(detachPath: detachPath, session: session) {
                    openInTerminal(command)
                }
            }
            .buttonStyle(.borderedProminent)
        case .recover:
            Button("Recover в терминале") { openInTerminal(TerminalCommand.recover(detachPath: detachPath, session: session)) }
                .buttonStyle(.borderedProminent)
        case .stop:
            Button("Stop", role: .destructive) { run(.stop) }
        case .delete:
            Button("Удалить", role: .destructive) { confirmDelete = true }
        }
    }

    private func openInTerminal(_ command: String) {
        // NSAppleScript can block (first-run Automation prompt, Terminal launch) —
        // keep it off the main actor.
        Task.detached {
            if let message = TerminalLauncher.open(command: command) {
                await MainActor.run { actionError = message }
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
