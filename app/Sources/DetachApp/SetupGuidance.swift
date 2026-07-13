import DetachKit

enum AmphetaminePrerequisite: String, Equatable {
    case app
    case powerProtect
}

enum SetupBlocker: Equatable {
    case repairInstallation
    case installAmphetamine([AmphetaminePrerequisite])
    case installTools([String])
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

        let ownedInstallationIDs: Set<String> = ["integrity", "cli", "manifest"]
        if failures.contains(where: { ownedInstallationIDs.contains($0.id) }) {
            return .repairInstallation
        }
        let amphetamine = [
            ("amphetamine_app", AmphetaminePrerequisite.app),
            ("amphetamine_power_protect", AmphetaminePrerequisite.powerProtect),
        ].compactMap { id, prerequisite in
            failures.contains { $0.id == id } ? prerequisite : nil
        }
        if !amphetamine.isEmpty { return .installAmphetamine(amphetamine) }
        let tools = ["tmux", "jq"].filter { id in failures.contains { $0.id == id } }
        if !tools.isEmpty { return .installTools(tools) }
        if failures.contains(where: { $0.id == "provider" }) { return .chooseProvider }
        return .other(failures[0].summary)
    }
}
