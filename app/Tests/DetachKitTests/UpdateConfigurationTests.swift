import XCTest
@testable import DetachKit

final class UpdateConfigurationTests: XCTestCase {
    private let publicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

    func testAcceptsConfiguredApplicationInApplications() {
        let configuration = makeConfiguration()

        XCTAssertTrue(configuration.isAvailable)
        XCTAssertEqual(configuration.feedURL?.absoluteString,
                       "https://example.com/appcast.xml")
        XCTAssertEqual(configuration.manualDownloadURL?.absoluteString,
                       "https://example.com/download")
    }

    func testRejectsInsecureFeedAndInvalidPublicKey() {
        let configuration = makeConfiguration(
            feedURL: "http://example.com/appcast.xml", publicKey: "not-a-key")

        XCTAssertEqual(configuration.issues, [.invalidFeedURL, .invalidPublicKey])
    }

    func testRejectsPackagedApplicationOnMountedDMG() {
        let configuration = makeConfiguration(
            applicationURL: URL(fileURLWithPath: "/Volumes/Detach/Detach.app"))

        XCTAssertEqual(configuration.issues, [.unstableApplicationLocation])
    }

    func testRejectsAppTranslocation() {
        XCTAssertFalse(UpdateConfiguration.isStableApplicationLocation(
            URL(fileURLWithPath:
                "/private/var/folders/AppTranslocation/Detach.app")))
    }

    func testIgnoresLocationForUnpackagedDeveloperExecutable() {
        let configuration = makeConfiguration(
            applicationURL: URL(fileURLWithPath: "/tmp/DetachApp"),
            isPackagedApplication: false)

        XCTAssertTrue(configuration.isAvailable)
    }

    func testRejectsInsecureManualDownloadURLWithoutDisablingUpdater() {
        let configuration = makeConfiguration(downloadURL: "http://example.com/download")

        XCTAssertTrue(configuration.isAvailable)
        XCTAssertNil(configuration.manualDownloadURL)
    }

    private func makeConfiguration(
        feedURL: String = "https://example.com/appcast.xml",
        publicKey: String? = nil,
        downloadURL: String = "https://example.com/download",
        applicationURL: URL = URL(fileURLWithPath: "/Applications/Detach.app"),
        isPackagedApplication: Bool = true
    ) -> UpdateConfiguration {
        UpdateConfiguration(
            feedURLString: feedURL,
            publicEDKey: publicKey ?? self.publicKey,
            downloadURLString: downloadURL,
            applicationURL: applicationURL,
            isPackagedApplication: isPackagedApplication)
    }
}
