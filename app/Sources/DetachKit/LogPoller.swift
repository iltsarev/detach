import Foundation
import Observation

@Observable @MainActor
public final class LogPoller {
    public static let tailLimit = 500

    public private(set) var lines: [String] = []
    public private(set) var errorText: String?

    private let cli: DetachCLIRunning
    private let provider: Provider
    private let sessionName: String

    public init(cli: DetachCLIRunning, provider: Provider, sessionName: String) {
        self.cli = cli
        self.provider = provider
        self.sessionName = sessionName
    }

    // No timer of its own: the detail view drives fetchOnce() from its
    // cancellable .task(id:) loop, so selection changes stop the polling.
    public func fetchOnce() async {
        do {
            let result = try await cli.run(
                arguments: [provider.rawValue, "logs", sessionName], timeout: 5)
            guard result.exitCode == 0 else {
                errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            let all = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            lines = Array(all.suffix(Self.tailLimit))
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
