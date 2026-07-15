import DetachKit
import Foundation

struct ProviderAvailability: Equatable {
    var codex = false
    var claude = false

    var any: Bool { codex || claude }
}

/// Locates provider CLIs the way they actually run: through the user's login
/// shell PATH. A bounded `--version` probe keeps a broken install (missing
/// runtime, bad shebang, wrong architecture) from counting as present. The
/// doctor report stays the source of truth for readiness; this probe only
/// tells the live poller when a refresh is worth running.
struct OnboardingProviderLocator {
    var runner: any DetachCLIRunning = ProcessDetachCLI(
        executable: URL(fileURLWithPath: "/bin/zsh"))

    func locate() async -> ProviderAvailability {
        async let codex = probe("codex")
        async let claude = probe("claude")
        return await ProviderAvailability(codex: codex, claude: claude)
    }

    private func probe(_ name: String) async -> Bool {
        let script =
            "command -v \(name) >/dev/null 2>&1 && \(name) --version >/dev/null 2>&1"
        guard let result = try? await runner.run(
            arguments: ["-lc", script], timeout: 10) else { return false }
        return result.exitCode == 0 && !result.timedOut
    }
}
