import Foundation

public func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum TerminalCommand {
    public static func attach(detachPath: String, session: Session) -> String {
        "exec \(shellQuoted(detachPath)) \(session.provider.rawValue) attach \(shellQuoted(session.sessionName))"
    }

    public static func resume(detachPath: String, session: Session) -> String? {
        guard let uuid = session.agentSessionId else { return nil }
        return "exec \(shellQuoted(detachPath)) resume \(shellQuoted(uuid))"
    }

    public static func recover(detachPath: String, session: Session) -> String {
        "exec \(shellQuoted(detachPath)) \(session.provider.rawValue) recover \(shellQuoted(session.sessionName))"
    }

    public static func start(detachPath: String, provider: Provider, projectDir: String,
                             name: String?, prompt: String?) -> String {
        var command = "cd \(shellQuoted(projectDir)) && exec \(shellQuoted(detachPath)) \(provider.rawValue)"
        if let name, !name.isEmpty {
            command += " --name \(shellQuoted(name))"
        }
        if let prompt, !prompt.isEmpty {
            command += " -- \(shellQuoted(prompt))"
        }
        return command
    }
}
