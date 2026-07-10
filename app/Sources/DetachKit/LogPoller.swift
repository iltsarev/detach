import AppKit
import Foundation
import Observation

@Observable @MainActor
public final class LogPoller {
    public static let tailLimit = 500

    public private(set) var lines: [String] = []
    public private(set) var attributed = NSAttributedString()
    public private(set) var errorText: String?

    private let cli: DetachCLIRunning
    private let provider: Provider
    private let sessionName: String

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
