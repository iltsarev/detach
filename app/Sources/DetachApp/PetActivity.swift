import Foundation
import DetachKit

/// Provider-neutral activity shown by the optional floating pet.
enum PetActivityState: String, Codable, Sendable, CaseIterable {
    case needsInput
    case blocked
    case ready
    case running

    var priority: Int {
        switch self {
        case .needsInput: 0
        case .blocked: 1
        case .ready: 2
        case .running: 3
        }
    }
}

struct PetActivity: Identifiable, Equatable, Sendable {
    let sessionID: String
    let title: String
    let provider: Provider
    let state: PetActivityState
    let recencyAt: Date?

    var id: String { sessionID }

    init(
        sessionID: String,
        title: String,
        provider: Provider,
        state: PetActivityState,
        recencyAt: Date?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.provider = provider
        self.state = state
        self.recencyAt = recencyAt
    }
}

/// Tracks terminal activity as unread without turning historical sessions into
/// fresh pet alerts on the first launch. Live waiting/running activity does not
/// need tracking because it is derived directly from the current snapshot.
struct PetActivityTracker: Equatable, Sendable {
    private(set) var unreadTerminalSessionIDs: Set<String>
    private(set) var lastObservedAt: Date?

    private var previousStatuses: [String: EffectiveStatus]

    init(
        unreadTerminalSessionIDs: Set<String> = [],
        lastObservedAt: Date? = nil
    ) {
        self.unreadTerminalSessionIDs = unreadTerminalSessionIDs
        self.lastObservedAt = lastObservedAt
        previousStatuses = [:]
    }

    mutating func observe(_ sessions: [Session], at now: Date = Date()) {
        let currentStatuses = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.effectiveStatus) })
        let notable = sessions.filter { Self.terminalActivityState(for: $0) != nil }
        let notableIDs = Set(notable.map(\.id))

        unreadTerminalSessionIDs.formIntersection(notableIDs)
        for session in notable {
            let transitioned = previousStatuses[session.id].map {
                $0 != session.effectiveStatus
            } ?? false
            let finishedWhileAway = lastObservedAt.flatMap { lastSeen in
                session.finishedAt.map { $0 > lastSeen }
            } ?? false
            if transitioned || finishedWhileAway {
                unreadTerminalSessionIDs.insert(session.id)
            }
        }

        previousStatuses = currentStatuses
        lastObservedAt = now
    }

    mutating func acknowledge(sessionID: String) {
        unreadTerminalSessionIDs.remove(sessionID)
    }

    static func terminalActivityState(
        for session: Session
    ) -> PetActivityState? {
        switch session.effectiveStatus {
        case .completed:
            .ready
        case .failed, .interrupted, .recoverable, .orphaned, .corrupt,
             .collision:
            .blocked
        case .starting, .running, .recovering, .hung, .stopped, .unknown:
            nil
        }
    }
}

enum PetActivityResolver {
    static func resolve(
        sessions: [Session],
        unreadTerminalSessionIDs: Set<String>
    ) -> [PetActivity] {
        sessions.compactMap { session in
            let state: PetActivityState?
            if session.needsUserInput {
                // Only a structured provider question/elicitation owns the
                // waiting animation. A normal completed turn is not proof that
                // the user owes the agent another message.
                state = .needsInput
            } else if session.effectiveStatus == .hung {
                state = .blocked
            } else if unreadTerminalSessionIDs.contains(session.id) {
                state = PetActivityTracker.terminalActivityState(for: session)
            } else if session.agentTurnState == .waiting {
                state = nil
            } else {
                if session.agentTurnState == .working {
                    state = switch session.effectiveStatus {
                    case .starting, .running, .recovering: .running
                    case .completed, .failed, .interrupted, .stopped, .hung,
                         .recoverable, .orphaned, .corrupt, .collision, .unknown:
                        nil
                    }
                } else {
                    state = nil
                }
            }

            guard let state else { return nil }
            return PetActivity(
                sessionID: session.id,
                title: session.displayTitle,
                provider: session.provider,
                state: state,
                recencyAt: session.finishedAt ?? session.createdAt)
        }
        .sorted {
            if $0.state.priority != $1.state.priority {
                return $0.state.priority < $1.state.priority
            }
            let leftRecency = $0.recencyAt ?? .distantPast
            let rightRecency = $1.recencyAt ?? .distantPast
            if leftRecency != rightRecency {
                return leftRecency > rightRecency
            }
            // `list --json` order is not part of the contract. A deterministic
            // final key prevents equal-priority sessions from stealing the pet
            // from each other between polls.
            return $0.sessionID < $1.sessionID
        }
    }
}
