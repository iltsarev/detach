import DetachKit
import Foundation

/// Pure derivation for the status item and its menu. State words and the
/// reason line come from the same heartbeat-first logic as the Mac Power
/// block, so the two surfaces can never disagree.
struct MenuBarPresentation: Equatable {
    /// Shape-first: the state is encoded by the glyph's form (filled, outline,
    /// badge), never by color alone.
    enum Icon: Equatable {
        case active(sessionCount: Int?)
        case canSleep
        case lowBattery
        case attention
        case unknown
    }

    enum ProblemAction: Equatable {
        case openSystemSettings
        case openDetach
    }

    struct SessionEntry: Equatable, Identifiable {
        let id: String
        let title: String
        let answerReady: Bool
    }

    let icon: Icon
    let power: MacPowerSettingsPresentation
    let ageSeconds: Int?
    let problem: ProblemAction?
    let sessions: [SessionEntry]
    let hiddenSessionCount: Int

    init(
        heartbeat: PowerHeartbeatSnapshot,
        sessions allSessions: [Session],
        helperStatus: PowerHelperRegistrationStatus,
        watchdogStatus: WatchdogStatus,
        distributionMatchesBundle: Bool,
        showsSessionCount: Bool,
        now: Date = Date()
    ) {
        let state = heartbeat.effectivePowerState
        let running = allSessions.filter { $0.effectiveStatus == .running }
        power = MacPowerSettingsPresentation(
            state: state,
            helperStatus: helperStatus,
            watchdogStatus: watchdogStatus,
            distributionMatchesBundle: distributionMatchesBundle,
            activeSessionCount: running.count)
        ageSeconds = heartbeat.healthy
            ? heartbeat.age(relativeTo: now).map { max(0, Int($0)) }
            : nil

        if helperStatus == .requiresApproval
            || watchdogStatus == .requiresApproval {
            problem = .openSystemSettings
        } else if state == .unavailable
            || helperStatus == .unavailable
            || helperStatus == .notRegistered {
            problem = .openDetach
        } else {
            problem = nil
        }

        if problem != nil, state != .protected, state != .transitioning {
            icon = .attention
        } else {
            switch state {
            case .protected, .transitioning:
                icon = .active(
                    sessionCount: showsSessionCount ? running.count : nil)
            case .allowed:
                icon = .canSleep
            case .lowBattery:
                icon = .lowBattery
            case .unavailable:
                icon = .attention
            case .unknown:
                icon = .unknown
            }
        }

        // Sessions awaiting a reply outrank ones that are still working.
        let ordered = running.sorted {
            if $0.isWaitingForUser != $1.isWaitingForUser {
                return $0.isWaitingForUser
            }
            return ($0.createdAt ?? .distantPast)
                > ($1.createdAt ?? .distantPast)
        }
        let visible = ordered.prefix(6)
        self.sessions = visible.map {
            SessionEntry(
                id: $0.id,
                title: $0.displayTitle,
                answerReady: $0.isWaitingForUser)
        }
        hiddenSessionCount = max(0, ordered.count - visible.count)
    }
}

extension MacPowerSettingsPresentation.Reason {
    /// Shared wording between Settings → System and the menu bar.
    var localizedText: String {
        switch self {
        case let .activeSessions(count):
            L10n.format("Held awake by active sessions: %d", count)
        case .protectionActive:
            L10n.string("Sleep protection is active")
        case .noActiveSessions:
            L10n.string("No active agent sessions")
        case .lowBattery:
            L10n.string("Protection released until power is connected")
        case .confirming:
            L10n.string("Confirming sleep protection…")
        case .helperUnreachable:
            L10n.string("The native power helper is unreachable")
        case .noFreshReport:
            L10n.string("No fresh report from the background monitor")
        }
    }
}

/// Shared freshness wording between Settings → System and the menu bar.
func powerCheckedAgeText(seconds: Int) -> String {
    if seconds < 120 { return L10n.format("checked %d s ago", seconds) }
    return L10n.format("checked %d min ago", seconds / 60)
}
