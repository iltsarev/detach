import SwiftUI
import DetachKit

/// What the group name sheet creates or renames.
enum SidebarGroupNamePrompt: Identifiable, Equatable {
    /// A new group. A row's New Group command also moves its session there.
    case create(assigningSessionID: String?)
    case rename(SidebarGroup)

    var id: String {
        switch self {
        case .create(let sessionID): "create/\(sessionID ?? "")"
        case .rename(let group): "rename/\(group.id.uuidString)"
        }
    }
}

/// A group row inside one status section. The whole row toggles the group
/// and accepts dropped session rows.
struct SidebarGroupHeader: View {
    let group: SidebarGroup
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .appFont(.caption2, weight: .semibold)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .foregroundStyle(Brand.indigo)
                Text(group.name)
                    .appFont(.body, weight: .semibold)
                    .lineLimit(1)
                Text(verbatim: "\(count)")
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("%@ · %d", group.name, count))
        .accessibilityValue(isCollapsed ? L10n.string("Collapsed") : L10n.string("Expanded"))
        .accessibilityAddTraits(.isButton)
    }
}

struct SidebarGroupNameSheet: View {
    let prompt: SidebarGroupNamePrompt
    let groups: SidebarGroupStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: SidebarGroupError?

    init(prompt: SidebarGroupNamePrompt, groups: SidebarGroupStore) {
        self.prompt = prompt
        self.groups = groups
        if case .rename(let group) = prompt {
            _name = State(initialValue: group.name)
        } else {
            _name = State(initialValue: "")
        }
    }

    private var isRename: Bool {
        if case .rename = prompt { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? L10n.string("Rename Group") : L10n.string("New Group"))
                .appFont(.headline)
            TextField(L10n.string("Group name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if let error {
                Text(error.message)
                    .appFont(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isRename ? L10n.string("Rename") : L10n.string("Create"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(SidebarGroupsDocument.normalizedName(name) == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onChange(of: name) { error = nil }
    }

    private func commit() {
        let failure: SidebarGroupError?
        switch prompt {
        case .create(let sessionID):
            switch groups.createGroup(named: name) {
            case .success(let groupID):
                if let sessionID {
                    groups.assign(sessionID, to: groupID)
                }
                failure = nil
            case .failure(let error):
                failure = error
            }
        case .rename(let group):
            if case .failure(let error) = groups.renameGroup(group.id, to: name) {
                failure = error
            } else {
                failure = nil
            }
        }
        if let failure {
            error = failure
        } else {
            dismiss()
        }
    }
}

enum SidebarGroupLayout {
    /// Grouped rows sit one disclosure step to the right of their group.
    static let rowIndent: CGFloat = 16
}
