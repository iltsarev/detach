import AppKit
import Foundation
import Observation

@Observable @MainActor
public final class LogPoller {
    public static let tailLimit = 500

    public private(set) var lines: [String] = []
    public private(set) var attributed = NSAttributedString()
    public private(set) var errorText: String?
    public private(set) var hasLoaded = false

    private let cli: DetachCLIRunning
    private let provider: Provider
    private let sessionName: String
    private var isFetching = false

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let defaultColor = NSColor(white: 0.85, alpha: 1)

    public init(cli: DetachCLIRunning, provider: Provider, sessionName: String) {
        self.cli = cli
        self.provider = provider
        self.sessionName = sessionName
    }

    // No timer of its own: the detail view drives fetchOnce() from its
    // cancellable .task(id:) loop, so selection changes stop the polling.
    public func fetchOnce() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let result = try await cli.run(
                arguments: [provider.rawValue, "logs", "--ansi", sessionName], timeout: 5)
            guard result.exitCode == 0 else {
                errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            guard !result.stdoutTruncated else {
                errorText = L10n.string("detach returned incomplete output")
                return
            }
            let all = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let tail = Array(all.suffix(Self.tailLimit))
            hasLoaded = true
            guard tail != lines else {
                errorText = nil
                return
            }
            // A tail this size parses in single-digit milliseconds; the heavy part
            // (text layout) happens once inside LogTextView, not per frame.
            lines = tail
            attributed = ANSIParser.parse(
                tail.joined(separator: "\n"),
                font: Self.font, boldFont: Self.boldFont, defaultColor: Self.defaultColor)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Keeps immutable non-live session tails ready for instant detail switching.
/// The cache is bounded and has no timer. A changed session identity revision
/// invalidates its tail; selecting an unchanged session does no process work.
/// Warm-up never evicts a selected entry and never repeats a failed read for
/// the same typed revision, so a snapshot burst cannot become a process storm.
@MainActor
public final class SessionLogSnapshotCache {
    public nonisolated static let capacity = 12
    public nonisolated static let prefetchLimit = capacity
    public nonisolated static let maximumConcurrentPrefetches = 3

    private struct Key: Hashable {
        let provider: Provider
        let sessionName: String
    }

    private struct Revision: Equatable {
        let status: EffectiveStatus
        let checkpoint: Date?
        let finished: Date?
        let exitStatus: Int?
        let lifecycleID: String?
        /// A new run may reuse an explicit name; its creation time and,
        /// once bound, its provider identity differ.
        let created: Date?
        let agentSessionID: String?
    }

    private var cli: DetachCLIRunning
    private var configurationID: String
    private var pollers: [Key: LogPoller] = [:]
    /// The typed revision each entry is bound to. A different revision for
    /// the same name invalidates the entry.
    private var revisions: [Key: Revision] = [:]
    /// The revision a warm-up read actually started for, whether or not it
    /// succeeded. A matching revision is never warmed again.
    private var attempted: [Key: Revision] = [:]
    private var recency: [Key] = []
    private var pendingPrefetch: [Session] = []
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration: UInt64 = 0

    public init(cli: DetachCLIRunning, configurationID: String) {
        self.cli = cli
        self.configurationID = configurationID
    }

    public func configure(
        cli: DetachCLIRunning,
        configurationID: String,
        sessions: [Session] = []
    ) {
        guard configurationID != self.configurationID else {
            schedulePrefetch(for: sessions)
            return
        }
        prefetchGeneration &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        pendingPrefetch = []
        pollers = [:]
        revisions = [:]
        attempted = [:]
        recency = []
        self.cli = cli
        self.configurationID = configurationID
        schedulePrefetch(for: sessions)
    }

    public func poller(for session: Session) -> LogPoller {
        let key = Key(provider: session.provider, sessionName: session.sessionName)
        let currentRevision = revision(for: session)
        if let poller = pollers[key], revisions[key] == currentRevision {
            touch(key)
            return poller
        }
        remove(key)
        let poller = LogPoller(
            cli: cli,
            provider: session.provider,
            sessionName: session.sessionName)
        pollers[key] = poller
        // Bind the entry to the typed revision it was created for, so a
        // tail the detail view loads directly is still invalidated when the
        // session's lifecycle, or a replacement run under its name, changes.
        revisions[key] = currentRevision
        touch(key)
        trimToCapacity()
        return poller
    }

    private func recordAttempt(key: Key, revision: Revision) {
        attempted[key] = revision
    }

    /// Starts one bounded warm-up without blocking snapshot publication.
    /// Snapshot bursts queue behind active reads instead of cancelling them.
    public func schedulePrefetch(for sessions: [Session]) {
        reconcile(sessions)
        let targets = prefetchTargets(in: sessions, limit: Self.prefetchLimit)
        guard !targets.isEmpty else {
            pendingPrefetch = []
            return
        }
        // Keep the complete snapshot: reconcile treats absent rows as deleted,
        // so draining only the remaining cold subset would evict valid tails.
        pendingPrefetch = sessions
        guard prefetchTask == nil else { return }
        let generation = prefetchGeneration
        prefetchTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.drainPendingPrefetch(generation: generation)
        }
    }

    /// Deterministic entry point used by the scheduler and focused tests.
    public func prefetch(
        _ sessions: [Session],
        limit: Int = prefetchLimit
    ) async {
        reconcile(sessions)
        let targets = prefetchTargets(in: sessions, limit: limit)
        let coldTargets = targets
            .map { (key(for: $0), revision(for: $0), poller(for: $0)) }
            .filter { !$0.2.hasLoaded }
        guard !coldTargets.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < coldTargets.count else { return }
                let (key, revision, poller) = coldTargets[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    // Record the attempted revision only once the read is
                    // really starting. A read that fails or returns nothing
                    // is not repeated until the typed lifecycle changes; a
                    // cancelled, never-started read stays eligible.
                    guard !Task.isCancelled else { return }
                    await self?.recordAttempt(key: key, revision: revision)
                    await poller.fetchOnce()
                }
            }
            for _ in 0..<min(
                Self.maximumConcurrentPrefetches, coldTargets.count) {
                enqueueNext()
            }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                enqueueNext()
            }
        }
    }

    private func drainPendingPrefetch(generation: UInt64) async {
        while generation == prefetchGeneration,
              !pendingPrefetch.isEmpty,
              !Task.isCancelled {
            let targets = pendingPrefetch
            pendingPrefetch = []
            await prefetch(targets, limit: Self.prefetchLimit)
        }
        if generation == prefetchGeneration { prefetchTask = nil }
    }

    /// Selects sessions whose current typed revision has not been read. A
    /// candidate without an entry needs a free slot; warm-up never evicts an
    /// entry that the detail view may be showing.
    private func prefetchTargets(in sessions: [Session], limit: Int) -> [Session] {
        guard limit > 0 else { return [] }
        var freeSlots = max(0, Self.capacity - pollers.count)
        var targets: [Session] = []
        for session in sessions where Self.shouldCache(session) {
            guard targets.count < limit else { break }
            let key = key(for: session)
            if let existing = pollers[key] {
                if existing.hasLoaded || attempted[key] == revision(for: session) {
                    continue
                }
            } else {
                guard freeSlots > 0 else { continue }
                freeSlots -= 1
            }
            targets.append(session)
        }
        return targets
    }

    /// A live session owns an interactive terminal and its passive screen
    /// cache. Every other state uses the read-only log surface.
    public static func shouldCache(_ session: Session) -> Bool {
        !session.isLive
    }

    private func key(for session: Session) -> Key {
        Key(provider: session.provider, sessionName: session.sessionName)
    }

    private func revision(for session: Session) -> Revision {
        Revision(
            status: session.effectiveStatus,
            checkpoint: session.lastCheckpointAt,
            finished: session.finishedAt,
            exitStatus: session.exitStatus,
            lifecycleID: session.lifecycleID,
            created: session.createdAt,
            agentSessionID: session.agentSessionId)
    }

    /// Drops only entries whose typed lifecycle identity changed. A live or
    /// deleted session cannot reuse an old passive tail when it later stops.
    private func reconcile(_ sessions: [Session]) {
        var current: [Key: Session] = [:]
        for session in sessions {
            current[key(for: session)] = session
        }
        for key in Array(pollers.keys) {
            guard let session = current[key], Self.shouldCache(session) else {
                remove(key)
                continue
            }
            if let loadedRevision = revisions[key],
               loadedRevision != revision(for: session) {
                remove(key)
            }
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func trimToCapacity() {
        while recency.count > Self.capacity {
            remove(recency[0])
        }
    }

    private func remove(_ key: Key) {
        pollers.removeValue(forKey: key)
        revisions.removeValue(forKey: key)
        attempted.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }
}
