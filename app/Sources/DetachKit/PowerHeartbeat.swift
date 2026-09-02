import Darwin
import Foundation

/// One immutable read of the background monitor's heartbeat file. Every UI
/// surface (Settings, onboarding, menu bar) must consume this shared reader so
/// freshness and state can never disagree between views.
public struct PowerHeartbeatSnapshot: Equatable, Sendable {
    public let statusURL: URL
    public let state: String?
    public let powerState: PowerProtectionState?
    public let thermalState: PowerThermalState?
    public let thermalSafetyActive: Bool
    public let checkedAt: Date?
    public let isFresh: Bool

    public var healthy: Bool { isFresh && state == "ok" }

    /// The state the app may present as current. A missing, stale, or
    /// unhealthy heartbeat is `.unknown`, never a guess from an old value.
    public var effectivePowerState: PowerProtectionState {
        guard healthy, let powerState else { return .unknown }
        return powerState
    }

    public var effectiveThermalState: PowerThermalState {
        guard healthy, let thermalState else { return .unknown }
        return thermalState
    }

    public var isThermallyLimited: Bool {
        healthy && thermalSafetyActive
    }

    public init(
        statusURL: URL,
        state: String?,
        powerState: PowerProtectionState?,
        checkedAt: Date?,
        isFresh: Bool,
        thermalState: PowerThermalState? = nil,
        thermalSafetyActive: Bool = false
    ) {
        self.statusURL = statusURL
        self.state = state
        self.powerState = powerState
        self.checkedAt = checkedAt
        self.isFresh = isFresh
        self.thermalState = thermalState
        self.thermalSafetyActive = thermalSafetyActive
    }

    public func age(relativeTo now: Date) -> TimeInterval? {
        checkedAt.map { now.timeIntervalSince($0) }
    }

    /// True when a replacement changes only the watchdog clock. The app must
    /// retain the newest timestamp for truthful diagnostics, but that routine
    /// liveness write does not change any state a view presents.
    public func hasSamePresentedState(as other: Self) -> Bool {
        statusURL == other.statusURL
            && state == other.state
            && powerState == other.powerState
            && thermalState == other.thermalState
            && thermalSafetyActive == other.thermalSafetyActive
            && isFresh == other.isFresh
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
        let thermalState: String?
        let thermalSafetyActive: Bool?

        enum CodingKeys: String, CodingKey {
            case state
            case powerState = "power_state"
            case checkedAt = "checked_at"
            case thermalState = "thermal_state"
            case thermalSafetyActive = "thermal_safety_active"
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
            isFresh: isFresh,
            thermalState: payload.thermalState.map {
                PowerThermalState(rawValue: $0) ?? .unknown
            },
            thermalSafetyActive: payload.thermalSafetyActive ?? false)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}

/// Watches the watchdog's atomically replaced heartbeat without periodic
/// reads. A one-shot deadline only wakes when the current heartbeat would
/// become stale; each new write replaces that deadline.
public final class PowerHeartbeatMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (PowerHeartbeatSnapshot) -> Void

    private let reader: PowerHeartbeatReader
    private let handler: Handler
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var expirationSource: (any DispatchSourceTimer)?
    private var watchedDirectory: URL?
    private var lastSnapshot: PowerHeartbeatSnapshot?
    private var started = false

    public init(
        reader: PowerHeartbeatReader,
        queue: DispatchQueue = DispatchQueue(
            label: "dev.tsarev.detach.power-heartbeat"),
        handler: @escaping Handler
    ) {
        self.reader = reader
        self.handler = handler
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func start() {
        synchronized {
            guard !started else { return }
            started = true
            refresh(force: true)
            armClosestDirectory()
        }
    }

    public func stop() {
        synchronized {
            guard started else { return }
            started = false
            directorySource?.cancel()
            directorySource = nil
            watchedDirectory = nil
            expirationSource?.cancel()
            expirationSource = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }

    deinit {
        stop()
    }

    static func expirationDelay(
        for snapshot: PowerHeartbeatSnapshot,
        now: Date = Date()
    ) -> TimeInterval? {
        guard snapshot.isFresh, let checkedAt = snapshot.checkedAt else {
            return nil
        }
        return max(
            0.05,
            PowerHeartbeatReader.maximumAge
                - now.timeIntervalSince(checkedAt)
                + 0.05)
    }

    private func synchronized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func refresh(force: Bool = false) {
        guard started else { return }
        let snapshot = reader.read()
        scheduleExpiration(for: snapshot)
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        handler(snapshot)
    }

    private func scheduleExpiration(for snapshot: PowerHeartbeatSnapshot) {
        expirationSource?.cancel()
        expirationSource = nil
        guard let delay = Self.expirationDelay(for: snapshot) else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(250))
        source.setEventHandler { [weak self, weak source] in
            guard let self, self.expirationSource === source else { return }
            self.expirationSource = nil
            self.refresh()
        }
        expirationSource = source
        source.resume()
    }

    private func armClosestDirectory() {
        guard started,
              let directory = closestExistingDirectory(
                to: reader.statusURL.deletingLastPathComponent())
        else { return }
        guard watchedDirectory != directory || directorySource == nil else {
            return
        }

        directorySource?.cancel()
        directorySource = nil
        watchedDirectory = nil
        let descriptor = Darwin.open(
            directory.path,
            O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke, .attrib, .extend],
            queue: queue)
        // Refresh once registration is live. This closes the gap between the
        // earlier read and vnode readiness, including each move from an
        // existing ancestor to a newly created power directory.
        source.setRegistrationHandler { [weak self, weak source] in
            guard let self, self.directorySource === source else { return }
            self.refresh()
            self.armClosestDirectory()
        }
        source.setEventHandler { [weak self, weak source] in
            guard let self, self.directorySource === source else { return }
            self.refresh()
            self.armClosestDirectory()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        watchedDirectory = directory
        directorySource = source
        source.resume()
    }

    private func closestExistingDirectory(to target: URL) -> URL? {
        var candidate = target.standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }
}
