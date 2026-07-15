import DetachKit

enum SetupBlocker: Equatable {
    case repairInstallation
    case chooseProvider
    case other(String)
}

/// The single card the onboarding assistant shows, derived deterministically
/// from installation state. The order encodes the spec's priority table.
enum OnboardingStep: Equatable {
    case moveToApplications
    case autoSetup(failureMessage: String?)
    case permissions
    case provider
    case done
    case mainApp
}

struct OnboardingStepInput: Equatable {
    var isStableApplicationLocation: Bool
    var isBusy: Bool
    var failureMessage: String?
    var distributionMatchesBundle: Bool
    var powerHelperEnabled: Bool
    var watchdogEnabled: Bool
    var powerReadinessConfirmed: Bool
    var providerInstalled: Bool
    var onboardingEverCompleted: Bool
}

enum SetupGuidance {
    /// A payload failure outranks provider discovery, so an install error on
    /// a machine without a provider is presented as an error, not as
    /// "install an AI client". Once onboarding has ever completed, a missing
    /// provider no longer brings the assistant back, and the success card is
    /// shown exactly once.
    static func step(for input: OnboardingStepInput) -> OnboardingStep {
        if !input.isStableApplicationLocation { return .moveToApplications }
        if input.isBusy { return .autoSetup(failureMessage: nil) }
        if let failure = input.failureMessage {
            return .autoSetup(failureMessage: failure)
        }
        if !input.distributionMatchesBundle {
            return .autoSetup(failureMessage: nil)
        }
        if !(input.powerHelperEnabled && input.watchdogEnabled
                && input.powerReadinessConfirmed) {
            return .permissions
        }
        if !input.providerInstalled && !input.onboardingEverCompleted {
            return .provider
        }
        return input.onboardingEverCompleted ? .mainApp : .done
    }

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
