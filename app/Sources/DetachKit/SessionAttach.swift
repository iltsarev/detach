import Foundation

/// Public attach invocation for an in-app PTY client.
///
/// The client must run `detach <provider> attach <session>` as argv. It must
/// not call tmux and must not use a shell string. Closing the client is not
/// `detach stop`.
public struct SessionAttachInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]

    public static let termName = "xterm-256color"

    public init(
        detachPath: String,
        session: Session,
        baseEnvironment: [String: String]
    ) {
        self.executable = detachPath
        self.arguments = Self.arguments(for: session)
        self.environment = Self.environment(from: baseEnvironment)
    }

    public static func isEligible(_ session: Session) -> Bool {
        session.isLive && session.availableActions.contains(.attach)
    }

    public static func shouldEmbed(_ session: Session, clientActive: Bool) -> Bool {
        clientActive && isEligible(session)
    }

    public static func arguments(for session: Session) -> [String] {
        [
            session.provider.rawValue,
            "attach",
            "--terminal-features",
            "sync",
            session.sessionName,
        ]
    }

    public static func environment(
        from base: [String: String],
        termName: String = termName
    ) -> [String] {
        var env = ProcessDetachCLI.runtimeEnvironment(base)
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        env["TERM"] = termName
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "en_US.UTF-8"
        }
        return env.keys.sorted().map { key in
            "\(key)=\(env[key] ?? "")"
        }
    }
}

/// Public, ownership-checked request to retarget the one visible tmux client.
public enum SessionClientSwitchInvocation {
    public static func arguments(
        clientPID: Int32,
        from source: Session,
        to target: Session
    ) -> [String] {
        [
            "client", "switch",
            "--pid", String(clientPID),
            "--from", source.sessionName,
            "--to", target.sessionName,
            "--provider", target.provider.rawValue,
        ]
    }
}
