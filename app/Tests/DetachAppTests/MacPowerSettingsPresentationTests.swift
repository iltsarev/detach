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

    func testReasonComesFromHeartbeatStateFirst() {
        // Session count enriches the protected case…
        XCTAssertEqual(
            presentation(state: .protected, activeSessionCount: 2).reason,
            .activeSessions(2))
        // …but never contradicts the heartbeat: a cached session list with
        // zero running entries degrades to a generic protected reason.
        XCTAssertEqual(
            presentation(state: .protected, activeSessionCount: 0).reason,
            .protectionActive)
        XCTAssertEqual(
            presentation(state: .protected, activeSessionCount: nil).reason,
            .protectionActive)
        // A stale/unknown heartbeat wins over any live session count.
        XCTAssertEqual(
            presentation(state: .unknown, activeSessionCount: 3).reason,
            .noFreshReport)
    }

    func testReasonsForRemainingStates() {
        let expected: [(PowerProtectionState, MacPowerSettingsPresentation.Reason)] = [
            (.allowed, .noActiveSessions),
            (.lowBattery, .lowBattery),
            (.transitioning, .confirming),
            (.unavailable, .helperUnreachable),
        ]
        for (state, reason) in expected {
            XCTAssertEqual(presentation(state: state).reason, reason)
        }
    }

    private func presentation(
        state: PowerProtectionState = .protected,
        helper: PowerHelperRegistrationStatus = .enabled,
        watchdog: WatchdogStatus = .enabled,
        distributionMatchesBundle: Bool = true,
        activeSessionCount: Int? = nil
    ) -> MacPowerSettingsPresentation {
        MacPowerSettingsPresentation(
            state: state,
            helperStatus: helper,
            watchdogStatus: watchdog,
            distributionMatchesBundle: distributionMatchesBundle,
            activeSessionCount: activeSessionCount)
    }
}
