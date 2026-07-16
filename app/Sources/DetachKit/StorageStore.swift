import Foundation
import Observation

@Observable @MainActor
public final class StorageStore {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ok
        case cliMissing
        case incompatible
        case error(String)
    }

    public private(set) var report: StorageReport?
    public private(set) var state: State = .idle
    public private(set) var lastUpdated: Date?

    private var cli: DetachCLIRunning
    private var generation: UInt64 = 0

    public init(cli: DetachCLIRunning) {
        self.cli = cli
    }

    public func configure(cli: DetachCLIRunning) async {
        self.cli = cli
        await refresh()
    }

    public func refresh() async {
        generation &+= 1
        let currentGeneration = generation
        let cli = self.cli
        state = .loading
        do {
            let result = try await cli.run(arguments: ["storage", "--json"], timeout: 30)
            guard currentGeneration == generation else { return }
            guard result.exitCode == 0, !result.timedOut else {
                state = .error(result.timedOut
                    ? L10n.string("Storage scan timed out")
                    : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            let decoder = JSONDecoder()
            guard let decoded = try? decoder.decode(StorageReport.self, from: Data(result.stdout.utf8)),
                  decoded.schema == 1 else {
                state = .incompatible
                return
            }
            report = decoded
            lastUpdated = Date()
            state = .ok
        } catch {
            guard currentGeneration == generation else { return }
            state = .cliMissing
        }
    }

    /// Deletes only candidates that still have the exact size, status and
    /// eligibility shown in the confirmation UI. Each provider command then
    /// rechecks tmux ownership/liveness while holding the checkpoint lock.
    public func cleanup(expected: [StorageSession]) async -> [String] {
        await refresh()
        guard case .ok = state, let current = report else {
            return [L10n.string("Storage changed before cleanup; review it again.")]
        }
        let currentByID = Dictionary(uniqueKeysWithValues: current.sessions.map { ($0.id, $0) })
        for candidate in expected {
            guard let latest = currentByID[candidate.id],
                  latest.deletable,
                  latest == candidate else {
                return [L10n.string("Storage changed before cleanup; review it again.")]
            }
        }

        var failures: [String] = []
        for candidate in expected {
            do {
                let result = try await cli.run(arguments: [
                    candidate.provider.rawValue, "delete", "--force", candidate.sessionName,
                ], timeout: 30)
                if result.exitCode != 0 || result.timedOut {
                    let detail = result.timedOut
                        ? L10n.string("timed out")
                        : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    failures.append("\(candidate.sessionName): \(detail.isEmpty ? L10n.string("failed") : detail)")
                }
            } catch {
                failures.append("\(candidate.sessionName): \(error.localizedDescription)")
            }
        }
        await refresh()
        return failures
    }
}
