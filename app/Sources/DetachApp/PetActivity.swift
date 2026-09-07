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
    let lifecycleID: String
    let title: String
    let provider: Provider
    let state: PetActivityState
    let recencyAt: Date?

    var id: String { lifecycleID }

    init(
        sessionID: String,
        lifecycleID: String? = nil,
        title: String,
        provider: Provider,
        state: PetActivityState,
        recencyAt: Date?
    ) {
        self.sessionID = sessionID
        self.lifecycleID = lifecycleID ?? "session:\(sessionID)"
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
    private(set) var unreadTerminalActivityIDs: Set<String>
    private(set) var observedTerminalActivityIDs: Set<String>
    private(set) var lastObservedAt: Date?

    private var previousStatuses: [String: EffectiveStatus]

    init(
        unreadTerminalActivityIDs: Set<String> = [],
        observedTerminalActivityIDs: Set<String> = [],
        lastObservedAt: Date? = nil
    ) {
        self.unreadTerminalActivityIDs = unreadTerminalActivityIDs
        self.observedTerminalActivityIDs = observedTerminalActivityIDs
        self.lastObservedAt = lastObservedAt
        previousStatuses = [:]
    }

    mutating func observe(_ sessions: [Session], at now: Date = Date()) {
        var currentStatuses: [String: EffectiveStatus] = [:]
        for session in sessions {
            currentStatuses[session.petActivityIdentity] =
                session.effectiveStatus
        }
        let notable = sessions.filter { Self.terminalActivityState(for: $0) != nil }
        let notableIDs = Set(notable.map(\.petActivityIdentity))

        unreadTerminalActivityIDs.formIntersection(notableIDs)
        observedTerminalActivityIDs.formIntersection(notableIDs)
        for session in notable {
            let activityID = session.petActivityIdentity
            let transitioned = previousStatuses[activityID].map {
                $0 != session.effectiveStatus
            } ?? false
            let finishedWhileAway = lastObservedAt.flatMap { lastSeen in
                session.finishedAt.map {
                    Self.timestampSecond($0) >= Self.timestampSecond(lastSeen)
                }
            } ?? false
            if transitioned
                || (!observedTerminalActivityIDs.contains(activityID)
                    && finishedWhileAway) {
                unreadTerminalActivityIDs.insert(activityID)
            }
        }

        observedTerminalActivityIDs = notableIDs
        previousStatuses = currentStatuses
        lastObservedAt = now
    }

    mutating func acknowledge(activityID: String) {
        unreadTerminalActivityIDs.remove(activityID)
    }

    /// Converts the unreleased session-name storage used by older preview
    /// builds into lifecycle-scoped identifiers. A session created after the
    /// last observation can be a different run reusing the same name, so it
    /// must not inherit the old unread state.
    mutating func migrateLegacyUnreadSessionIDs(
        _ sessionIDs: Set<String>,
        sessions: [Session]
    ) {
        guard !sessionIDs.isEmpty else { return }
        for session in sessions where sessionIDs.contains(session.id) {
            if let lastObservedAt,
               let createdAt = session.createdAt,
               Self.timestampSecond(createdAt)
                    >= Self.timestampSecond(lastObservedAt) {
                continue
            }
            guard Self.terminalActivityState(for: session) != nil else {
                continue
            }
            unreadTerminalActivityIDs.insert(session.petActivityIdentity)
        }
    }

    static func terminalActivityState(
        for session: Session
    ) -> PetActivityState? {
        switch session.effectiveStatus {
        case .completed:
            .ready
        case .interrupted where session.stopRequestedAt != nil:
            nil
        case .failed, .interrupted, .recoverable, .orphaned, .corrupt,
             .collision:
            .blocked
        case .starting, .running, .recovering, .hung, .stopped, .unknown:
            nil
        }
    }

    private static func timestampSecond(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

enum PetActivityResolver {
    static func resolve(
        sessions: [Session],
        unreadTerminalActivityIDs: Set<String>
    ) -> [PetActivity] {
        var seenActivityIDs: Set<String> = []
        return sessions.compactMap { session in
            guard seenActivityIDs.insert(session.petActivityIdentity).inserted else {
                return nil
            }
            if session.effectiveStatus == .stopped
                || (session.effectiveStatus == .interrupted
                    && session.stopRequestedAt != nil) {
                return nil
            }
            let state: PetActivityState?
            if session.needsUserInput {
                // Only a structured provider question/elicitation owns the
                // waiting animation. A normal completed turn is not proof that
                // the user owes the agent another message.
                state = .needsInput
            } else if session.effectiveStatus == .hung {
                state = .blocked
            } else if unreadTerminalActivityIDs.contains(
                session.petActivityIdentity) {
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
                lifecycleID: session.petActivityIdentity,
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

private extension Session {
    /// `session_name` can be reused after deletion. Prefer the opaque run ID;
    /// older records fall back to immutable creation/provider metadata so a
    /// new run cannot inherit an unread badge or animation phase.
    var petActivityIdentity: String {
        if let lifecycleID, !lifecycleID.isEmpty {
            return "lifecycle:\(provider.rawValue):\(sessionName):\(lifecycleID)"
        }
        let created = createdAt.map {
            String(Int64(($0.timeIntervalSince1970 * 1_000).rounded()))
        } ?? "unknown"
        let knownAgentID = agentSessionId.flatMap { $0.isEmpty ? nil : $0 }
        let agent = createdAt == nil ? (knownAgentID ?? "unknown") : "created"
        return "legacy:\(provider.rawValue):\(sessionName):\(created):\(agent)"
    }
}
