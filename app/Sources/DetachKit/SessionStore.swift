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

    /// Called after every successful poll — including an unchanged list — so
    /// a transition detector can advance its baseline. The store is the single
    /// app-level `list --json` poller; notifications and the menu bar consume
    /// these snapshots instead of running their own subprocess loops.
    @ObservationIgnored public var onSnapshot: (@MainActor ([Session]) async -> Void)?

    private var cli: DetachCLIRunning
    private var pollTask: Task<Void, Never>?
    private var baseInterval: TimeInterval = 2
    private var foreground = true

    public init(cli: DetachCLIRunning) {
        self.cli = cli
    }

    /// Swaps the CLI (for example after the installed payload activates) and
    /// refreshes immediately. The polling cadence is unchanged.
    public func configure(cli: DetachCLIRunning) async {
        self.cli = cli
        await refresh()
    }

    public func startPolling(interval: TimeInterval) {
        baseInterval = max(interval, 0.5)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let delay = self?.currentInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Foreground (a visible window or open menu wants fresh data) polls at
    /// the base interval. Idle polling slows down but never stops, so
    /// notifications and the menu bar stay truthful after the last window
    /// closes.
    public func updateCadence(foreground: Bool) {
        self.foreground = foreground
    }

    private var currentInterval: TimeInterval {
        foreground ? baseInterval : max(baseInterval * 5, 10)
    }

    public func refresh() async {
        do {
            let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
            guard result.exitCode == 0, !result.timedOut else {
                state = .error(result.timedOut ? L10n.string("detach list timed out")
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
            if let onSnapshot { await onSnapshot(sessions) }
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
            return L10n.format(
                "Internal error: %@ must run in Terminal",
                action.rawValue)
        }
        do {
            let result = try await cli.run(arguments: arguments, timeout: 30)
            await refresh()
            if result.exitCode == 0 { return nil }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return stderr.isEmpty
                ? L10n.format("detach exited with status %d", result.exitCode)
                : stderr
        } catch {
            return L10n.format("Could not run detach: %@", error.localizedDescription)
        }
    }
}
