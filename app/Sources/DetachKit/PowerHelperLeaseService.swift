import Foundation

/// Durable root-helper state. `ownsClosedLidProtection` distinguishes a
/// setting Detach changed from a pre-existing setting it merely borrowed.
public struct PowerHelperPersistentState: Codable, Equatable, Sendable {
    public let schema: Int
    public var ownsClosedLidProtection: Bool
    public var leases: [PowerLease]
    public var bootSessionIdentifier: String?
    public var unregistrationPending: Bool

    public init(
        schema: Int = 1,
        ownsClosedLidProtection: Bool = false,
        leases: [PowerLease] = [],
        bootSessionIdentifier: String? = nil,
        unregistrationPending: Bool = false
    ) {
        self.schema = schema
        self.ownsClosedLidProtection = ownsClosedLidProtection
        self.leases = leases
        self.bootSessionIdentifier = bootSessionIdentifier
        self.unregistrationPending = unregistrationPending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == 1 else {
            throw PowerHelperLeaseServiceError.unsupportedStateSchema(schema)
        }
        self.schema = schema
        ownsClosedLidProtection = try container.decode(
            Bool.self, forKey: .ownsClosedLidProtection)
        leases = try container.decode([PowerLease].self, forKey: .leases)
        bootSessionIdentifier = try container.decodeIfPresent(
            String.self, forKey: .bootSessionIdentifier)
        unregistrationPending = try container.decodeIfPresent(
            Bool.self, forKey: .unregistrationPending) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case ownsClosedLidProtection = "owns_closed_lid_protection"
        case leases
        case bootSessionIdentifier = "boot_session_identifier"
        case unregistrationPending = "unregistration_pending"
    }
}

public protocol PowerHelperStateStoring: AnyObject {
    func load() throws -> PowerHelperPersistentState?
    func save(_ state: PowerHelperPersistentState) throws
}

public protocol PowerBatterySafetyReading {
    func isLowBattery() throws -> Bool
}

public protocol PowerBootSessionReading: Sendable {
    func currentBootSessionIdentifier() throws -> String
}

public enum PowerHelperLeaseServiceError: Error, Equatable, Sendable {
    case invalidIdentity
    case tooManyLeases
    case unsupportedStateSchema(Int)
    case closedLidRestorationFailed
    case activeLeasesPreventUnregistration
    case serviceQuiescing
    case invalidBootSessionIdentifier
    case requestExpired
}

extension PowerHelperLeaseServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "power lease identity is invalid"
        case .tooManyLeases:
            return "power lease limit reached"
        case let .unsupportedStateSchema(schema):
            return "unsupported power state schema: \(schema)"
        case .closedLidRestorationFailed:
            return "closed-lid sleep protection could not be restored"
        case .activeLeasesPreventUnregistration:
            return "active power leases prevent helper unregistration"
        case .serviceQuiescing:
            return "power helper is preparing to unregister"
        case .invalidBootSessionIdentifier:
            return "power helper could not identify the current boot session"
        case .requestExpired:
            return "power lease request expired before protection was confirmed"
        }
    }
}

/// Thread-safe policy engine used by the privileged helper.
///
/// Lease changes are persisted before any machine power mutation. When Detach
/// needs to enable closed-lid protection, ownership intent is also persisted
/// first. Thus a helper crash can leave at most a recoverable state: the next
/// launch knows it is responsible for restoring normal sleep.
public final class PowerHelperLeaseService: @unchecked Sendable {
    public static let defaultLeaseTimeout: TimeInterval = 120
    public static let maximumLeaseCount = 256

    private let store: any PowerHelperStateStoring
    private let backend: any ClosedLidProtectionControlling
    private let batteryReader: any PowerBatterySafetyReading
    private let bootSessionReader: any PowerBootSessionReading
    private let now: @Sendable () -> Date
    private let leaseTimeout: TimeInterval
    private let lock = NSLock()
    private let statusLock = NSLock()
    private var state: PowerHelperPersistentState
    private var isTerminating = false
    /// Read-only XPC status must never launch pmset. The daemon populates this
    /// cache during startup before accepting clients, then refreshes it from
    /// mutations and the periodic reconciler.
    private var cachedStatus = PowerProtectionStatus(
        state: .unavailable,
        leaseCount: 0,
        assertionActive: false,
        closedLidProtectionActive: false,
        helperReachable: false,
        transitionInProgress: false,
        lowBattery: false)

    public init(
        store: any PowerHelperStateStoring,
        backend: any ClosedLidProtectionControlling,
        batteryReader: any PowerBatterySafetyReading,
        bootSessionReader: any PowerBootSessionReading,
        now: @escaping @Sendable () -> Date = { Date() },
        leaseTimeout: TimeInterval = PowerHelperLeaseService.defaultLeaseTimeout
    ) throws {
        self.store = store
        self.backend = backend
        self.batteryReader = batteryReader
        self.bootSessionReader = bootSessionReader
        self.now = now
        self.leaseTimeout = max(1, leaseTimeout)
        state = try store.load() ?? PowerHelperPersistentState()
    }

    public func status() throws -> PowerProtectionStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return cachedStatus
    }

    public func reconcile() throws -> PowerProtectionStatus {
        try synchronized { try reconcileAndCacheLocked() }
    }

    /// Best-effort orderly-shutdown hook. Leases remain durable so a newly
    /// registered helper can resume them, while the persistent machine setting
    /// is restored before this process exits.
    public func prepareForTermination() throws {
        try synchronized {
            try recordingFailureLocked {
                // Close the mutation gate before restoring. The process exits
                // immediately after this hook, so no new lease may race the
                // final read-back verification.
                isTerminating = true
                try restoreOwnedProtectionLocked()
                updateCachedStatus(Self.unavailableStatus)
            }
        }
    }

    /// Quiesces mutations and verifies that Detach-owned closed-lid
    /// protection has been removed before SMAppService deletes the launchd
    /// job. Active leases are never interrupted for an app update; the app
    /// leaves the current helper registered and retries later.
    public func prepareForUnregistration() throws {
        try synchronized {
            try recordingFailureLocked {
                _ = try reconcileAndCacheLocked()
                guard state.leases.isEmpty else {
                    throw PowerHelperLeaseServiceError
                        .activeLeasesPreventUnregistration
                }
                if !state.unregistrationPending {
                    var candidate = state
                    candidate.unregistrationPending = true
                    try replaceState(candidate)
                }
                do {
                    try restoreOwnedProtectionLocked()
                    _ = try reconcileAndCacheLocked()
                } catch {
                    // A failed preflight must leave the still-registered
                    // service usable. Persist the reopened gate; if that save
                    // itself fails, durable state remains fail-closed.
                    let preparationError = error
                    var candidate = state
                    candidate.unregistrationPending = false
                    try replaceState(candidate)
                    throw preparationError
                }
            }
        }
    }

    /// Reopens the lease gate when SMAppService failed to unregister or when a
    /// later app launch recovers an interrupted unregister operation.
    @discardableResult
    public func cancelUnregistration() throws -> PowerProtectionStatus {
        try synchronized {
            try recordingFailureLocked {
                if state.unregistrationPending {
                    var candidate = state
                    candidate.unregistrationPending = false
                    try replaceState(candidate)
                }
                return try reconcileAndCacheLocked()
            }
        }
    }

    public func acquireLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool,
        requestDeadline: Date? = nil
    ) throws -> PowerProtectionStatus {
        try synchronized {
            try recordingFailureLocked {
                try Self.validate(identity)
                let instant = now()
                if let requestDeadline, instant >= requestDeadline {
                    throw PowerHelperLeaseServiceError.requestExpired
                }
                guard !isTerminating, !state.unregistrationPending else {
                    throw PowerHelperLeaseServiceError.serviceQuiescing
                }
                try reconcileBootSessionLocked()
                let previousLease = Self.index(of: identity, in: state.leases)
                    .map { state.leases[$0] }
                try upsertLeaseLocked(
                    identity, renewedAt: instant,
                    assertionActive: assertionActive)

                let status: PowerProtectionStatus
                do {
                    status = try reconcileAndCacheLocked(
                        requestDeadline: requestDeadline)
                } catch {
                    // A persisted initial lease must not be allowed to
                    // activate protection later after its caller has failed.
                    do {
                        _ = try rollbackInitialAcquireLocked(
                            identity, previousLease: previousLease)
                    } catch let rollbackError {
                        throw rollbackError
                    }
                    throw error
                }

                if let requestDeadline, now() >= requestDeadline {
                    _ = try rollbackInitialAcquireLocked(
                        identity, previousLease: previousLease)
                    throw PowerHelperLeaseServiceError.requestExpired
                }
                guard status.state == .protected else {
                    let rollbackStatus = try rollbackInitialAcquireLocked(
                        identity, previousLease: previousLease)
                    // Usually the rollback snapshot is the most truthful
                    // result (`lowBattery`, `allowed`, or `unavailable`). It
                    // can also be `protected` solely because another app owns
                    // the global setting; that must never confirm a Detach
                    // lease which no longer exists.
                    guard rollbackStatus.state == .protected else {
                        return rollbackStatus
                    }
                    return PowerProtectionStatus(
                        state: .unavailable,
                        leaseCount: rollbackStatus.leaseCount,
                        assertionActive: rollbackStatus.assertionActive,
                        closedLidProtectionActive:
                            rollbackStatus.closedLidProtectionActive,
                        helperReachable: rollbackStatus.helperReachable,
                        transitionInProgress:
                            rollbackStatus.transitionInProgress,
                        lowBattery: rollbackStatus.lowBattery)
                }
                return status
            }
        }
    }

    public func renewLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> PowerProtectionStatus {
        // Treat a missing renewal as a reacquire. This lets a still-running
        // provider recover after the helper state file is legitimately reset.
        try synchronized {
            try recordingFailureLocked {
                try Self.validate(identity)
                let instant = now()
                guard !isTerminating, !state.unregistrationPending else {
                    throw PowerHelperLeaseServiceError.serviceQuiescing
                }
                try reconcileBootSessionLocked()
                try upsertLeaseLocked(
                    identity, renewedAt: instant,
                    assertionActive: assertionActive)
                return try reconcileAndCacheLocked()
            }
        }
    }

    public func releaseLease(
        _ identity: PowerLeaseIdentity
    ) throws -> PowerProtectionStatus {
        try synchronized {
            try recordingFailureLocked {
                try Self.validate(identity)
                var candidate = state
                candidate.leases.removeAll {
                    $0.sessionName == identity.sessionName
                        && $0.runToken == identity.runToken
                }
                try replaceState(candidate)
                let status = try reconcileAndCacheLocked()
                if state.ownsClosedLidProtection && status.leaseCount == 0 {
                    throw PowerHelperLeaseServiceError
                        .closedLidRestorationFailed
                }
                return status
            }
        }
    }

    private func reconcileLocked(
        requestDeadline: Date? = nil
    ) throws -> PowerProtectionStatus {
        let instant = now()
        try reconcileBootSessionLocked()
        let lowBattery = try batteryReader.isLowBattery()
        let liveLeases = PowerLeaseRegistry.liveLeases(
            state.leases, now: instant, timeout: leaseTimeout)

        if liveLeases != state.leases {
            var candidate = state
            candidate.leases = liveLeases
            try replaceState(candidate)
        }

        // Persist ownership before enabling the setting. If the process dies
        // between this write and pmset, startup reconciliation safely either
        // completes the transition or clears the harmless ownership marker.
        if !liveLeases.isEmpty && !lowBattery
            && !state.ownsClosedLidProtection
        {
            let protectionWasAlreadyEnabled = try backend.protectionIsEnabled()
            if !protectionWasAlreadyEnabled {
                if let requestDeadline, now() >= requestDeadline {
                    throw PowerHelperLeaseServiceError.requestExpired
                }
                var candidate = state
                candidate.ownsClosedLidProtection = true
                try replaceState(candidate)
            }
        }

        var coordinator = PowerProtectionCoordinator(
            ownsClosedLidProtection: state.ownsClosedLidProtection)
        let status = coordinator.reconcile(
            leases: liveLeases,
            now: instant,
            timeout: leaseTimeout,
            lowBattery: lowBattery,
            backend: backend,
            allowEnablingProtection: { [now] in
                requestDeadline.map { now() < $0 } ?? true
            })

        if state.ownsClosedLidProtection
            != coordinator.ownsClosedLidProtection
        {
            var candidate = state
            candidate.ownsClosedLidProtection = coordinator.ownsClosedLidProtection
            try replaceState(candidate)
        }
        guard state.unregistrationPending else { return status }
        return PowerProtectionStatus(
            state: .transitioning,
            leaseCount: status.leaseCount,
            assertionActive: status.assertionActive,
            closedLidProtectionActive: status.closedLidProtectionActive,
            helperReachable: status.helperReachable,
            transitionInProgress: true,
            lowBattery: status.lowBattery)
    }

    private func reconcileBootSessionLocked() throws {
        let current = try bootSessionReader.currentBootSessionIdentifier()
        guard !current.isEmpty else {
            throw PowerHelperLeaseServiceError.invalidBootSessionIdentifier
        }
        guard state.bootSessionIdentifier != current else { return }
        var candidate = state
        if candidate.bootSessionIdentifier != nil {
            // tmux and its provider processes do not survive reboot. A lease
            // from another boot must never turn the persistent setting back
            // on, even if its wall-clock timestamp still looks fresh.
            candidate.leases = []
        }
        // Schema-1 state written before this field existed is adopted in place
        // so upgrading a helper does not interrupt same-boot live sessions.
        candidate.bootSessionIdentifier = current
        try replaceState(candidate)
    }

    private func restoreOwnedProtectionLocked() throws {
        guard state.ownsClosedLidProtection else { return }
        if try backend.protectionIsEnabled() {
            try backend.setProtectionEnabled(false)
            let remainsEnabled = try backend.protectionIsEnabled()
            guard !remainsEnabled else {
                throw PowerHelperLeaseServiceError.closedLidRestorationFailed
            }
        }
        var candidate = state
        candidate.ownsClosedLidProtection = false
        try replaceState(candidate)
    }

    private func upsertLeaseLocked(
        _ identity: PowerLeaseIdentity,
        renewedAt: Date,
        assertionActive: Bool
    ) throws {
        var candidate = state
        if let index = Self.index(of: identity, in: candidate.leases) {
            candidate.leases[index] = Self.lease(
                identity, renewedAt: renewedAt,
                assertionActive: assertionActive,
                existingID: candidate.leases[index].id)
        } else {
            guard candidate.leases.count < Self.maximumLeaseCount else {
                throw PowerHelperLeaseServiceError.tooManyLeases
            }
            candidate.leases.append(Self.lease(
                identity, renewedAt: renewedAt,
                assertionActive: assertionActive))
        }
        try replaceState(candidate)
    }

    /// Restores only the identity touched by an initial acquire. Reconciliation
    /// may concurrently expire other durable leases or update ownership, so
    /// replacing the complete pre-request snapshot would resurrect stale state.
    private func rollbackInitialAcquireLocked(
        _ identity: PowerLeaseIdentity,
        previousLease: PowerLease?
    ) throws -> PowerProtectionStatus {
        var candidate = state
        candidate.leases.removeAll {
            $0.sessionName == identity.sessionName
                && $0.runToken == identity.runToken
        }
        if let previousLease {
            candidate.leases.append(previousLease)
        }
        try replaceState(candidate)
        let status = try reconcileAndCacheLocked()
        if status.leaseCount == 0 && state.ownsClosedLidProtection {
            throw PowerHelperLeaseServiceError.closedLidRestorationFailed
        }
        return status
    }

    private func reconcileAndCacheLocked(
        requestDeadline: Date? = nil
    ) throws -> PowerProtectionStatus {
        do {
            let status = try reconcileLocked(
                requestDeadline: requestDeadline)
            updateCachedStatus(status)
            return status
        } catch {
            updateCachedStatus(Self.unavailableStatus)
            throw error
        }
    }

    private func recordingFailureLocked<T>(
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch {
            updateCachedStatus(Self.unavailableStatus)
            throw error
        }
    }

    /// Called only while the mutation lock is held. `status()` takes only this
    /// short snapshot lock, so a slow pmset reconciliation cannot block UI or
    /// CLI status polling behind the root mutation queue.
    private func updateCachedStatus(_ status: PowerProtectionStatus) {
        statusLock.lock()
        cachedStatus = status
        statusLock.unlock()
    }

    private static var unavailableStatus: PowerProtectionStatus {
        PowerProtectionStatus(
            state: .unavailable,
            leaseCount: 0,
            assertionActive: false,
            closedLidProtectionActive: false,
            helperReachable: false,
            transitionInProgress: false,
            lowBattery: false)
    }

    private func replaceState(_ candidate: PowerHelperPersistentState) throws {
        try store.save(candidate)
        state = candidate
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func validate(_ identity: PowerLeaseIdentity) throws {
        guard !identity.sessionName.isEmpty,
              identity.sessionName.utf8.count <= 256,
              !identity.runToken.isEmpty,
              identity.runToken.utf8.count <= 512,
              !identity.sessionName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !identity.runToken.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PowerHelperLeaseServiceError.invalidIdentity
        }
    }

    private static func index(
        of identity: PowerLeaseIdentity,
        in leases: [PowerLease]
    ) -> Int? {
        leases.firstIndex {
            $0.sessionName == identity.sessionName
                && $0.runToken == identity.runToken
        }
    }

    private static func lease(
        _ identity: PowerLeaseIdentity,
        renewedAt: Date,
        assertionActive: Bool,
        existingID: String? = nil
    ) -> PowerLease {
        PowerLease(
            id: existingID ?? UUID().uuidString.lowercased(),
            sessionName: identity.sessionName,
            runToken: identity.runToken,
            renewedAt: renewedAt,
            assertionActive: assertionActive)
    }
}
