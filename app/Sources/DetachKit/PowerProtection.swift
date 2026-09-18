import Foundation

/// The narrow boundary implemented by the privileged power helper.
///
/// Lease policy and ownership stay in `DetachKit`; platform IPC and the actual
/// system mutation live behind this protocol.
public protocol ClosedLidProtectionControlling {
    func protectionIsEnabled() throws -> Bool
    func setProtectionEnabled(_ enabled: Bool) throws
}

/// The user-facing result of Detach's two-part sleep protection.
///
/// Idle-sleep assertions and closed-lid protection are deliberately reported
/// as one state: a running detached session is protected only when both have
/// been verified.
public enum PowerProtectionState: String, Codable, Sendable {
    case allowed
    case transitioning
    case protected
    case lowBattery = "low_battery"
    case temperature
    case unavailable
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PowerProtectionState(rawValue: raw) ?? .unknown
    }
}

/// A snapshot used by the CLI and app to explain the effective power state.
public struct PowerProtectionStatus: Equatable, Codable, Sendable {
    public let state: PowerProtectionState
    public let leaseCount: Int
    public let assertionActive: Bool
    public let closedLidProtectionActive: Bool
    public let helperReachable: Bool
    public let transitionInProgress: Bool
    public let lowBattery: Bool
    public let thermalState: PowerThermalState
    public let thermalSafetyActive: Bool
    public let lowBatteryThreshold: PowerLowBatteryThreshold

    public init(
        state: PowerProtectionState,
        leaseCount: Int,
        assertionActive: Bool,
        closedLidProtectionActive: Bool,
        helperReachable: Bool,
        transitionInProgress: Bool,
        lowBattery: Bool,
        thermalState: PowerThermalState = .nominal,
        thermalSafetyActive: Bool = false,
        lowBatteryThreshold: PowerLowBatteryThreshold = .default
    ) {
        self.state = state
        self.leaseCount = max(0, leaseCount)
        self.assertionActive = assertionActive
        self.closedLidProtectionActive = closedLidProtectionActive
        self.helperReachable = helperReachable
        self.transitionInProgress = transitionInProgress
        self.lowBattery = lowBattery
        self.thermalState = thermalState
        self.thermalSafetyActive = thermalSafetyActive
        self.lowBatteryThreshold = lowBatteryThreshold
    }

    public static func derive(
        leaseCount: Int,
        assertionActive: Bool,
        closedLidProtectionActive: Bool,
        helperReachable: Bool,
        transitionInProgress: Bool,
        lowBattery: Bool,
        thermalState: PowerThermalState = .nominal,
        thermalSafetyActive: Bool = false,
        lowBatteryThreshold: PowerLowBatteryThreshold = .default
    ) -> PowerProtectionStatus {
        let normalizedLeaseCount = max(0, leaseCount)
        let state: PowerProtectionState

        if !helperReachable {
            state = .unavailable
        } else if lowBattery {
            // The low-battery state promises that both Detach protection
            // layers have been released. A still-live local assertion or a
            // borrowed external disablesleep setting makes that claim false.
            state = !assertionActive && !closedLidProtectionActive
                ? .lowBattery : .unavailable
        } else if thermalSafetyActive {
            state = !assertionActive && !closedLidProtectionActive
                ? .temperature : .unavailable
        } else if normalizedLeaseCount == 0 {
            // With no Detach leases, report the observed machine setting. A
            // pre-existing disablesleep value is still real user-visible
            // protection even though Detach does not own it.
            state = closedLidProtectionActive ? .protected : .allowed
        } else if assertionActive && closedLidProtectionActive {
            state = .protected
        } else if transitionInProgress {
            state = .transitioning
        } else {
            state = .unavailable
        }

        return PowerProtectionStatus(
            state: state,
            leaseCount: normalizedLeaseCount,
            assertionActive: assertionActive,
            closedLidProtectionActive: closedLidProtectionActive,
            helperReachable: helperReachable,
            transitionInProgress: transitionInProgress,
            lowBattery: lowBattery,
            thermalState: thermalState,
            thermalSafetyActive: thermalSafetyActive,
            lowBatteryThreshold: lowBatteryThreshold)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(PowerProtectionState.self, forKey: .state)
        leaseCount = max(0, try container.decode(Int.self, forKey: .leaseCount))
        assertionActive = try container.decode(Bool.self, forKey: .assertionActive)
        closedLidProtectionActive = try container.decode(
            Bool.self, forKey: .closedLidProtectionActive)
        helperReachable = try container.decode(Bool.self, forKey: .helperReachable)
        transitionInProgress = try container.decode(
            Bool.self, forKey: .transitionInProgress)
        lowBattery = try container.decode(Bool.self, forKey: .lowBattery)
        thermalState = try container.decodeIfPresent(
            PowerThermalState.self, forKey: .thermalState) ?? .unknown
        thermalSafetyActive = try container.decodeIfPresent(
            Bool.self, forKey: .thermalSafetyActive) ?? false
        lowBatteryThreshold = PowerLowBatteryThreshold.parse(
            try container.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold))
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case leaseCount = "lease_count"
        case assertionActive = "assertion_active"
        case closedLidProtectionActive = "closed_lid_protection_active"
        case helperReachable = "helper_reachable"
        case transitionInProgress = "transition_in_progress"
        case lowBattery = "low_battery"
        case thermalState = "thermal_state"
        case thermalSafetyActive = "thermal_safety_active"
        case lowBatteryThreshold = "low_battery_threshold"
    }
}

/// One renewable claim that a managed session still needs sleep protection.
public struct PowerLease: Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let sessionName: String
    public let runToken: String
    public let renewedAt: Date
    public let assertionActive: Bool

    public init(
        id: String,
        sessionName: String,
        runToken: String,
        renewedAt: Date,
        assertionActive: Bool = false
    ) {
        self.id = id
        self.sessionName = sessionName
        self.runToken = runToken
        self.renewedAt = renewedAt
        self.assertionActive = assertionActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        runToken = try container.decode(String.self, forKey: .runToken)
        renewedAt = try container.decode(Date.self, forKey: .renewedAt)
        assertionActive = try container.decodeIfPresent(
            Bool.self, forKey: .assertionActive) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionName = "session_name"
        case runToken = "run_token"
        case renewedAt = "renewed_at"
        case assertionActive = "assertion_active"
    }
}

public enum PowerLeaseRegistry {
    public static let defaultMaximumFutureClockSkew: TimeInterval = 300

    /// Returns leases whose last renewal is no older than `timeout`.
    /// A small future skew is retained for harmless wall-clock corrections;
    /// a far-future timestamp is rejected so corruption cannot create an
    /// effectively immortal lease.
    public static func liveLeases(
        _ leases: [PowerLease],
        now: Date,
        timeout: TimeInterval,
        maximumFutureClockSkew: TimeInterval =
            PowerLeaseRegistry.defaultMaximumFutureClockSkew
    ) -> [PowerLease] {
        guard timeout >= 0, maximumFutureClockSkew >= 0 else { return [] }
        return leases.filter {
            let age = now.timeIntervalSince($0.renewedAt)
            return age <= timeout && age >= -maximumFutureClockSkew
        }
    }
}

/// Applies lease/refcount, borrowing, low-battery, and ownership policy without
/// depending on ServiceManagement, XPC, IOKit, or a concrete helper process.
public struct PowerProtectionCoordinator: Sendable {
    public private(set) var ownsClosedLidProtection: Bool

    public init(ownsClosedLidProtection: Bool = false) {
        self.ownsClosedLidProtection = ownsClosedLidProtection
    }

    public mutating func reconcile(
        leases: [PowerLease],
        now: Date,
        timeout: TimeInterval,
        lowBattery: Bool,
        thermalState: PowerThermalState = .nominal,
        thermalSafetyActive: Bool = false,
        lowBatteryThreshold: PowerLowBatteryThreshold = .default,
        backend: any ClosedLidProtectionControlling,
        allowEnablingProtection: () -> Bool = { true }
    ) -> PowerProtectionStatus {
        let liveLeases = PowerLeaseRegistry.liveLeases(
            leases, now: now, timeout: timeout)
        let assertionActive = !liveLeases.isEmpty
            && liveLeases.allSatisfy(\.assertionActive)

        do {
            var closedLidProtectionActive = try backend.protectionIsEnabled()

            if liveLeases.isEmpty || lowBattery || thermalSafetyActive {
                if ownsClosedLidProtection {
                    if closedLidProtectionActive {
                        try backend.setProtectionEnabled(false)
                        closedLidProtectionActive = try backend.protectionIsEnabled()
                    }
                    if !closedLidProtectionActive {
                        ownsClosedLidProtection = false
                    }
                }
            } else if !closedLidProtectionActive {
                // Initial XPC acquire requests carry a server-side deadline.
                // Check it at the last possible point before the global power
                // mutation, after any preceding pmset query has completed.
                guard allowEnablingProtection() else {
                    return PowerProtectionStatus.derive(
                        leaseCount: liveLeases.count,
                        assertionActive: assertionActive,
                        closedLidProtectionActive: false,
                        helperReachable: true,
                        transitionInProgress: true,
                        lowBattery: lowBattery,
                        thermalState: thermalState,
                        thermalSafetyActive: thermalSafetyActive,
                        lowBatteryThreshold: lowBatteryThreshold)
                }
                try backend.setProtectionEnabled(true)
                // Record ownership as soon as our mutation succeeds. If
                // verification then fails, a later reconcile must still make
                // a best effort to restore normal system sleep.
                ownsClosedLidProtection = true
                closedLidProtectionActive = try backend.protectionIsEnabled()
            }

            return PowerProtectionStatus.derive(
                leaseCount: liveLeases.count,
                assertionActive: assertionActive,
                closedLidProtectionActive: closedLidProtectionActive,
                helperReachable: true,
                transitionInProgress: false,
                lowBattery: lowBattery,
                thermalState: thermalState,
                thermalSafetyActive: thermalSafetyActive,
                lowBatteryThreshold: lowBatteryThreshold)
        } catch {
            return PowerProtectionStatus.derive(
                leaseCount: liveLeases.count,
                assertionActive: assertionActive,
                closedLidProtectionActive: false,
                helperReachable: false,
                transitionInProgress: false,
                lowBattery: lowBattery,
                thermalState: thermalState,
                thermalSafetyActive: thermalSafetyActive,
                lowBatteryThreshold: lowBatteryThreshold)
        }
    }
}
