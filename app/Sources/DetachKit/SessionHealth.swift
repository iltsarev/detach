import Darwin
import Foundation

public enum TmuxHealthState: String, Codable, Sendable {
    case missing
    case foreign
    case dead
    case live
}

public enum RunTokenHealthState: String, Codable, Sendable {
    case match
    case missing
    case mismatch
}

public enum ProcessHealthState: String, Codable, Sendable {
    case unknown
    case alive
    case dead
    case mismatch
}

public enum FreshnessState: String, Codable, Sendable {
    case fresh
    case stale
    case missing
}

struct SessionProcessHealth: Equatable, Sendable {
    var worker: ProcessHealthState
    var provider: ProcessHealthState
}

struct SessionProcessIdentity: Equatable, Sendable {
    var parentPID: pid_t
    var userID: uid_t
}

/// Reads only the process identities named by one health record. The result is
/// presentation evidence. Runtime mutations repeat their established live
/// ownership and tmux-token checks immediately before they act.
enum SessionProcessHealthInspector {
    typealias Lookup = (pid_t) -> SessionProcessIdentity?

    static func inspect(
        tmuxState: TmuxHealthState,
        workerPID rawWorkerPID: String,
        providerPID rawProviderPID: String,
        panePID rawPanePID: String,
        userID: uid_t = geteuid(),
        lookup: Lookup = liveIdentity
    ) -> SessionProcessHealth {
        let workerPID = validPID(rawWorkerPID)
        let providerPID = validPID(rawProviderPID)
        let panePID = validPID(rawPanePID)
        var identities: [pid_t: SessionProcessIdentity?] = [:]
        func identity(_ pid: pid_t) -> SessionProcessIdentity? {
            if let cached = identities[pid] { return cached }
            let value = lookup(pid)
            identities[pid] = .some(value)
            return value
        }

        var worker: ProcessHealthState
        if let workerPID {
            worker = identity(workerPID)?.userID == userID ? .alive : .dead
        } else {
            worker = .unknown
        }

        var provider: ProcessHealthState
        if let providerPID {
            if identity(providerPID)?.userID != userID {
                provider = .dead
            } else if let workerPID,
                      worker == .alive,
                      isDescendant(
                          providerPID,
                          of: workerPID,
                          identity: identity) {
                provider = .alive
            } else {
                provider = .mismatch
            }
        } else {
            provider = .unknown
        }

        if tmuxState == .live,
           worker == .alive,
           panePID != workerPID {
            worker = .mismatch
            provider = .mismatch
        }
        return SessionProcessHealth(worker: worker, provider: provider)
    }

    private static func validPID(_ raw: String) -> pid_t? {
        guard let value = Int64(raw),
              value > 1,
              value <= Int64(Int32.max) else { return nil }
        return pid_t(value)
    }

    private static func isDescendant(
        _ child: pid_t,
        of ancestor: pid_t,
        identity: (pid_t) -> SessionProcessIdentity?
    ) -> Bool {
        var current = child
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard let parent = identity(current)?.parentPID,
                  parent > 1 else { return false }
            current = parent
        }
        return false
    }

    private static func liveIdentity(_ pid: pid_t) -> SessionProcessIdentity? {
        var information = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &information,
            expected) == expected else { return nil }
        return SessionProcessIdentity(
            parentPID: pid_t(information.pbi_ppid),
            userID: uid_t(information.pbi_uid))
    }
}

public enum SessionHealthReason: String, Codable, Sendable {
    case healthy
    case finished
    case checkpointStale = "checkpoint_stale"
    case heartbeatStale = "heartbeat_stale"
    case heartbeatMissing = "heartbeat_missing"
    case tmuxServerMissing = "tmux_server_missing"
    case paneExited = "pane_exited"
    case foreignTmux = "foreign_tmux"
    case malformedMetadata = "malformed_metadata"
    case runTokenMissing = "run_token_missing"
    case runTokenMismatch = "run_token_mismatch"
    case workerPIDMissing = "worker_pid_missing"
    case workerProcessLost = "worker_process_lost"
    case workerPIDMismatch = "worker_pid_mismatch"
    case providerPIDMissing = "provider_pid_missing"
    case providerProcessLost = "provider_process_lost"
    case providerPIDNotDescendant = "provider_pid_not_descendant"
    case runtimeProcessWithoutTmux = "runtime_process_without_tmux"
    case recoverableCheckpoint = "recoverable_checkpoint"
    case noRecoveryCheckpoint = "no_recovery_checkpoint"
}

public enum SessionReconcileAction: String, Codable, Sendable {
    case none
    case markRecoverable = "mark_recoverable"
    case markOrphaned = "mark_orphaned"
    case removeDeadTmux = "remove_dead_tmux"
    case removeDeadTmuxAndMarkRecoverable = "remove_dead_tmux_and_mark_recoverable"
    case removeDeadTmuxAndMarkOrphaned = "remove_dead_tmux_and_mark_orphaned"
}

public struct SessionHealthEvidence: Equatable, Sendable {
    public var metadataValid: Bool
    public var runtimeIdentityExpected: Bool
    public var metaStatus: EffectiveStatus
    public var tmuxState: TmuxHealthState
    public var runTokenState: RunTokenHealthState
    public var workerState: ProcessHealthState
    public var providerState: ProcessHealthState
    public var heartbeatFreshness: FreshnessState
    public var checkpointFreshness: FreshnessState
    public var checkpointRecoverable: Bool
    public var agentSessionKnown: Bool
    public var stopRequested: Bool

    public init(
        metadataValid: Bool,
        runtimeIdentityExpected: Bool,
        metaStatus: EffectiveStatus,
        tmuxState: TmuxHealthState,
        runTokenState: RunTokenHealthState,
        workerState: ProcessHealthState,
        providerState: ProcessHealthState,
        heartbeatFreshness: FreshnessState,
        checkpointFreshness: FreshnessState,
        checkpointRecoverable: Bool,
        agentSessionKnown: Bool,
        stopRequested: Bool = false
    ) {
        self.metadataValid = metadataValid
        self.runtimeIdentityExpected = runtimeIdentityExpected
        self.metaStatus = metaStatus
        self.tmuxState = tmuxState
        self.runTokenState = runTokenState
        self.workerState = workerState
        self.providerState = providerState
        self.heartbeatFreshness = heartbeatFreshness
        self.checkpointFreshness = checkpointFreshness
        self.checkpointRecoverable = checkpointRecoverable
        self.agentSessionKnown = agentSessionKnown
        self.stopRequested = stopRequested
    }
}

public struct SessionHealthAssessment: Codable, Equatable, Sendable {
    public var schema: Int
    public var effectiveStatus: EffectiveStatus
    public var reason: SessionHealthReason
    public var actions: [SessionAction]
    public var reconcileAction: SessionReconcileAction
    public var ownershipProven: Bool
    public var cleanupEligible: Bool
    public var heartbeatFresh: Bool
    public var checkpointFresh: Bool

    enum CodingKeys: String, CodingKey {
        case schema, reason, actions
        case effectiveStatus = "effective_status"
        case reconcileAction = "reconcile_action"
        case ownershipProven = "ownership_proven"
        case cleanupEligible = "cleanup_eligible"
        case heartbeatFresh = "heartbeat_fresh"
        case checkpointFresh = "checkpoint_fresh"
    }
}

public enum SessionHealthEvaluator {
    public static func evaluate(_ evidence: SessionHealthEvidence) -> SessionHealthAssessment {
        if evidence.tmuxState == .foreign {
            return assessment(
                status: .collision,
                reason: .foreignTmux,
                actions: [],
                evidence: evidence)
        }

        if !evidence.metadataValid {
            let actions: [SessionAction] = evidence.tmuxState == .live
                ? [.attach, .stop] : [.delete]
            return assessment(
                status: .corrupt,
                reason: .malformedMetadata,
                actions: actions,
                ownershipProven: evidence.tmuxState == .live || evidence.tmuxState == .dead,
                evidence: evidence)
        }

        switch evidence.tmuxState {
        case .missing:
            guard isActive(evidence.metaStatus) else {
                return finishedAssessment(evidence, reason: .finished)
            }
            if runtimeProcessMayStillBeAlive(evidence) {
                return assessment(
                    status: .hung,
                    reason: .runtimeProcessWithoutTmux,
                    actions: [],
                    evidence: evidence)
            }
            return interruptedAssessment(evidence, deadTmux: false)

        case .dead:
            guard isActive(evidence.metaStatus) else {
                var result = finishedAssessment(evidence, reason: .paneExited)
                result.reconcileAction = .removeDeadTmux
                return result
            }
            if runtimeProcessMayStillBeAlive(evidence) {
                return assessment(
                    status: .hung,
                    reason: .runtimeProcessWithoutTmux,
                    actions: [],
                    evidence: evidence)
            }
            return interruptedAssessment(evidence, deadTmux: true)

        case .live:
            break

        case .foreign:
            preconditionFailure("foreign tmux is handled above")
        }

        switch evidence.runTokenState {
        case .missing:
            return assessment(
                status: .corrupt,
                reason: .runTokenMissing,
                actions: [.attach, .stop],
                ownershipProven: true,
                evidence: evidence)
        case .mismatch:
            return assessment(
                status: .corrupt,
                reason: .runTokenMismatch,
                actions: [.attach, .stop],
                ownershipProven: true,
                evidence: evidence)
        case .match:
            break
        }

        // Stop records exact-run intent before signalling the process group.
        // The provider can exit while its worker is still checkpointing and
        // writing the final `stopped` metadata. That proven transition is an
        // interruption in progress, not a lost provider. Keep actions closed
        // until the worker and tmux pane have finished.
        if evidence.stopRequested,
           evidence.runtimeIdentityExpected,
           isActive(evidence.metaStatus),
           evidence.workerState == .alive,
           evidence.providerState == .dead {
            return assessment(
                status: .interrupted,
                reason: .finished,
                actions: [],
                ownershipProven: true,
                evidence: evidence)
        }

        // The worker publishes its final status and only then exits, so a
        // terminal metadata record with a live owned pane and a gone provider
        // is a run that is finishing, not a hung one. The pane dies moments
        // later. Reporting `hung` here would move a finished session into
        // Problems until an unrelated event repaired it.
        if evidence.runtimeIdentityExpected,
           !isActive(evidence.metaStatus),
           evidence.workerState == .alive,
           evidence.providerState == .dead {
            var result = finishedAssessment(evidence, reason: .finished)
            result.ownershipProven = true
            // The pane is still alive for a moment. Typed cleanup waits for
            // the next snapshot, which sees the dead pane.
            result.cleanupEligible = false
            return result
        }

        if !evidence.runtimeIdentityExpected {
            let reason: SessionHealthReason = evidence.checkpointFreshness == .stale
                ? .checkpointStale : .heartbeatMissing
            return assessment(
                status: isActive(evidence.metaStatus) ? evidence.metaStatus : .running,
                reason: reason,
                actions: [.attach, .stop],
                ownershipProven: true,
                evidence: evidence)
        }

        switch evidence.workerState {
        case .unknown:
            return hungAssessment(reason: .workerPIDMissing, evidence: evidence)
        case .dead:
            return hungAssessment(reason: .workerProcessLost, evidence: evidence)
        case .mismatch:
            return hungAssessment(reason: .workerPIDMismatch, evidence: evidence)
        case .alive:
            break
        }

        switch evidence.providerState {
        case .unknown:
            return hungAssessment(reason: .providerPIDMissing, evidence: evidence)
        case .dead:
            return hungAssessment(reason: .providerProcessLost, evidence: evidence)
        case .mismatch:
            return hungAssessment(reason: .providerPIDNotDescendant, evidence: evidence)
        case .alive:
            break
        }

        let reason: SessionHealthReason
        switch evidence.heartbeatFreshness {
        case .stale:
            // A live, owned provider may spend an arbitrarily long time in one
            // turn. A stale observer is diagnostic degradation, not proof that
            // the provider itself is hung.
            reason = .heartbeatStale
        case .missing:
            reason = .heartbeatMissing
        case .fresh where evidence.checkpointFreshness == .stale:
            reason = .checkpointStale
        case .fresh:
            reason = .healthy
        }
        return assessment(
            status: isActive(evidence.metaStatus) ? evidence.metaStatus : .running,
            reason: reason,
            actions: [.attach, .stop],
            ownershipProven: true,
            evidence: evidence)
    }

    private static func interruptedAssessment(
        _ evidence: SessionHealthEvidence,
        deadTmux: Bool
    ) -> SessionHealthAssessment {
        let status: EffectiveStatus = evidence.checkpointRecoverable ? .recoverable : .orphaned
        let action: SessionReconcileAction
        if deadTmux {
            action = evidence.checkpointRecoverable
                ? .removeDeadTmuxAndMarkRecoverable
                : .removeDeadTmuxAndMarkOrphaned
        } else {
            action = evidence.checkpointRecoverable ? .markRecoverable : .markOrphaned
        }
        var result = assessment(
            status: status,
            reason: evidence.checkpointRecoverable ? .recoverableCheckpoint : .noRecoveryCheckpoint,
            actions: evidence.checkpointRecoverable ? [.recover, .delete] : [.delete],
            evidence: evidence)
        result.reconcileAction = action
        result.cleanupEligible = status == .orphaned
        return result
    }

    private static func finishedAssessment(
        _ evidence: SessionHealthEvidence,
        reason: SessionHealthReason
    ) -> SessionHealthAssessment {
        let status = isActive(evidence.metaStatus) ? .interrupted : evidence.metaStatus
        let actions: [SessionAction]
        if status == .recoverable {
            actions = [.recover, .delete]
        } else if evidence.agentSessionKnown {
            actions = [.resume, .delete]
        } else {
            actions = [.delete]
        }
        var result = assessment(
            status: status,
            reason: reason,
            actions: actions,
            evidence: evidence)
        result.cleanupEligible = status == .stopped || status == .orphaned
        return result
    }

    private static func hungAssessment(
        reason: SessionHealthReason,
        evidence: SessionHealthEvidence
    ) -> SessionHealthAssessment {
        assessment(
            status: .hung,
            reason: reason,
            actions: [.attach, .stop],
            ownershipProven: true,
            evidence: evidence)
    }

    private static func assessment(
        status: EffectiveStatus,
        reason: SessionHealthReason,
        actions: [SessionAction],
        ownershipProven: Bool = false,
        evidence: SessionHealthEvidence
    ) -> SessionHealthAssessment {
        SessionHealthAssessment(
            schema: 1,
            effectiveStatus: status,
            reason: reason,
            actions: actions,
            reconcileAction: .none,
            ownershipProven: ownershipProven,
            cleanupEligible: status == .stopped || status == .orphaned,
            heartbeatFresh: evidence.heartbeatFreshness == .fresh,
            checkpointFresh: evidence.checkpointFreshness == .fresh)
    }

    private static func isActive(_ status: EffectiveStatus) -> Bool {
        status == .starting || status == .running || status == .recovering || status == .hung
    }

    private static func runtimeProcessMayStillBeAlive(_ evidence: SessionHealthEvidence) -> Bool {
        evidence.runtimeIdentityExpected && (
            evidence.workerState == .alive
                || evidence.providerState == .alive
                || evidence.providerState == .mismatch)
    }
}
