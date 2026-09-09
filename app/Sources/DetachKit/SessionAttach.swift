import Foundation

/// Initial detached window grid. Attached clients supply later dimensions.
public struct SessionTerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init?(columns: Int, rows: Int) {
        guard (1...999).contains(columns), (1...999).contains(rows) else { return nil }
        self.columns = columns
        self.rows = rows
    }

    public var arguments: [String] { ["--terminal-size", "\(columns)x\(rows)"] }
}

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

    public static func shouldEmbed(
        _ session: Session,
        clientActive: Bool,
        replacing previous: Session? = nil
    ) -> Bool {
        guard clientActive, isEligible(session) else { return false }
        guard let previous else { return true }
        guard session.id == previous.id else { return false }
        if let oldRun = previous.lifecycleID, let newRun = session.lifecycleID {
            return oldRun != newRun
        }
        // Older records have no lifecycle ID. A later creation timestamp can
        // prove replacement; missing identity waits for command completion.
        guard let oldDate = previous.createdAt, let newDate = session.createdAt else {
            return false
        }
        return newDate > oldDate
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
        // The attach client must see the same runtime roots as every other
        // child, so inherited `DETACH_*` overrides are removed here as well.
        var env = ProcessDetachCLI.runtimeEnvironment(
            base, allowsDetachOverrides: false)
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        env["TERM"] = termName
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true {
            env["LANG"] = "en_US.UTF-8"
        }
        // SwiftTerm always consumes UTF-8. A GUI launch can inherit LC_ALL=C,
        // which takes precedence over LANG and makes tmux render for a
        // non-UTF-8 client. Limit this correction to the attach client.
        let characterLocale = ["LC_ALL", "LC_CTYPE", "LANG"]
            .compactMap { env[$0] }.first { !$0.isEmpty } ?? ""
        let normalizedLocale = characterLocale.uppercased()
            .replacingOccurrences(of: "-", with: "")
        if !normalizedLocale.contains("UTF8") {
            env["LC_ALL"] = "en_US.UTF-8"
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
