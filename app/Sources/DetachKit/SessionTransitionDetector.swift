import Foundation

public enum SessionTransitionKind: String, Equatable, Sendable {
    case completed
    case failed
    case recoverable
    case waitingForUser
}

public struct SessionTransition: Equatable, Sendable {
    public let kind: SessionTransitionKind
    public let session: Session

    public init(kind: SessionTransitionKind, session: Session) {
        self.kind = kind
        self.session = session
    }
}

/// Finds attention-worthy state changes between successful `list --json`
/// polls. The first observation only establishes a baseline, so launching the
/// app does not replay notifications for every historical finished session.
public struct SessionTransitionDetector: Sendable {
    private struct Lifecycle: Hashable, Sendable {
        let sessionName: String
        let createdAt: Date?

        init(_ session: Session) {
            sessionName = session.sessionName
            createdAt = session.createdAt
        }
    }

    private struct Snapshot: Sendable {
        let status: EffectiveStatus

        init(_ session: Session) {
            status = session.effectiveStatus
        }
    }

    private var snapshots: [Lifecycle: Snapshot] = [:]
    private var seenWaitingTurnIDs: [String: Set<String>] = [:]
    private var pendingInterrupted: Set<Lifecycle> = []
    private var isPrimed = false

    public init() {}

    public mutating func observe(_ sessions: [Session]) -> [SessionTransition] {
        defer {
            snapshots = Dictionary(uniqueKeysWithValues: sessions.map {
                (Lifecycle($0), Snapshot($0))
            })
            pendingInterrupted.formIntersection(snapshots.keys)
            for session in sessions where session.agentTurnState == .waiting {
                guard let turnID = session.agentTurnID, !turnID.isEmpty else { continue }
                let fallbackKey = conversationFallbackKey(for: session)
                if let agentKey = conversationAgentKey(for: session) {
                    if let fallbackIDs = seenWaitingTurnIDs.removeValue(forKey: fallbackKey) {
                        seenWaitingTurnIDs[agentKey, default: []].formUnion(fallbackIDs)
                    }
                    seenWaitingTurnIDs[agentKey, default: []].insert(turnID)
                } else {
                    seenWaitingTurnIDs[fallbackKey, default: []].insert(turnID)
                }
            }
            isPrimed = true
        }

        guard isPrimed else { return [] }

        var transitions: [SessionTransition] = []
        for session in sessions {
            let lifecycle = Lifecycle(session)
            let previous = snapshots[lifecycle]
            let previousStatus = previous?.status

            if session.effectiveStatus == .interrupted {
                if pendingInterrupted.remove(lifecycle) != nil {
                    transitions.append(SessionTransition(kind: .failed, session: session))
                } else if previousStatus != .interrupted {
                    // `detach stop` briefly passes through interrupted before
                    // recording stopped. Require one more successful poll so
                    // a user-requested stop does not look like a crash. This
                    // also covers a new session that crashed between polls.
                    pendingInterrupted.insert(lifecycle)
                }
                continue
            }

            pendingInterrupted.remove(lifecycle)
            if previousStatus != session.effectiveStatus,
               let kind = SessionTransitionKind(status: session.effectiveStatus) {
                transitions.append(SessionTransition(kind: kind, session: session))
                continue
            }

            if session.effectiveStatus == .running,
               session.agentTurnState == .waiting,
               let turnID = session.agentTurnID,
               !turnID.isEmpty,
               !hasSeenWaitingTurn(turnID, for: session) {
                transitions.append(SessionTransition(kind: .waitingForUser, session: session))
            }
        }
        return transitions
    }

    private func conversationAgentKey(for session: Session) -> String? {
        guard let agentSessionID = session.agentSessionId, !agentSessionID.isEmpty else {
            return nil
        }
        return "agent:\(session.provider.rawValue):\(agentSessionID)"
    }

    private func conversationFallbackKey(for session: Session) -> String {
        "session:\(session.sessionName)"
    }

    private func hasSeenWaitingTurn(_ turnID: String, for session: Session) -> Bool {
        if let agentKey = conversationAgentKey(for: session),
           seenWaitingTurnIDs[agentKey]?.contains(turnID) == true {
            return true
        }
        return seenWaitingTurnIDs[conversationFallbackKey(for: session)]?.contains(turnID) == true
    }
}

private extension SessionTransitionKind {
    init?(status: EffectiveStatus) {
        switch status {
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .recoverable:
            self = .recoverable
        default:
            return nil
        }
    }
}
