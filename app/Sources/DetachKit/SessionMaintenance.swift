import Foundation

public struct SessionMaintenanceItem: Codable, Equatable, Sendable {
    public var provider: Provider
    public var sessionName: String
    public var effectiveStatus: EffectiveStatus
    public var reason: SessionHealthReason
    public var action: SessionReconcileAction

    enum CodingKeys: String, CodingKey {
        case provider, reason, action
        case sessionName = "session_name"
        case effectiveStatus = "effective_status"
    }
}

public struct SessionMaintenancePlan: Codable, Equatable, Sendable {
    public var schema: Int
    public var dryRun: Bool
    public var items: [SessionMaintenanceItem]

    enum CodingKeys: String, CodingKey {
        case schema, items
        case dryRun = "dry_run"
    }
}

enum SessionMaintenancePlanner {
    static func reconcile(inventory: Data) throws -> SessionMaintenancePlan {
        let parsed = SessionListParser.parse(String(decoding: inventory, as: UTF8.self))
        guard !parsed.hadInvalidLines else {
            throw StorageInspectionError.invalidInventory
        }
        let items = parsed.sessions.compactMap { session -> SessionMaintenanceItem? in
            guard let reason = session.healthReason,
                  let action = session.reconcileAction,
                  action != .none else { return nil }
            return SessionMaintenanceItem(
                provider: session.provider,
                sessionName: session.sessionName,
                effectiveStatus: session.effectiveStatus,
                reason: reason,
                action: action)
        }.sorted {
            ($0.provider.rawValue, $0.sessionName) < ($1.provider.rawValue, $1.sessionName)
        }
        return SessionMaintenancePlan(schema: 1, dryRun: true, items: items)
    }
}
