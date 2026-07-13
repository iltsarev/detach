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
}
