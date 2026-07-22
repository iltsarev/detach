import XCTest
import DetachKit
@testable import DetachApp

final class SetupGuidanceTests: XCTestCase {
    func testMissingBundledRuntimeOffersRepairInsteadOfExternalInstallation() {
        for id in ["tmux", "state_helper", "power_runtime"] {
            XCTAssertEqual(
                blocker(checks: [check(id)]),
                .repairInstallation,
                "expected Repair guidance for \(id)")
        }
    }

    func testUnreachableRegisteredHelperIsNotMisreportedAsPayloadDamage() {
        XCTAssertEqual(
            blocker(checks: [
                check("power_helper", summary: "helper unavailable"),
            ]),
            .other("helper unavailable"))
    }

    func testProviderGetsDedicatedGuidance() {
        XCTAssertEqual(blocker(checks: [check("provider")]), .chooseProvider)
    }

    func testOwnedIntegrityFailureOffersRepair() {
        XCTAssertEqual(blocker(checks: [check("integrity")]), .repairInstallation)
        XCTAssertEqual(blocker(checks: [check("manifest")]), .repairInstallation)
    }

    func testCLIPathDoesNotBlockAppOwnedAbsolutePath() {
        XCTAssertNil(blocker(checks: [check("cli_path")]))
    }

    func testUnknownRequiredFailureShowsItsSummary() {
        XCTAssertEqual(
            blocker(checks: [check("future", summary: "Нужна новая настройка")]),
            .other("Нужна новая настройка"))
    }

    func testDistributionMismatchAlwaysOffersRepair() {
        XCTAssertEqual(
            SetupGuidance.blocker(
                distributionMatchesBundle: false,
                checks: [check("provider")]),
            .repairInstallation)
    }

    func testOnlyRequiredFailingBaseChecksCanBlockSetup() {
        let ignored = [
            check("optional", required: false),
            check("healthy", status: .ok),
            check("provider", section: .keepAwake),
            check("watchdog"),
            check("cli_path"),
        ]

        XCTAssertNil(blocker(checks: ignored))
    }

    func testRequiredWarningStillBlocksSetup() {
        XCTAssertEqual(
            blocker(checks: [
                check("approval", summary: "approval pending", status: .warning),
            ]),
            .other("approval pending"))
    }

    func testOwnedInstallationFailureOutranksProviderGuidance() {
        XCTAssertEqual(
            blocker(checks: [check("provider"), check("cli")]),
            .repairInstallation)
    }

    func testProviderFailureOutranksUnknownFailure() {
        XCTAssertEqual(
            blocker(checks: [
                check("future", summary: "future setup"),
                check("provider"),
            ]),
            .chooseProvider)
    }

    private func blocker(checks: [DiagnosticCheck]) -> SetupBlocker? {
        SetupGuidance.blocker(distributionMatchesBundle: true, checks: checks)
    }

    private func check(
        _ id: String,
        summary: String = "missing",
        section: DiagnosticCheck.Section = .base,
        required: Bool = true,
        status: DiagnosticCheck.Status = .error
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id, section: section, label: id, required: required,
            status: status, path: nil, summary: summary)
    }
}

final class OnboardingStepTests: XCTestCase {
    func testUnstableLocationOutranksEverything() {
        var input = readyInput()
        input.isStableApplicationLocation = false
        input.failureMessage = "boom"
        XCTAssertEqual(SetupGuidance.step(for: input), .moveToApplications)
    }

    func testBusyMatchedRuntimeUsesPublishedGatesInsteadOfFirstScreen() {
        var input = readyInput()
        input.isBusy = true
        XCTAssertEqual(SetupGuidance.step(for: input), .done)
    }

    func testBusyPermissionGatesAdvanceAfterRuntimeMatches() {
        var helperApproval = readyInput()
        helperApproval.isBusy = true
        helperApproval.powerHelperEnabled = false
        helperApproval.powerReadinessConfirmed = false

        var watchdogApproval = readyInput()
        watchdogApproval.isBusy = true
        watchdogApproval.watchdogEnabled = false

        var readinessProbe = readyInput()
        readinessProbe.isBusy = true
        readinessProbe.powerReadinessConfirmed = false

        for input in [helperApproval, watchdogApproval, readinessProbe] {
            XCTAssertEqual(SetupGuidance.step(for: input), .permissions)
        }
    }

    func testBusyPayloadMismatchStaysOnAutomaticSetup() {
        var input = readyInput()
        input.isBusy = true
        input.distributionMatchesBundle = false
        input.powerHelperEnabled = false
        input.powerReadinessConfirmed = false

        XCTAssertEqual(
            SetupGuidance.step(for: input),
            .autoSetup(failureMessage: nil))
    }

    func testFirstOnboardingSequenceNeverMovesBackwardAfterRuntimeMatches() {
        var input = readyInput()
        input.distributionMatchesBundle = false
        input.isBusy = true
        input.powerHelperEnabled = false
        input.watchdogEnabled = false
        input.powerReadinessConfirmed = false
        XCTAssertEqual(
            SetupGuidance.step(for: input),
            .autoSetup(failureMessage: nil))

        input.distributionMatchesBundle = true
        XCTAssertEqual(SetupGuidance.step(for: input), .permissions)

        input.powerHelperEnabled = true
        input.watchdogEnabled = true
        input.powerReadinessConfirmed = true
        XCTAssertEqual(SetupGuidance.step(for: input), .done)

        input.isBusy = false
        XCTAssertEqual(SetupGuidance.step(for: input), .done)
    }

    func testProviderScreenDoesNotMoveBackwardDuringRefresh() {
        var input = readyInput()
        input.providerInstalled = false
        input.isBusy = true

        XCTAssertEqual(SetupGuidance.step(for: input), .provider)
    }

    func testFailureOutranksProviderDiscovery() {
        var input = readyInput()
        input.failureMessage = "installer failed"
        input.providerInstalled = false
        XCTAssertEqual(
            SetupGuidance.step(for: input),
            .autoSetup(failureMessage: "installer failed"))
    }

    func testPayloadMismatchKeepsAutoSetupPending() {
        var input = readyInput()
        input.distributionMatchesBundle = false
        XCTAssertEqual(
            SetupGuidance.step(for: input),
            .autoSetup(failureMessage: nil))
    }

    func testEnabledStatusAloneDoesNotCompletePermissions() {
        var input = readyInput()
        input.powerReadinessConfirmed = false
        XCTAssertEqual(SetupGuidance.step(for: input), .permissions)
    }

    func testAnyServiceNotEnabledKeepsPermissionsStep() {
        var watchdogPending = readyInput()
        watchdogPending.watchdogEnabled = false
        XCTAssertEqual(SetupGuidance.step(for: watchdogPending), .permissions)

        var helperPending = readyInput()
        helperPending.powerHelperEnabled = false
        XCTAssertEqual(SetupGuidance.step(for: helperPending), .permissions)
    }

    func testMissingProviderBlocksOnlyFirstOnboarding() {
        var input = readyInput()
        input.providerInstalled = false
        XCTAssertEqual(SetupGuidance.step(for: input), .provider)

        input.onboardingEverCompleted = true
        XCTAssertEqual(SetupGuidance.step(for: input), .mainApp)
    }

    func testSuccessCardShowsExactlyOnce() {
        var input = readyInput()
        XCTAssertEqual(SetupGuidance.step(for: input), .done)

        input.onboardingEverCompleted = true
        XCTAssertEqual(SetupGuidance.step(for: input), .mainApp)
    }

    private func readyInput() -> OnboardingStepInput {
        OnboardingStepInput(
            isStableApplicationLocation: true,
            isBusy: false,
            failureMessage: nil,
            distributionMatchesBundle: true,
            powerHelperEnabled: true,
            watchdogEnabled: true,
            powerReadinessConfirmed: true,
            providerInstalled: true,
            onboardingEverCompleted: false)
    }
}
