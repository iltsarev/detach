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
@MainActor
public final class SessionLogSnapshotCache {
    public nonisolated static let capacity = 12
    public nonisolated static let prefetchLimit = capacity
    public nonisolated static let maximumConcurrentPrefetches = 6

    private struct Key: Hashable {
        let provider: Provider
        let sessionName: String
    }

    private struct Revision: Equatable {
        let status: EffectiveStatus
        let checkpoint: Date?
        let finished: Date?
        let exitStatus: Int?
    }

    private struct ScheduledTarget: Equatable {
        let key: Key
        let revision: Revision
    }

    private var cli: DetachCLIRunning
    private var configurationID: String
    private var pollers: [Key: LogPoller] = [:]
    private var revisions: [Key: Revision] = [:]
    private var recency: [Key] = []
    private var scheduledTargets: [ScheduledTarget] = []
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
        scheduledTargets = []
        pollers = [:]
        revisions = [:]
        recency = []
        self.cli = cli
        self.configurationID = configurationID
        schedulePrefetch(for: sessions)
    }

    public func poller(for session: Session) -> LogPoller {
        let key = Key(provider: session.provider, sessionName: session.sessionName)
        if let poller = pollers[key] {
            touch(key)
            return poller
        }
        let poller = LogPoller(
            cli: cli,
            provider: session.provider,
            sessionName: session.sessionName)
        pollers[key] = poller
        touch(key)
        trimToCapacity()
        return poller
    }

    /// Starts one bounded warm-up without blocking snapshot publication.
    /// Repeated snapshots with the same cold set do no work.
    public func schedulePrefetch(for sessions: [Session]) {
        reconcile(sessions)
        let targets = prefetchTargets(in: sessions, limit: Self.prefetchLimit)
        let identities = targets.map {
            ScheduledTarget(key: key(for: $0), revision: revision(for: $0))
        }
        guard !identities.isEmpty, identities != scheduledTargets else { return }
        prefetchTask?.cancel()
        prefetchGeneration &+= 1
        let generation = prefetchGeneration
        scheduledTargets = identities
        prefetchTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            await self.prefetch(sessions, limit: Self.prefetchLimit)
            if self.prefetchGeneration == generation,
               self.scheduledTargets == identities {
                self.scheduledTargets = []
                self.prefetchTask = nil
            }
        }
    }

    /// Deterministic entry point used by the scheduler and focused tests.
    public func prefetch(
        _ sessions: [Session],
        limit: Int = prefetchLimit
    ) async {
        reconcile(sessions)
        let targets = prefetchTargets(in: sessions, limit: limit)
        let coldPollers = targets
            .map(poller(for:))
            .filter { !$0.hasLoaded }
        guard !coldPollers.isEmpty else {
            recordLoadedRevisions(for: sessions)
            return
        }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < coldPollers.count else { return }
                let poller = coldPollers[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return }
                    await poller.fetchOnce()
                }
            }
            for _ in 0..<min(
                Self.maximumConcurrentPrefetches, coldPollers.count) {
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
        guard !Task.isCancelled else { return }
        recordLoadedRevisions(for: targets)
    }

    private func prefetchTargets(in sessions: [Session], limit: Int) -> [Session] {
        guard limit > 0 else { return [] }
        return Array(sessions.lazy
            .filter { Self.shouldCache($0) }
            .filter { self.pollers[self.key(for: $0)]?.hasLoaded != true }
            .prefix(limit))
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
            exitStatus: session.exitStatus)
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

    private func recordLoadedRevisions(for sessions: [Session]) {
        for session in sessions where Self.shouldCache(session) {
            let key = key(for: session)
            if pollers[key]?.hasLoaded == true {
                revisions[key] = revision(for: session)
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
        recency.removeAll { $0 == key }
    }
}
