import Sparkle
import DetachKit
import XCTest
@testable import DetachApp

@MainActor
final class UpdaterServiceTests: XCTestCase {
    func testDevelopmentBundleKeepsInvalidUpdaterConfigurationDormant() {
        let service = UpdaterService()

        XCTAssertFalse(service.isAvailable)
        XCTAssertTrue(service.shouldOfferManualDownload)
        XCTAssertNil(service.lastUpdateCheckDate)
        XCTAssertNotNil(service.unavailableReason)
        XCTAssertTrue(
            service.unavailableReason?.contains("local development") == true)

        service.checkForUpdates()
        service.setAutomaticallyChecksForUpdates(true)
        service.setAutomaticallyDownloadsUpdates(true)
        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        XCTAssertFalse(service.automaticallyDownloadsUpdates)
        XCTAssertFalse(service.canAutomaticallyDownloadUpdates)
    }

    func testAutomaticDownloadRequiresAvailableChecks() {
        XCTAssertFalse(UpdaterService.canAutomaticallyDownloadUpdates(
            isAvailable: false, checksEnabled: true))
        XCTAssertFalse(UpdaterService.canAutomaticallyDownloadUpdates(
            isAvailable: true, checksEnabled: false))
        XCTAssertTrue(UpdaterService.canAutomaticallyDownloadUpdates(
            isAvailable: true, checksEnabled: true))

        XCTAssertFalse(UpdaterService.canChangeAutomaticDownload(
            enable: true, isAvailable: false, checksEnabled: true))
        XCTAssertFalse(UpdaterService.canChangeAutomaticDownload(
            enable: true, isAvailable: true, checksEnabled: false))
        XCTAssertTrue(UpdaterService.canChangeAutomaticDownload(
            enable: false, isAvailable: true, checksEnabled: false))
        XCTAssertTrue(UpdaterService.canChangeAutomaticDownload(
            enable: true, isAvailable: true, checksEnabled: true))
    }

    func testExpectedNonFailureResultsDoNotOfferFallback() {
        for code in [1001, 4007, 4008] {
            let error = NSError(domain: SUSparkleErrorDomain, code: code)
            XCTAssertNil(UpdaterService.fallbackMessage(for: error))
            XCTAssertNil(UpdaterService.recovery(for: error))
        }
        XCTAssertNil(UpdaterService.fallbackMessage(for: nil))
        XCTAssertNil(UpdaterService.recovery(for: nil))
    }

    func testDownloadErrorKeepsTheActiveCLIAndOffersRetry() {
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"])

        XCTAssertEqual(UpdaterService.recovery(for: error), .retryDownload)
        XCTAssertEqual(
            UpdaterService.fallbackMessage(for: error),
            L10n.format(
                "Detach could not prepare or download the update: %@. The active CLI did not change. Check the network connection and free disk space. Then try again.",
                "Download failed"))
    }

    func testFailureMatrixSelectsARecoveryAndDoesNotClaimCurrentVersion() throws {
        let cases: [(label: String, code: Int, recovery: UpdaterService.UpdateRecovery)] = [
            ("read-only DMG", 1003, .moveToApplications),
            ("App Translocation", 1005, .moveToApplications),
            ("temporary directory", 2000, .retryDownload),
            ("offline download", 2001, .retryDownload),
            ("bad archive", 3000, .reinstallAndRepair),
            ("bad signature", 3001, .reinstallAndRepair),
            ("failed validation", 3002, .reinstallAndRepair),
            ("file copy", 4000, .reinstallAndRepair),
            ("installation", 4005, .reinstallAndRepair),
            ("invalid update", 4009, .reinstallAndRepair),
            ("read-only destination", 4012, .reinstallAndRepair),
        ]

        for item in cases {
            let error = NSError(
                domain: SUSparkleErrorDomain,
                code: item.code,
                userInfo: [NSLocalizedDescriptionKey: item.label])
            let message = try XCTUnwrap(
                UpdaterService.fallbackMessage(for: error),
                "Missing recovery message for \(item.label)")

            XCTAssertEqual(UpdaterService.recovery(for: error), item.recovery, item.label)
            XCTAssertTrue(message.contains("The active CLI did not change."), item.label)
            XCTAssertFalse(UpdaterService.provesApplicationIsCurrent(error), item.label)
        }
    }

    func testUnknownErrorUsesReinstallAndRepairRecovery() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Write failed"])

        XCTAssertEqual(UpdaterService.recovery(for: error), .reinstallAndRepair)
        XCTAssertTrue(
            UpdaterService.fallbackMessage(for: error)?.contains("run Repair") == true)
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
