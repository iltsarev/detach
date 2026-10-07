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

/// A group row inside one sidebar section. The whole row toggles the group
/// and accepts dropped session rows.
struct SidebarGroupHeader: View {
    let group: SidebarGroup
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SidebarGroupLayout.disclosureSpacing) {
                Image(systemName: "chevron.right")
                    .appFont(.caption2, weight: .semibold)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(SessionPalette.secondary)
                    .frame(width: SidebarGroupLayout.disclosureWidth)
                Text(group.name)
                    .appFont(.caption, weight: .semibold)
                    .foregroundStyle(SessionPalette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: "\(count)")
                    .appFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(SessionPalette.secondary)
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
                    .accessibilityIdentifier("sidebar-group-name-error")
                    .uiE2EGeometryProbe(
                        "sidebar-group-name-error",
                        label: error.message,
                        role: .staticText,
                        enabled: false)
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
                    .accessibilityIdentifier("sidebar-group-name-confirm")
                    .uiE2EGeometryProbe(
                        "sidebar-group-name-confirm",
                        label: isRename ? L10n.string("Rename") : L10n.string("Create"),
                        role: .button,
                        enabled: SidebarGroupsDocument.normalizedName(name) != nil)
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
    static let disclosureWidth: CGFloat = 12
    static let disclosureSpacing: CGFloat = 6
    /// Grouped rows start under the group name. Rows outside groups stay at
    /// the section edge, so a row after the last group never looks grouped.
    static let rowIndent = disclosureWidth + disclosureSpacing
}
