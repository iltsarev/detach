import Foundation

public enum SessionSection: String, CaseIterable, Sendable {
    case active = "Работают"
    case finished = "Завершены"
    case problems = "Проблемные"
}

public enum SessionAction: String, CaseIterable, Sendable {
    case attach, stop, resume, recover, delete
}

public extension Session {
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

    /// "91k · 74% свободно" when the window is known, "361k токенов" otherwise.
    var contextSummary: String? {
        guard let used = contextUsedTokens else { return nil }
        let usedText = "\(Int((Double(used) / 1000).rounded()))k"
        if let fraction = contextFraction {
            return "\(usedText) · \(Int(((1 - fraction) * 100).rounded()))% свободно"
        }
        return "\(usedText) токенов"
    }
}
