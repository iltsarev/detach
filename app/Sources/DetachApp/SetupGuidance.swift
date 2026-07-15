import DetachKit

enum SetupBlocker: Equatable {
    case repairInstallation
    case chooseProvider
    case other(String)
}

enum SetupGuidance {
    static func blocker(
        distributionMatchesBundle: Bool,
        checks: [DiagnosticCheck]
    ) -> SetupBlocker? {
        guard distributionMatchesBundle else { return .repairInstallation }
        let failures = checks.filter {
            $0.section == .base && $0.required && $0.status != .ok
                && $0.id != "watchdog" && $0.id != "cli_path"
        }
        guard !failures.isEmpty else { return nil }

        let ownedInstallationIDs: Set<String> = [
            "integrity", "cli", "manifest", "tmux", "state_helper",
            "power_runtime",
        ]
        if failures.contains(where: { ownedInstallationIDs.contains($0.id) }) {
            return .repairInstallation
        }
        if failures.contains(where: { $0.id == "provider" }) { return .chooseProvider }
        return .other(failures[0].summary)
    }
}
