import Foundation

public enum SessionTransitionKind: String, Equatable, Sendable {
    case completed
    case failed
    case recoverable
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

    private var statuses: [Lifecycle: EffectiveStatus] = [:]
    private var pendingInterrupted: Set<Lifecycle> = []
    private var isPrimed = false

    public init() {}

    public mutating func observe(_ sessions: [Session]) -> [SessionTransition] {
        defer {
            statuses = Dictionary(uniqueKeysWithValues: sessions.map {
                (Lifecycle($0), $0.effectiveStatus)
            })
            pendingInterrupted.formIntersection(statuses.keys)
            isPrimed = true
        }

        guard isPrimed else { return [] }

        var transitions: [SessionTransition] = []
        for session in sessions {
            let lifecycle = Lifecycle(session)
            let previousStatus = statuses[lifecycle]

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
            guard previousStatus != session.effectiveStatus,
                  let kind = SessionTransitionKind(status: session.effectiveStatus) else {
                continue
            }
            transitions.append(SessionTransition(kind: kind, session: session))
        }
        return transitions
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
