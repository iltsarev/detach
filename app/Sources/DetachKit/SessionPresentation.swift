import Foundation

public enum SessionSection: String, CaseIterable, Sendable {
    case answerReady
    case active
    case finished
    case problems

    public var displayName: String {
        switch self {
        case .answerReady: L10n.string("Answer ready")
        case .active: L10n.string("Working")
        case .finished: L10n.string("Finished")
        case .problems: L10n.string("Problems")
        }
    }
}

public enum SessionAction: String, Codable, CaseIterable, Sendable {
    case attach, stop, resume, recover, delete
}

public extension Session {
    var isWaitingForUser: Bool {
        effectiveStatus == .running && agentTurnState == .waiting
    }

    /// Whether the provider process is still expected to produce live output.
    /// This intentionally stays independent from the sidebar section: a live
    /// session can move between Working and Answer ready without stopping log
    /// polling.
    var isLive: Bool {
        switch effectiveStatus {
        case .starting, .running, .recovering, .hung: true
        case .completed, .failed, .interrupted, .stopped, .recoverable,
             .orphaned, .corrupt, .collision, .unknown: false
        }
    }

    var displayStatus: String {
        if isWaitingForUser { return L10n.string("answer ready") }
        return switch effectiveStatus {
        case .starting: L10n.string("starting")
        case .running: L10n.string("running")
        case .recovering: L10n.string("recovering")
        case .hung: L10n.string("hung")
        case .completed: L10n.string("completed")
        case .failed: L10n.string("failed")
        case .interrupted: L10n.string("interrupted")
        case .stopped: L10n.string("stopped")
        case .recoverable: L10n.string("recoverable")
        case .orphaned: L10n.string("orphaned")
        case .corrupt: L10n.string("corrupt")
        case .collision: L10n.string("name collision")
        case .unknown: L10n.string("unknown")
        }
    }

    var section: SessionSection {
        if isWaitingForUser { return .answerReady }
        return switch effectiveStatus {
        case .running, .starting, .recovering: .active
        case .hung: .problems
        case .completed, .failed, .interrupted, .stopped: .finished
        case .recoverable, .orphaned, .corrupt, .collision, .unknown: .problems
        }
    }

    var availableActions: [SessionAction] {
        if let healthActions { return healthActions }
        return switch effectiveStatus {
        case .running, .starting, .recovering, .hung:
            [.attach, .stop]
        case .completed, .failed, .interrupted, .stopped, .orphaned:
            agentSessionId != nil ? [.resume, .delete] : [.delete]
        case .recoverable:
            [.recover, .delete]
        case .corrupt, .unknown:
            [.delete]
        case .collision:
            []
        }
    }

    var displayTitle: String {
        if let projectDir, let base = projectDir.split(separator: "/").last {
            return String(base)
        }
        return name
    }

    var healthReasonLabel: String? {
        guard let healthReason else { return nil }
        return switch healthReason {
        case .healthy, .finished:
            nil
        case .checkpointStale:
            L10n.string("The provider is alive; the last checkpoint is old.")
        case .heartbeatStale:
            L10n.string("The provider is alive, but its health heartbeat is stale.")
        case .heartbeatMissing:
            L10n.string("The provider is alive, but no health heartbeat is available yet.")
        case .tmuxServerMissing:
            L10n.string("The managed tmux session disappeared.")
        case .paneExited:
            L10n.string("The managed pane exited and was retained for inspection.")
        case .foreignTmux:
            L10n.string("Another tmux session uses this name; Detach will not touch it.")
        case .malformedMetadata:
            L10n.string("Session metadata is missing or malformed.")
        case .runTokenMissing:
            L10n.string("The live session has no complete run-token proof.")
        case .runTokenMismatch:
            L10n.string("The live session and saved metadata have different run tokens.")
        case .workerPIDMissing:
            L10n.string("The managed worker PID is missing.")
        case .workerProcessLost:
            L10n.string("The managed worker process is no longer running.")
        case .workerPIDMismatch:
            L10n.string("The tmux pane no longer matches the managed worker PID.")
        case .providerPIDMissing:
            L10n.string("The provider PID is missing.")
        case .providerProcessLost:
            L10n.string("The provider process exited while its worker remained alive.")
        case .providerPIDNotDescendant:
            L10n.string("The recorded provider PID is not owned by this worker.")
        case .runtimeProcessWithoutTmux:
            L10n.string("A recorded runtime process is still alive without its managed tmux session; Detach will not signal it.")
        case .recoverableCheckpoint:
            L10n.string("The live runtime disappeared, but a valid checkpoint can be recovered.")
        case .noRecoveryCheckpoint:
            L10n.string("The live runtime disappeared without a valid recovery checkpoint.")
        }
    }

    /// 0...1 share of the context window in use, when the window size is known.
    var contextFraction: Double? {
        guard let used = contextUsedTokens, let window = contextWindow, window > 0 else { return nil }
        return min(1.0, Double(used) / Double(window))
    }

    /// Localized token usage summary for the model context window.
    var contextSummary: String? {
        guard let used = contextUsedTokens else { return nil }
        let usedText = "\(Int((Double(used) / 1000).rounded()))k"
        if let fraction = contextFraction {
            return L10n.format(
                "%@ · %@%% available",
                usedText,
                String(Int(((1 - fraction) * 100).rounded())))
        }
        return L10n.format("%@ tokens", usedText)
    }

    /// Human-readable sleep policy. Text is the primary signal because a
    /// moon/shield glyph alone is easy to interpret in opposite ways.
    var powerProtectionLabel: String {
        switch powerProtectionState ?? .unknown {
        case .protected: L10n.string("Mac stays awake")
        case .allowed: L10n.string("Mac can sleep")
        case .transitioning: L10n.string("Enabling sleep protection")
        case .lowBattery: L10n.string("Mac can sleep: low battery")
        case .unavailable: L10n.string("Sleep protection unavailable")
        case .unknown: L10n.string("Sleep status unknown")
        }
    }

    /// Temporary SF Symbols; the adjacent label carries the meaning.
    var powerProtectionSystemImage: String {
        switch powerProtectionState ?? .unknown {
        case .protected: "shield.fill"
        case .allowed: "moon.zzz"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .lowBattery: "battery.25"
        case .unavailable: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }
}
