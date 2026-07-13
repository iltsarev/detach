import Foundation

public enum SessionSection: String, CaseIterable, Sendable {
    case active
    case finished
    case problems

    public var displayName: String {
        switch self {
        case .active: L10n.string("Working")
        case .finished: L10n.string("Finished")
        case .problems: L10n.string("Problems")
        }
    }
}

public enum SessionAction: String, CaseIterable, Sendable {
    case attach, stop, resume, recover, delete
}

public extension Session {
    var isWaitingForUser: Bool {
        effectiveStatus == .running && agentTurnState == .waiting
    }

    var displayStatus: String {
        if isWaitingForUser { return L10n.string("answer ready") }
        return switch effectiveStatus {
        case .starting: L10n.string("starting")
        case .running: L10n.string("running")
        case .recovering: L10n.string("recovering")
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
        switch effectiveStatus {
        case .running, .starting, .recovering: .active
        case .completed, .failed, .interrupted, .stopped: .finished
        case .recoverable, .orphaned, .corrupt, .collision, .unknown: .problems
        }
    }

    var availableActions: [SessionAction] {
        switch effectiveStatus {
        case .running, .starting, .recovering:
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
}
