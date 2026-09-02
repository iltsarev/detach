import Foundation
import Observation
import os

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
    public private(set) var hasFreshSnapshot = false
    public private(set) var state: State = .ok

    /// Called after every successful typed snapshot — including an unchanged list — so
    /// a transition detector can advance its baseline. The store is the single
    /// app-level session source; notifications and the menu bar consume these
    /// snapshots instead of running their own subprocess loops.
    @ObservationIgnored public var onSnapshot: (@MainActor ([Session]) async -> Void)?

    private var cli: DetachCLIRunning
    @ObservationIgnored private let snapshotCache: (any SessionSnapshotCaching)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var eventReadyGeneration: UInt64?
    @ObservationIgnored private var eventReadyWaiters:
        [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var eventReadinessTimeoutTask: Task<Void, Never>?
    /// Set when the short readiness wait elapsed before `ready`. The first
    /// event of that generation then takes the snapshot the wait skipped.
    @ObservationIgnored private var eventReadinessTimedOutGeneration: UInt64?
    @ObservationIgnored private var eventRestartTask: Task<Void, Never>?
    @ObservationIgnored private var eventRestartAttempt = 0
    @ObservationIgnored private var refreshRetryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRetryAttempt = 0
    @ObservationIgnored private var transientConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var confirmedTransientSessionIDs: Set<String> = []
    @ObservationIgnored private var eventGeneration: UInt64 = 0
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var sessionWaiters: [UUID: SessionWaiter] = [:]
    @ObservationIgnored private let confirmationSleep:
        @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private let eventReadinessSleep:
        @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private let restartSleep:
        @Sendable (UInt64) async throws -> Void
    @ObservationIgnored private let logger = Logger(
        subsystem: "dev.tsarev.detach", category: "session-events")

    /// The cold-start wait for `ready` before the first typed snapshot.
    static let readinessWaitNanoseconds: UInt64 = 1_000_000_000
    /// A watcher that never reports `ready` is replaced after this bound.
    static let readinessAbandonNanoseconds: UInt64 = 30_000_000_000
    /// Restart and retry delays double from this value up to the cap.
    static let restartBaseDelayNanoseconds: UInt64 = 2_000_000_000
    static let restartMaximumDelayNanoseconds: UInt64 = 60_000_000_000

    public init(
        cli: DetachCLIRunning,
        snapshotCache: (any SessionSnapshotCaching)? = nil
    ) {
        self.cli = cli
        self.snapshotCache = snapshotCache
        self.sessions = snapshotCache?.load() ?? []
        self.confirmationSleep = { try await Task.sleep(nanoseconds: $0) }
        self.eventReadinessSleep = { try await Task.sleep(nanoseconds: $0) }
        self.restartSleep = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        cli: DetachCLIRunning,
        snapshotCache: (any SessionSnapshotCaching)? = nil,
        confirmationSleep: @escaping @Sendable (UInt64) async throws -> Void,
        eventReadinessSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        restartSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.cli = cli
        self.snapshotCache = snapshotCache
        self.sessions = snapshotCache?.load() ?? []
        self.confirmationSleep = confirmationSleep
        self.eventReadinessSleep = eventReadinessSleep
        self.restartSleep = restartSleep
    }

    /// Swaps the CLI (for example after the installed payload activates),
    /// installs its event stream, and then takes one fresh typed snapshot.
    /// Waiting for `ready` closes the watch/snapshot race without the former
    /// second full list on every cold start.
    public func configure(cli: DetachCLIRunning) async {
        stopObserving()
        // Invalidate a list request from the previous executable before the
        // new watcher readiness wait suspends this reconfiguration.
        refreshGeneration &+= 1
        self.cli = cli
        hasFreshSnapshot = false
        let generation = beginObserving(refreshOnFirstEvent: false)
        await waitUntilObservationIsReady(generation: generation)
        guard generation == eventGeneration else { return }
        await refresh()
        // A missing, old, or damaged watcher must not hold app startup. Retry
        // in the background after the bounded snapshot path is available.
        if eventTask == nil { startObserving() }
    }

    /// Starts one bounded stream of native change hints. The initial `ready`
    /// event closes the refresh/watch race by requesting another full list
    /// only after FSEvents is installed.
    public func startObserving() {
        _ = beginObserving(refreshOnFirstEvent: true)
    }

    @discardableResult
    private func beginObserving(refreshOnFirstEvent: Bool) -> UInt64 {
        guard eventTask == nil else { return eventGeneration }
        eventRestartTask?.cancel()
        eventRestartTask = nil
        eventGeneration &+= 1
        let generation = eventGeneration
        let cli = self.cli
        eventTask = Task { [weak self] in
            var receivedFirstEvent = false
            var streamFailure: (any Error)?
            defer {
                if let self {
                    self.markObservationReady(generation: generation)
                    if generation == self.eventGeneration {
                        self.eventTask = nil
                        self.eventReadinessTimedOutGeneration = nil
                        // The stream ended while still wanted: the watcher
                        // exited, printed an invalid line, or an old CLI
                        // lacks `watch`. Keep the last typed snapshot and
                        // reinstall the source with bounded backoff, so the
                        // menu bar and notifications recover without a window.
                        self.logger.error(
                            "session event stream ended: \(String(describing: streamFailure), privacy: .public)")
                        self.scheduleObservationRestart()
                    }
                }
            }
            do {
                for try await _ in cli.sessionEvents() {
                    guard !Task.isCancelled,
                          let self,
                          generation == self.eventGeneration else { return }
                    if !receivedFirstEvent {
                        receivedFirstEvent = true
                        let waitElapsed =
                            self.eventReadinessTimedOutGeneration == generation
                        self.eventReadinessTimedOutGeneration = nil
                        self.eventRestartAttempt = 0
                        self.markObservationReady(generation: generation)
                        // A cold start refreshes right after `ready` itself.
                        // If the wait elapsed first, that snapshot raced the
                        // watcher installation and must be repeated now.
                        if !refreshOnFirstEvent, !waitElapsed { continue }
                    }
                    await self.refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                streamFailure = error
            }
        }
        scheduleObservationReadinessTimeout(generation: generation)
        return generation
    }

    public func stopObserving() {
        let stoppedGeneration = eventGeneration
        eventGeneration &+= 1
        eventReadinessTimeoutTask?.cancel()
        eventReadinessTimeoutTask = nil
        eventReadinessTimedOutGeneration = nil
        eventRestartTask?.cancel()
        eventRestartTask = nil
        eventRestartAttempt = 0
        eventTask?.cancel()
        eventTask = nil
        markObservationReady(generation: stoppedGeneration)
    }

    /// Repairs missed or failed event delivery at a natural boundary such as
    /// app activation. A pending backoff restart is replaced immediately.
    public func resynchronize() async {
        if eventTask == nil {
            let generation = beginObserving(refreshOnFirstEvent: false)
            await waitUntilObservationIsReady(generation: generation)
            guard generation == eventGeneration else { return }
        }
        await refresh()
        if eventTask == nil { startObserving() }
    }

    private static func backoffDelay(attempt: Int) -> UInt64 {
        let shift = min(attempt, 5)
        let scaled = restartBaseDelayNanoseconds << UInt64(shift)
        return min(scaled, restartMaximumDelayNanoseconds)
    }

    private func scheduleObservationRestart() {
        eventRestartTask?.cancel()
        let delay = Self.backoffDelay(attempt: eventRestartAttempt)
        eventRestartAttempt += 1
        let sleep = restartSleep
        eventRestartTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.eventTask == nil else { return }
            self.eventRestartTask = nil
            self.startObserving()
        }
    }

    private func waitUntilObservationIsReady(generation: UInt64) async {
        if eventReadyGeneration == generation { return }
        await withCheckedContinuation { continuation in
            if eventReadyGeneration == generation {
                continuation.resume()
            } else {
                eventReadyWaiters[generation, default: []].append(continuation)
            }
        }
    }

    private func markObservationReady(generation: UInt64) {
        if generation == eventGeneration {
            eventReadyGeneration = generation
            eventReadinessTimeoutTask?.cancel()
            eventReadinessTimeoutTask = nil
        }
        let waiters = eventReadyWaiters.removeValue(forKey: generation) ?? []
        for waiter in waiters { waiter.resume() }
    }

    /// Two bounds guard a watcher that has not reported `ready`. The short
    /// wait releases cold start so a slow but healthy watcher never delays the
    /// first snapshot; the watcher itself keeps running and refreshes on its
    /// first event. The long bound replaces a watcher that never becomes ready.
    private func scheduleObservationReadinessTimeout(generation: UInt64) {
        eventReadinessTimeoutTask?.cancel()
        let sleep = eventReadinessSleep
        eventReadinessTimeoutTask = Task { [weak self] in
            do {
                try await sleep(Self.readinessWaitNanoseconds)
            } catch {
                return
            }
            guard let self,
                  generation == self.eventGeneration,
                  self.eventReadyGeneration != generation else { return }
            self.eventReadinessTimedOutGeneration = generation
            let waiters = self.eventReadyWaiters.removeValue(forKey: generation) ?? []
            for waiter in waiters { waiter.resume() }

            do {
                try await sleep(
                    Self.readinessAbandonNanoseconds - Self.readinessWaitNanoseconds)
            } catch {
                return
            }
            guard generation == self.eventGeneration,
                  self.eventReadyGeneration != generation else { return }
            // Cancelling the stalled task runs its exit path, which schedules
            // the bounded restart for this still-current generation.
            self.logger.error("session event watcher never became ready; restarting")
            self.eventTask?.cancel()
        }
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
                    scheduleRefreshRetry(generation: generation)
                }
                return []
            }
            let parsed = SessionListParser.parse(result.stdout)
            if parsed.hadInvalidLines {
                if generation == refreshGeneration {
                    state = .incompatible // spec: never update the list from bad data
                    scheduleRefreshRetry(generation: generation)
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
            refreshRetryTask?.cancel()
            refreshRetryTask = nil
            refreshRetryAttempt = 0
            let changed = sessions != snapshot
            if changed { sessions = snapshot }
            resolveSessionWaiters(from: snapshot)
            lastUpdated = Date()
            hasFreshSnapshot = true
            state = .ok
            if changed { snapshotCache?.store(snapshot) }
            // Schedule before the observer suspends this request: a newer
            // snapshot may publish meanwhile and must own the confirmation.
            scheduleTransientConfirmation(for: snapshot)
            if let onSnapshot { await onSnapshot(sessions) }
            return snapshot
        } catch {
            if generation == refreshGeneration {
                state = .cliMissing
                scheduleRefreshRetry(generation: generation)
            }
            return []
        }
    }

    /// One lifecycle hint arrives per transition. When the typed list that
    /// follows it fails, nothing else would repeat the request, so retry with
    /// bounded backoff until a newer refresh supersedes this one.
    private func scheduleRefreshRetry(generation: UInt64) {
        refreshRetryTask?.cancel()
        let delay = Self.backoffDelay(attempt: refreshRetryAttempt)
        refreshRetryAttempt += 1
        let sleep = restartSleep
        refreshRetryTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  generation == self.refreshGeneration else { return }
            self.refreshRetryTask = nil
            await self.refresh()
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

    /// `interrupted` and `hung` can be one-frame transients: a worker that is
    /// still writing its final status, or a provider that exited moments
    /// before its worker. The runtime publishes no further hint for the pane
    /// death that resolves them, so one bounded follow-up snapshot confirms
    /// each transition exactly once.
    private static func isTransient(_ status: EffectiveStatus) -> Bool {
        status == .interrupted || status == .hung
    }

    private func scheduleTransientConfirmation(for snapshot: [Session]) {
        let transientIDs = Set(snapshot.lazy
            .filter { Self.isTransient($0.effectiveStatus) }
            .map(\.id))
        confirmedTransientSessionIDs.formIntersection(transientIDs)
        guard !transientIDs.isEmpty else {
            transientConfirmationTask?.cancel()
            transientConfirmationTask = nil
            return
        }
        let unconfirmedIDs = transientIDs.subtracting(
            confirmedTransientSessionIDs)
        guard !unconfirmedIDs.isEmpty else { return }

        transientConfirmationTask?.cancel()
        transientConfirmationTask = Task { [weak self] in
            do {
                try await self?.confirmationSleep(350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.confirmedTransientSessionIDs.formUnion(unconfirmedIDs)
            self.transientConfirmationTask = nil
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
