import Foundation

@MainActor
public protocol SessionSnapshotCaching: AnyObject {
    func load() -> [Session]
    func store(_ sessions: [Session])
}

/// A bounded presentation cache for the last complete typed session list.
/// Cached rows paint cold startup only. They carry no mutation permission and
/// are replaced by the first fresh `list --json` snapshot.
@MainActor
public final class UserDefaultsSessionSnapshotCache: SessionSnapshotCaching {
    nonisolated public static let defaultKey = "sessionPresentationSnapshotV1"
    nonisolated public static let maximumSessionCount = 128
    nonisolated public static let maximumByteCount = 1_048_576

    private struct Document: Codable {
        let schema: Int
        let sessions: [Session]
    }

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsSessionSnapshotCache.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [Session] {
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumByteCount else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data),
              document.schema == 1,
              document.sessions.count <= Self.maximumSessionCount,
              document.sessions.allSatisfy({ $0.schema == 1 }),
              Set(document.sessions.map(\.id)).count == document.sessions.count
        else { return [] }
        return document.sessions.map(Self.presentationOnly)
    }

    public func store(_ sessions: [Session]) {
        guard sessions.count <= Self.maximumSessionCount,
              sessions.allSatisfy({ $0.schema == 1 }),
              Set(sessions.map(\.id)).count == sessions.count else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Document(schema: 1, sessions: sessions)),
              data.count <= Self.maximumByteCount else { return }
        defaults.set(data, forKey: key)
    }

    private static func presentationOnly(_ source: Session) -> Session {
        var session = source
        session.healthActions = []
        session.healthReason = nil
        session.reconcileAction = SessionReconcileAction.none
        session.ownershipProven = false
        session.cleanupEligible = false
        session.workerPID = nil
        session.providerPID = nil
        session.workerHeartbeatAt = nil
        session.heartbeatFresh = false
        session.checkpointFresh = false
        session.powerProtectionState = .unknown
        return session
    }
}
