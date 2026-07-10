import Foundation
import Observation

@Observable @MainActor
public final class SessionStore {
    public enum State: Equatable, Sendable {
        case ok
        case cliMissing
        case incompatible
        case error(String)
    }

    public private(set) var sessions: [Session] = []
    public private(set) var lastUpdated: Date?
    public private(set) var state: State = .ok

    private let cli: DetachCLIRunning
    private var pollTask: Task<Void, Never>?

    public init(cli: DetachCLIRunning) {
        self.cli = cli
    }

    public func startPolling(interval: TimeInterval) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        do {
            let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
            guard result.exitCode == 0, !result.timedOut else {
                state = .error(result.timedOut ? "detach list timed out"
                               : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            let parsed = SessionListParser.parse(result.stdout)
            if parsed.hadInvalidLines {
                state = .incompatible // spec: never update the list from bad data
                return
            }
            sessions = parsed.sessions.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            lastUpdated = Date()
            state = .ok
        } catch {
            state = .cliMissing
        }
    }

    /// Runs a non-interactive action (stop/delete). Returns an error message or nil.
    public func perform(_ action: SessionAction, on session: Session) async -> String? {
        let arguments: [String]
        switch action {
        case .stop:
            arguments = [session.provider.rawValue, "stop", session.sessionName]
        case .delete:
            arguments = [session.provider.rawValue, "delete", "--force", session.sessionName]
        case .attach, .resume, .recover:
            return "internal error: \(action.rawValue) must run in Terminal"
        }
        do {
            let result = try await cli.run(arguments: arguments, timeout: 30)
            await refresh()
            if result.exitCode == 0 { return nil }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return stderr.isEmpty ? "detach exited with status \(result.exitCode)" : stderr
        } catch {
            return "could not run detach: \(error.localizedDescription)"
        }
    }
}
