import Combine
import DetachKit

struct SessionShortcutAssignment: Equatable, Identifiable {
    let sessionID: String
    let displayTitle: String
    let slot: Int

    var id: Int { slot }
}

@MainActor
final class SessionShortcutRegistry: ObservableObject {
    static let slots = 1...9

    @Published private(set) var assignments: [SessionShortcutAssignment] = []

    private var slotsBySessionID: [String: Int] = [:]
    private var admissionOrder: [String] = []

    func reconcile(_ sessions: [Session]) {
        let eligible = sessions.filter(Self.isEligible)
        let eligibleIDs = Set(eligible.map(\.id))

        slotsBySessionID = slotsBySessionID.filter {
            eligibleIDs.contains($0.key)
        }
        admissionOrder.removeAll { !eligibleIDs.contains($0) }

        let admittedIDs = Set(admissionOrder)
        admissionOrder.append(contentsOf: eligible.lazy.map(\.id).filter {
            !admittedIDs.contains($0)
        })

        var freeSlots = Self.slots.filter {
            !slotsBySessionID.values.contains($0)
        }
        for sessionID in admissionOrder where slotsBySessionID[sessionID] == nil {
            guard let slot = freeSlots.first else { break }
            slotsBySessionID[sessionID] = slot
            freeSlots.removeFirst()
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: eligible.map {
            ($0.id, $0)
        })
        let updated = slotsBySessionID.compactMap { sessionID, slot in
            sessionsByID[sessionID].map {
                SessionShortcutAssignment(
                    sessionID: sessionID,
                    displayTitle: $0.displayTitle,
                    slot: slot)
            }
        }.sorted { $0.slot < $1.slot }

        // Published delivers its current value to a later subscriber, so an
        // unchanged snapshot does not need to redraw the sidebar or command menu.
        if assignments != updated {
            assignments = updated
        }
    }

    func slot(for sessionID: String) -> Int? {
        assignments.first { $0.sessionID == sessionID }?.slot
    }

    func sessionID(for slot: Int) -> String? {
        assignments.first { $0.slot == slot }?.sessionID
    }

    private static func isEligible(_ session: Session) -> Bool {
        session.section == .answerReady || session.section == .active
    }
}

enum SessionShortcutPresentation {
    static func badge(slot: Int) -> String {
        "⌘\(slot)"
    }

    static func accessibilityLabel(title: String, slot: Int?) -> String {
        guard let slot else { return title }
        return L10n.format("%@, Command-%d", title, slot)
    }
}
