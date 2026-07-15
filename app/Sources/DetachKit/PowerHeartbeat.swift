import Foundation

/// One immutable read of the background monitor's heartbeat file. Every UI
/// surface (Settings, onboarding, menu bar) must consume this shared reader so
/// freshness and state can never disagree between views.
public struct PowerHeartbeatSnapshot: Equatable, Sendable {
    public let statusURL: URL
    public let state: String?
    public let powerState: PowerProtectionState?
    public let checkedAt: Date?
    public let isFresh: Bool

    public var healthy: Bool { isFresh && state == "ok" }

    /// The state the app may present as current. A missing, stale, or
    /// unhealthy heartbeat is `.unknown`, never a guess from an old value.
    public var effectivePowerState: PowerProtectionState {
        guard healthy, let powerState else { return .unknown }
        return powerState
    }

    public func age(relativeTo now: Date) -> TimeInterval? {
        checkedAt.map { now.timeIntervalSince($0) }
    }
}

/// Reads the watchdog heartbeat using the `checked_at` timestamp inside the
/// document rather than file modification time.
public struct PowerHeartbeatReader: Sendable {
    public static let maximumAge: TimeInterval = 180
    /// Second-granularity timestamps written on the same clock may appear
    /// marginally in the future; only that margin is tolerated.
    static let futureTolerance: TimeInterval = 5

    private struct Payload: Decodable {
        let state: String
        let powerState: String?
        let checkedAt: String?

        enum CodingKeys: String, CodingKey {
            case state
            case powerState = "power_state"
            case checkedAt = "checked_at"
        }
    }

    public let statusURL: URL

    public init(statusURL: URL) {
        self.statusURL = statusURL
    }

    /// Keep this precedence aligned with the watchdog executable and the CLI:
    /// POWER override, then STATE, then XDG/detach, then HOME/.local/state.
    public static func defaultStatusURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil
    ) -> URL {
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        let root: URL
        if let explicit = value("DETACH_POWER_STATE_ROOT") {
            root = URL(fileURLWithPath: explicit, isDirectory: true)
        } else {
            let base: URL
            if let state = value("DETACH_STATE_ROOT") {
                base = URL(fileURLWithPath: state, isDirectory: true)
            } else if let xdg = value("XDG_STATE_HOME") {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
                    .appendingPathComponent("detach", isDirectory: true)
            } else {
                let home = homeDirectory
                    ?? value("HOME").map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? FileManager.default.homeDirectoryForCurrentUser
                base = home.appendingPathComponent(
                    ".local/state/detach", isDirectory: true)
            }
            root = base.appendingPathComponent("power", isDirectory: true)
        }
        return root.appendingPathComponent("watchdog-status.json")
    }

    public func read(now: Date = Date()) -> PowerHeartbeatSnapshot {
        guard let data = try? Data(contentsOf: statusURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return PowerHeartbeatSnapshot(
                statusURL: statusURL, state: nil, powerState: nil,
                checkedAt: nil, isFresh: false)
        }
        let checkedAt = payload.checkedAt.flatMap(Self.parseTimestamp)
        let isFresh = checkedAt.map {
            let age = now.timeIntervalSince($0)
            return age >= -Self.futureTolerance && age < Self.maximumAge
        } ?? false
        return PowerHeartbeatSnapshot(
            statusURL: statusURL,
            state: payload.state,
            powerState: payload.powerState.map {
                PowerProtectionState(rawValue: $0) ?? .unknown
            },
            checkedAt: checkedAt,
            isFresh: isFresh)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}
