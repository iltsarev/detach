import Foundation
import Observation

public struct SessionDeletionFailure: Equatable, Sendable {
    public var sessionName: String
    public var displayTitle: String
    public var message: String

    public init(sessionName: String, displayTitle: String, message: String) {
        self.sessionName = sessionName
        self.displayTitle = displayTitle
        self.message = message
    }
}

public struct SessionStartResult: Equatable, Sendable {
    public var sessionID: String?
    public var message: String?

    public init(sessionID: String? = nil, message: String? = nil) {
        self.sessionID = sessionID
        self.message = message
    }
}

@Observable @MainActor
public final class SessionStore {
    private struct SessionWaiter {
        let provider: Provider
        let projectPath: String
        let excludedIDs: Set<String>
        let continuation: CheckedContinuation<String?, Never>
    }

    private enum Mutation {
        case stop
        case delete
    }

    public enum State: Equatable, Sendable {
        case ok
        case cliMissing
        case incompatible
        case error(String)
    }

    public private(set) var sessions: [Session] = []
    public private(set) var lastUpdated: Date?
    public private(set) var state: State = .ok

    /// Called after every successful typed snapshot — including an unchanged list — so
    /// a transition detector can advance its baseline. The store is the single
    /// app-level session source; notifications and the menu bar consume these
    /// snapshots instead of running their own subprocess loops.
    @ObservationIgnored public var onSnapshot: (@MainActor ([Session]) async -> Void)?

    private var cli: DetachCLIRunning
    private var eventTask: Task<Void, Never>?
    private var interruptedConfirmationTask: Task<Void, Never>?
    private var confirmedInterruptedSessionIDs: Set<String> = []
    private var eventGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var sessionWaiters: [UUID: SessionWaiter] = [:]
    @ObservationIgnored private let confirmationSleep:
        @Sendable (UInt64) async throws -> Void

    public init(cli: DetachCLIRunning) {
        self.cli = cli
        self.confirmationSleep = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        cli: DetachCLIRunning,
        confirmationSleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.cli = cli
        self.confirmationSleep = confirmationSleep
    }

    /// Swaps the CLI (for example after the installed payload activates) and
    /// establishes a fresh typed snapshot before replacing the event stream.
    public func configure(cli: DetachCLIRunning) async {
        stopObserving()
        self.cli = cli
        await refresh()
        startObserving()
    }

    /// Starts one bounded stream of native change hints. The initial `ready`
    /// event closes the refresh/watch race by requesting another full list
    /// only after FSEvents is installed.
    public func startObserving() {
        guard eventTask == nil else { return }
        eventGeneration &+= 1
        let generation = eventGeneration
        let cli = self.cli
        eventTask = Task { [weak self] in
            defer {
                if let self, generation == self.eventGeneration {
                    self.eventTask = nil
                }
            }
            do {
                for try await _ in cli.sessionEvents() {
                    guard !Task.isCancelled,
                          let self,
                          generation == self.eventGeneration else { return }
                    await self.refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                // A full refresh on app activation restarts a failed stream.
                // Keep the last typed snapshot instead of replacing it with
                // an event-transport diagnostic.
            }
        }
    }

    public func stopObserving() {
        eventGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
    }

    /// Repairs missed or failed event delivery without introducing a timer.
    /// App activation is a natural resynchronization boundary.
    public func resynchronize() async {
        await refresh()
        startObserving()
    }

    /// Returns this request's valid typed snapshot even when a newer refresh
    /// owns publication to the shared store.
    @discardableResult
    public func refresh() async -> [Session] {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let cli = self.cli
        do {
            let result = try await cli.run(arguments: ["list", "--json"], timeout: 5)
            guard result.exitCode == 0, !result.timedOut else {
                if generation == refreshGeneration {
                    state = .error(result.timedOut ? L10n.string("detach list timed out")
                                   : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return []
            }
            let parsed = SessionListParser.parse(result.stdout)
            if parsed.hadInvalidLines {
                if generation == refreshGeneration {
                    state = .incompatible // spec: never update the list from bad data
                }
                return []
            }
            let snapshot = parsed.sessions.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            // Event refreshes, explicit refreshes, and CLI reconfiguration may
            // overlap while their subprocesses are suspended. Only the latest
            // request may publish state or notify transition consumers.
            guard generation == refreshGeneration else { return snapshot }
            if sessions != snapshot { sessions = snapshot }
            resolveSessionWaiters(from: snapshot)
            lastUpdated = Date()
            state = .ok
            if let onSnapshot { await onSnapshot(sessions) }
            scheduleInterruptedConfirmation(for: snapshot)
            return snapshot
        } catch {
            if generation == refreshGeneration { state = .cliMissing }
            return []
        }
    }

    /// Suspends without polling until a valid typed snapshot contains one
    /// unambiguous new session for the requested provider and project.
    public func waitForSession(
        provider: Provider,
        projectDirectory: URL,
        excluding excludedIDs: Set<String>
    ) async -> String? {
        let projectPath = Self.canonicalProjectPath(projectDirectory.path)
        if let match = Self.matchingSessionID(
            in: sessions,
            provider: provider,
            projectPath: projectPath,
            excludedIDs: excludedIDs) {
            return match
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                sessionWaiters[waiterID] = SessionWaiter(
                    provider: provider,
                    projectPath: projectPath,
                    excludedIDs: excludedIDs,
                    continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSessionWaiter(waiterID)
            }
        }
    }

    private func resolveSessionWaiters(from snapshot: [Session]) {
        let resolved = sessionWaiters.compactMap { id, waiter -> (UUID, String)? in
            guard let sessionID = Self.matchingSessionID(
                in: snapshot,
                provider: waiter.provider,
                projectPath: waiter.projectPath,
                excludedIDs: waiter.excludedIDs) else { return nil }
            return (id, sessionID)
        }
        for (id, sessionID) in resolved {
            sessionWaiters.removeValue(forKey: id)?
                .continuation.resume(returning: sessionID)
        }
    }

    private func cancelSessionWaiter(_ id: UUID) {
        sessionWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    private static func matchingSessionID(
        in sessions: [Session],
        provider: Provider,
        projectPath: String,
        excludedIDs: Set<String>
    ) -> String? {
        let candidates = sessions.filter {
            !excludedIDs.contains($0.id)
                && $0.provider == provider
                && $0.projectDir.map(canonicalProjectPath) == projectPath
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private func scheduleInterruptedConfirmation(for snapshot: [Session]) {
        let interruptedIDs = Set(snapshot.lazy
            .filter { $0.effectiveStatus == .interrupted }
            .map(\.id))
        confirmedInterruptedSessionIDs.formIntersection(interruptedIDs)
        guard !interruptedIDs.isEmpty else {
            interruptedConfirmationTask?.cancel()
            interruptedConfirmationTask = nil
            return
        }
        let unconfirmedIDs = interruptedIDs.subtracting(
            confirmedInterruptedSessionIDs)
        guard !unconfirmedIDs.isEmpty else { return }

        interruptedConfirmationTask?.cancel()
        interruptedConfirmationTask = Task { [weak self] in
            do {
                try await self?.confirmationSleep(350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.confirmedInterruptedSessionIDs.formUnion(unconfirmedIDs)
            self.interruptedConfirmationTask = nil
            await self.refresh()
        }
    }

    /// Runs a non-interactive action (stop/delete). Returns an error message or nil.
    public func perform(_ action: SessionAction, on session: Session) async -> String? {
        guard action == .stop || action == .delete else {
            return L10n.format(
                "Internal error: %@ must run in Terminal",
                action.rawValue)
        }
        let mutation: Mutation = action == .stop ? .stop : .delete
        let result = await run(mutation, on: session)
        if result.launched { await refresh() }
        return result.message
    }

    /// Starts a fresh managed run without an outer terminal. A successful
    /// start refreshes typed state and returns the one unambiguous new session
    /// for the selected provider and project.
    public func startDetached(
        provider: Provider,
        projectDirectory: URL,
        name: String?,
        prompt: String?
    ) async -> SessionStartResult {
        let existingIDs = Set(sessions.map(\.id))
        var arguments = [provider.rawValue]
        if let name, !name.isEmpty {
            arguments += ["--name", name]
        }
        arguments.append("--detach")
        if let prompt, !prompt.isEmpty {
            arguments += ["--", prompt]
        }

        do {
            let result = try await cli.run(
                arguments: arguments,
                timeout: 120,
                currentDirectoryURL: projectDirectory)
            guard !result.timedOut else {
                await refresh()
                return SessionStartResult(
                    message: L10n.string("detach start timed out"))
            }
            guard result.exitCode == 0 else {
                let stderr = result.stderr.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                return SessionStartResult(message: stderr.isEmpty
                    ? L10n.format("detach exited with status %d", result.exitCode)
                    : stderr)
            }

            let refreshedSessions = await refresh()
            let projectPath = Self.canonicalProjectPath(projectDirectory.path)
            let candidates = refreshedSessions.filter {
                !existingIDs.contains($0.id)
                    && $0.provider == provider
                    && $0.projectDir.map(Self.canonicalProjectPath) == projectPath
            }
            return SessionStartResult(
                sessionID: candidates.count == 1 ? candidates[0].id : nil)
        } catch {
            return SessionStartResult(message: L10n.format(
                "Could not run detach: %@",
                error.localizedDescription))
        }
    }

    /// Starts Resume or Recover without an outer terminal. The provider starts
    /// detached; the app creates a separate attach-only PTY after this returns.
    public func prepareInteractive(
        _ action: SessionAction,
        on session: Session
    ) async -> String? {
        let arguments: [String]
        let timeoutMessage: String
        switch action {
        case .resume:
            guard let sessionID = session.agentSessionId, !sessionID.isEmpty else {
                return L10n.string("The session has no provider UUID to resume.")
            }
            arguments = ["resume", "--detach", sessionID]
            timeoutMessage = L10n.string("detach resume timed out")
        case .recover:
            arguments = [
                session.provider.rawValue,
                "recover",
                "--detach",
                session.sessionName,
            ]
            timeoutMessage = L10n.string("detach recover timed out")
        case .attach, .stop, .delete:
            return L10n.format(
                "Internal error: %@ is not an in-app start action",
                action.rawValue)
        }

        do {
            let result = try await cli.run(arguments: arguments, timeout: 120)
            await refresh()
            if result.timedOut {
                return timeoutMessage
            }
            guard result.exitCode == 0 else {
                let stderr = result.stderr.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                return stderr.isEmpty
                    ? L10n.format("detach exited with status %d", result.exitCode)
                    : stderr
            }
            return nil
        } catch {
            return L10n.format(
                "Could not run detach: %@",
                error.localizedDescription)
        }
    }

    private static func canonicalProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    /// Deletes every selected finished session and reports failures without
    /// stopping the remaining operations. One final refresh publishes the
    /// resulting list instead of polling between individual removals.
    public func deleteFinished(
        _ selectedSessions: [Session]
    ) async -> [SessionDeletionFailure] {
        var failures: [SessionDeletionFailure] = []
        var seen: Set<String> = []
        for session in selectedSessions where seen.insert(session.id).inserted {
            guard let current = sessions.first(where: { $0.id == session.id }),
                  current.canDeleteFromFinishedList else {
                failures.append(SessionDeletionFailure(
                    sessionName: session.sessionName,
                    displayTitle: session.displayTitle,
                    message: L10n.string(
                        "Session is not eligible for deletion from Finished.")))
                continue
            }
            if let message = await run(.delete, on: current).message {
                failures.append(SessionDeletionFailure(
                    sessionName: current.sessionName,
                    displayTitle: current.displayTitle,
                    message: message))
            }
        }
        await refresh()
        return failures
    }

    private func run(
        _ mutation: Mutation,
        on session: Session
    ) async -> (message: String?, launched: Bool) {
        let arguments: [String]
        switch mutation {
        case .stop:
            arguments = [session.provider.rawValue, "stop", session.sessionName]
        case .delete:
            arguments = [session.provider.rawValue, "delete", "--force", session.sessionName]
        }
        do {
            let result = try await cli.run(arguments: arguments, timeout: 30)
            if result.exitCode == 0 { return (nil, true) }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stderr.isEmpty
                ? L10n.format("detach exited with status %d", result.exitCode)
                : stderr, true)
        } catch {
            return (L10n.format(
                "Could not run detach: %@",
                error.localizedDescription), false)
        }
    }
}
