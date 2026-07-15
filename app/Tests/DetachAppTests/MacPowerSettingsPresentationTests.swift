import DetachKit
import XCTest
@testable import DetachApp

final class MacPowerSettingsPresentationTests: XCTestCase {
    func testStateLabelsDescribeSleepInWords() {
        let expected: [(PowerProtectionState, String)] = [
            (.protected, "Mac stays awake"),
            (.allowed, "Mac can sleep"),
            (.transitioning, "Enabling sleep protection"),
            (.lowBattery, "Mac can sleep: low battery"),
            (.unavailable, "Sleep protection unavailable"),
            (.unknown, "Sleep status unknown"),
        ]

        for (state, localizationKey) in expected {
            XCTAssertEqual(
                presentation(state: state).stateLocalizationKey,
                localizationKey)
        }
    }

    func testApprovalActionsTakePriorityOverSetupAndRepair() {
        XCTAssertEqual(
            presentation(
                helper: .requiresApproval,
                watchdog: .notRegistered,
                distributionMatchesBundle: false).action,
            .approveHelper)
        XCTAssertEqual(
            presentation(
                helper: .enabled,
                watchdog: .requiresApproval,
                distributionMatchesBundle: false).action,
            .approveBackground)
    }

    func testMissingComponentOffersSetup() {
        XCTAssertEqual(
            presentation(helper: .notRegistered).action,
            .setup)
        XCTAssertEqual(
            presentation(watchdog: .unavailable).action,
            .setup)
    }

    func testBrokenInstalledConfigurationOffersRepair() {
        XCTAssertEqual(
            presentation(distributionMatchesBundle: false).action,
            .repair)
        XCTAssertEqual(
            presentation(state: .unavailable).action,
            .repair)
    }

    func testUnknownStateOffersRefreshAndHealthyStateNeedsNoAction() {
        XCTAssertEqual(
            presentation(state: .unknown).action,
            .refresh)
        XCTAssertNil(presentation(state: .protected).action)
        XCTAssertNil(presentation(state: .allowed).action)
        XCTAssertNil(presentation(state: .lowBattery).action)
    }

    private func presentation(
        state: PowerProtectionState = .protected,
        helper: PowerHelperRegistrationStatus = .enabled,
        watchdog: WatchdogStatus = .enabled,
        distributionMatchesBundle: Bool = true
    ) -> MacPowerSettingsPresentation {
        MacPowerSettingsPresentation(
            state: state,
            helperStatus: helper,
            watchdogStatus: watchdog,
            distributionMatchesBundle: distributionMatchesBundle)
    }
}
