import Foundation
import Observation
import DetachKit

/// A sidebar bucket is independent from lifecycle action eligibility. Raw
/// values preserve existing Working and Finished group collapse preferences.
enum SidebarSection: String, CaseIterable {
    case sessions = "active"
    case stopped = "finished"

    var displayName: String {
        L10n.string(self == .sessions ? "Sessions" : "Stopped")
    }

    static func containing(_ session: Session) -> Self {
        switch session.effectiveStatus {
        case .stopped, .interrupted: .stopped
        default: .sessions
        }
    }
}

/// Groups never change status, actions, ownership, or shortcuts.
struct SidebarGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
}

enum SidebarGroupError: Error, Equatable {
    case emptyName
    case duplicateName
    case tooManyGroups
    case unknownGroup

    var message: String {
        switch self {
        case .emptyName:
            L10n.string("Enter a group name.")
        case .duplicateName:
            L10n.string("A group with this name already exists.")
        case .tooManyGroups:
            L10n.format(
                "You can create up to %d groups.",
                SidebarGroupsDocument.maximumGroups)
        case .unknownGroup:
            L10n.string("This group no longer exists.")
        }
    }
}

/// App-only presentation preferences. The CLI and typed session state never
/// read this document.
struct SidebarGroupsDocument: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let maximumGroups = 32
    static let maximumNameLength = 60
    static let maximumEncodedBytes = 256 * 1024

    var schema = Self.currentSchema
    var groups: [SidebarGroup] = []
    /// Session name to group. The session name survives Resume and Recover;
    /// the lifecycle ID and provider UUID do not.
    var assignments: [String: UUID] = [:]
    /// Collapsed (sidebar section, group) pairs.
    var collapsed: Set<String> = []
    var stoppedCollapsed: Bool?

    static func collapseKey(section: SidebarSection, groupID: UUID) -> String {
        "\(section.rawValue)/\(groupID.uuidString)"
    }

    /// Trims the name and rejects an empty or control-character name. A long
    /// name keeps its first `maximumNameLength` characters.
    static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return String(trimmed.prefix(maximumNameLength))
    }

    /// An unreadable, oversized, or unknown-schema document is empty. A
    /// readable one keeps only valid groups and the references to them.
    static func decode(_ data: Data?) -> Self {
        guard let data, data.count <= maximumEncodedBytes,
              let document = try? JSONDecoder().decode(Self.self, from: data),
              document.schema == currentSchema
        else { return Self() }
        return document.validated()
    }

    func validated() -> Self {
        var result = Self()
        result.stoppedCollapsed = stoppedCollapsed
        var names = Set<String>()
        for group in groups where result.groups.count < Self.maximumGroups {
            guard let name = Self.normalizedName(group.name),
                  !result.groups.contains(where: { $0.id == group.id }),
                  names.insert(name.lowercased()).inserted
            else { continue }
            result.groups.append(SidebarGroup(id: group.id, name: name))
        }
        let groupIDs = Set(result.groups.map(\.id))
        result.assignments = assignments.filter { groupIDs.contains($0.value) }
        result.collapsed = collapsed.filter { key in
            result.groups.contains { group in
                SidebarSection.allCases.contains {
                    Self.collapseKey(section: $0, groupID: group.id) == key
                }
            }
        }
        return result
    }
}

/// One sidebar bucket with its groups first, in user order, and then the
/// sessions outside every group. Empty groups and sections are omitted.
struct SidebarSectionLayout: Equatable {
    struct GroupBlock: Equatable, Identifiable {
        let group: SidebarGroup
        let section: SidebarSection
        let sessions: [Session]

        var id: String { SidebarGroupsDocument.collapseKey(section: section, groupID: group.id) }
    }

    let section: SidebarSection
    let groupBlocks: [GroupBlock]
    let ungrouped: [Session]

    var count: Int {
        groupBlocks.reduce(ungrouped.count) { $0 + $1.sessions.count }
    }

    static func build(
        sessions: [Session],
        document: SidebarGroupsDocument,
        shortcutAssignments: [SessionShortcutAssignment] = []
    ) -> [SidebarSectionLayout] {
        let slots = Dictionary(uniqueKeysWithValues: shortcutAssignments.map {
            ($0.sessionID, $0.slot)
        })
        func slot(_ session: Session) -> Int {
            guard session.section == .active || session.section == .answerReady else {
                return Int.max
            }
            return slots[session.id] ?? Int.max
        }
        return SidebarSection.allCases.compactMap { section in
            let items = sessions.enumerated().filter {
                SidebarSection.containing($0.element) == section
            }.sorted { lhs, rhs in
                if section == .sessions, slot(lhs.element) != slot(rhs.element) {
                    return slot(lhs.element) < slot(rhs.element)
                }
                let leftDate = lhs.element.createdAt ?? .distantPast
                let rightDate = rhs.element.createdAt ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                return lhs.offset < rhs.offset
            }.map(\.element)
            guard !items.isEmpty else { return nil }
            let blocks = document.groups.compactMap { group -> GroupBlock? in
                let members = items.filter {
                    document.assignments[$0.id] == group.id
                }
                return members.isEmpty ? nil : GroupBlock(group: group, section: section, sessions: members)
            }
            let groupedIDs = Set(blocks.flatMap { $0.sessions.map(\.id) })
            return SidebarSectionLayout(
                section: section,
                groupBlocks: blocks,
                ungrouped: items.filter { !groupedIDs.contains($0.id) })
        }
    }
}

@Observable @MainActor
final class SidebarGroupStore {
    nonisolated static let storageKey = "sidebarGroupsV1"

    private let defaults: UserDefaults
    private(set) var document: SidebarGroupsDocument

    init(defaults: UserDefaults) {
        self.defaults = defaults
        document = SidebarGroupsDocument.decode(
            defaults.data(forKey: Self.storageKey))
    }

    var groups: [SidebarGroup] { document.groups }

    func groupID(for sessionID: String) -> UUID? {
        document.assignments[sessionID]
    }

    func createGroup(named rawName: String) -> Result<UUID, SidebarGroupError> {
        guard let name = SidebarGroupsDocument.normalizedName(rawName) else {
            return .failure(.emptyName)
        }
        guard !hasGroup(named: name, except: nil) else {
            return .failure(.duplicateName)
        }
        guard document.groups.count < SidebarGroupsDocument.maximumGroups else {
            return .failure(.tooManyGroups)
        }
        let group = SidebarGroup(id: UUID(), name: name)
        update { $0.groups.append(group) }
        return .success(group.id)
    }

    func renameGroup(
        _ groupID: UUID,
        to rawName: String
    ) -> Result<Void, SidebarGroupError> {
        guard let index = document.groups.firstIndex(where: { $0.id == groupID }) else {
            return .failure(.unknownGroup)
        }
        guard let name = SidebarGroupsDocument.normalizedName(rawName) else {
            return .failure(.emptyName)
        }
        guard !hasGroup(named: name, except: groupID) else {
            return .failure(.duplicateName)
        }
        update { $0.groups[index].name = name }
        return .success(())
    }

    /// Deleting a group never deletes sessions; they return to their status
    /// section outside every group.
    func deleteGroup(_ groupID: UUID) {
        update { document in
            document.groups.removeAll { $0.id == groupID }
            document.assignments = document.assignments.filter { $0.value != groupID }
            document.collapsed = document.collapsed.filter {
                !$0.hasSuffix("/" + groupID.uuidString)
            }
        }
    }

    /// A `nil` group removes the session from its group.
    func assign(_ sessionID: String, to groupID: UUID?) {
        guard let groupID else {
            update { $0.assignments[sessionID] = nil }
            return
        }
        guard document.groups.contains(where: { $0.id == groupID }) else { return }
        update { $0.assignments[sessionID] = groupID }
    }

    var stoppedCollapsed: Bool { document.stoppedCollapsed ?? false }

    func setStoppedCollapsed(_ collapsed: Bool) {
        update { $0.stoppedCollapsed = collapsed }
    }

    func isCollapsed(section: SidebarSection, groupID: UUID) -> Bool {
        document.collapsed.contains(
            SidebarGroupsDocument.collapseKey(section: section, groupID: groupID))
    }

    func setCollapsed(_ collapsed: Bool, section: SidebarSection, groupID: UUID) {
        let key = SidebarGroupsDocument.collapseKey(section: section, groupID: groupID)
        update { document in
            if collapsed {
                document.collapsed.insert(key)
            } else {
                document.collapsed.remove(key)
            }
        }
    }

    /// A selection made outside the sidebar (a shortcut, a notification, or a
    /// new session) opens the group that holds the row.
    func reveal(_ session: Session) {
        let section = SidebarSection.containing(session)
        if section == .stopped { setStoppedCollapsed(false) }
        guard let groupID = groupID(for: session.id) else { return }
        setCollapsed(false, section: section, groupID: groupID)
    }

    /// Call only with an authoritative session list. Cached rows cannot
    /// remove an assignment.
    func pruneAssignments(keeping sessionIDs: Set<String>) {
        update { document in
            document.assignments = document.assignments.filter {
                sessionIDs.contains($0.key)
            }
        }
    }

    private func hasGroup(named name: String, except groupID: UUID?) -> Bool {
        document.groups.contains {
            $0.id != groupID && $0.name.lowercased() == name.lowercased()
        }
    }

    private func update(_ change: (inout SidebarGroupsDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        document = next
        guard let data = try? JSONEncoder().encode(next),
              data.count <= SidebarGroupsDocument.maximumEncodedBytes
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
