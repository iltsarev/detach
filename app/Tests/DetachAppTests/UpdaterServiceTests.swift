import Sparkle
import DetachKit
import XCTest
@testable import DetachApp

@MainActor
final class UpdaterServiceTests: XCTestCase {
    func testExpectedNonFailureResultsDoNotOfferFallback() {
        for code in [1001, 4007, 4008] {
            let error = NSError(domain: SUSparkleErrorDomain, code: code)
            XCTAssertNil(UpdaterService.fallbackMessage(for: error))
        }
        XCTAssertNil(UpdaterService.fallbackMessage(for: nil))
    }

    func testUpdateErrorOffersFallbackWithUsefulMessage() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"])

        XCTAssertEqual(
            UpdaterService.fallbackMessage(for: error),
            L10n.format("Sparkle couldn't complete the update: %@", "Download failed"))
    }

    func testOnlyOnLatestVersionReasonsProveTheApplicationIsCurrent() {
        for reason in [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion] {
            let error = NSError(
                domain: SUSparkleErrorDomain,
                code: 1001,
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
            XCTAssertTrue(UpdaterService.provesApplicationIsCurrent(error))
        }
    }

    func testOtherOutcomesDoNotClaimTheApplicationIsCurrent() {
        // A newer release can exist while Sparkle still reports "no update"
        // because that release is incompatible with this system.
        for reason in [
            SPUNoUpdateFoundReason.unknown, .systemIsTooOld, .systemIsTooNew,
        ] {
            let error = NSError(
                domain: SUSparkleErrorDomain,
                code: 1001,
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
            XCTAssertFalse(UpdaterService.provesApplicationIsCurrent(error))
        }
        // No reason attached, a successful cycle, and a real failure prove nothing.
        XCTAssertFalse(UpdaterService.provesApplicationIsCurrent(
            NSError(domain: SUSparkleErrorDomain, code: 1001)))
        XCTAssertFalse(UpdaterService.provesApplicationIsCurrent(nil))
        XCTAssertFalse(UpdaterService.provesApplicationIsCurrent(
            NSError(domain: SUSparkleErrorDomain, code: 2001)))
    }
}
