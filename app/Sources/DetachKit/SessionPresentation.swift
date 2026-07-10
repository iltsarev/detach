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
}
