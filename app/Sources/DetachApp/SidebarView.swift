import SwiftUI
import DetachKit

struct SidebarView: View {
    @Environment(\.appFontPointSize) private var fontPointSize
    let store: SessionStore
    let detachPath: String
    @Binding var selectedID: String?
    @State private var showNewSession = false

    private func sessions(in section: SessionSection) -> [Session] {
        store.sessions.filter { $0.section == section }
    }

    var body: some View {
        List(selection: $selectedID) {
            ForEach(SessionSection.allCases, id: \.self) { section in
                let items = sessions(in: section)
                if !items.isEmpty {
                    Section("\(section.rawValue) · \(items.count)") {
                        ForEach(items) { session in
                            SessionRow(session: session).tag(session.id)
                        }
                    }
                }
            }
        }
        .overlay {
            if store.sessions.isEmpty && store.state == .ok {
                ContentUnavailableView {
                    Label {
                        Text("Сессий пока нет")
                    } icon: {
                        Image(systemName: "terminal").foregroundStyle(Brand.gradient)
                    }
                } description: {
                    Text("Запусти Codex или Claude в терминале")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar(store: store)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewSession = true
                } label: {
                    Label("Новая сессия", systemImage: "plus")
                        .foregroundStyle(Brand.indigo)
                }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(detachPath: detachPath)
        }
        .navigationSplitViewColumnWidth(
            min: max(230, fontPointSize * 18),
            ideal: max(260, fontPointSize * 20))
    }
}

struct SessionRow: View {
    let session: Session

    private var dotColor: Color {
        if session.isWaitingForUser { return .orange }
        switch session.effectiveStatus {
        case .running, .starting, .recovering: return Brand.teal
        case .completed, .stopped: return .secondary.opacity(0.6)
        case .failed, .interrupted: return .red
        case .recoverable, .orphaned, .corrupt, .collision, .unknown: return .orange
        }
    }

    private var isCustomName: Bool {
        // Default names end with the 8-hex project-dir digest; custom ones don't.
        session.name.range(of: "-[0-9a-f]{8}$", options: .regularExpression) == nil
    }

    private var subtitle: String {
        var parts: [String] = []
        if isCustomName { parts.append(session.name) }
        parts.append(session.displayStatus)
        if let exit = session.exitStatus { parts.append("exit \(exit)") }
        if let created = session.createdAt {
            parts.append(created.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).appFont(.body, weight: .semibold).lineLimit(1)
                    Text(session.provider.rawValue)
                        .appFont(.caption2)
                        .foregroundStyle(Brand.tint(for: session.provider))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Brand.tint(for: session.provider).opacity(0.35)))
                }
                Text(subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBar: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 6) {
            switch store.state {
            case .ok:
                if let updated = store.lastUpdated {
                    Text("Обновлено \(updated.formatted(date: .omitted, time: .standard))")
                }
            case .incompatible:
                Label("Несовместимая версия CLI — обнови detach", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .cliMissing:
                Label("detach недоступен", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }
}
