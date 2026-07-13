import Foundation

public enum TmuxStyle: String, Equatable, Sendable, CaseIterable {
    /// Apply Detach's stable per-session identity color and status line.
    case detach
    /// Leave all tmux presentation to the user's own configuration.
    case inherit
}

public enum TmuxStyleClientError: LocalizedError, Equatable {
    case timedOut
    case commandFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            L10n.string("detach config timed out")
        case .commandFailed(let message):
            message
        case .invalidResponse(let value):
            L10n.format(
                "detach returned an unsupported tmux style: %@",
                value.isEmpty ? L10n.string("<empty>") : value)
        }
    }
}

/// Typed access to the CLI-backed tmux presentation setting.
public struct TmuxStyleClient: Sendable {
    private let cli: any DetachCLIRunning

    public init(cli: any DetachCLIRunning) {
        self.cli = cli
    }

    public func loadStyle() async throws -> TmuxStyle {
        let result = try await cli.run(arguments: ["config", "tmux-style"], timeout: 5)
        try validate(result)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let style = TmuxStyle(rawValue: value) else {
            throw TmuxStyleClientError.invalidResponse(value)
        }
        return style
    }

    public func setStyle(_ style: TmuxStyle) async throws {
        let result = try await cli.run(
            arguments: ["config", "tmux-style", style.rawValue],
            timeout: 5)
        try validate(result)
    }

    private func validate(_ result: CLIResult) throws {
        if result.timedOut {
            throw TmuxStyleClientError.timedOut
        }
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TmuxStyleClientError.commandFailed(
                stderr.isEmpty
                    ? L10n.format("detach config exited with status %d", result.exitCode)
                    : stderr)
        }
    }
}
