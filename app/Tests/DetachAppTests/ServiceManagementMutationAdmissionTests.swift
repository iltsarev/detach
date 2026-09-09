import XCTest
@testable import DetachApp

final class ServiceManagementMutationAdmissionTests: XCTestCase {
    private let identifiers = [
        "dev.tsarev.detach",
        "dev.tsarev.detach.power-helper",
        "dev.tsarev.detach.power-watchdog",
    ]

    func testExactReleaseIdentityPermitsServiceManagementMutation() {
        let teams = Dictionary(
            uniqueKeysWithValues: identifiers.map { ($0, "JPXHBUZBNM") })

        XCTAssertTrue(ServiceManagementMutationAdmission.permits(
            bundleIdentifier: "dev.tsarev.detach",
            validatedTeams: teams))
    }

    func testPreviewOrIncompleteIdentityCannotMutateSharedServices() {
        let releaseTeams = Dictionary(
            uniqueKeysWithValues: identifiers.map { ($0, "JPXHBUZBNM") })
        var missingHelper = releaseTeams
        missingHelper.removeValue(
            forKey: "dev.tsarev.detach.power-helper")
        var foreignWatchdog = releaseTeams
        foreignWatchdog["dev.tsarev.detach.power-watchdog"] = "ABCDEFGHIJ"

        XCTAssertFalse(ServiceManagementMutationAdmission.permits(
            bundleIdentifier: "dev.tsarev.detach.preview",
            validatedTeams: releaseTeams))
        XCTAssertFalse(ServiceManagementMutationAdmission.permits(
            bundleIdentifier: "dev.tsarev.detach",
            validatedTeams: missingHelper))
        XCTAssertFalse(ServiceManagementMutationAdmission.permits(
            bundleIdentifier: "dev.tsarev.detach",
            validatedTeams: foreignWatchdog))
        XCTAssertFalse(ServiceManagementMutationAdmission.permits(
            bundleIdentifier: "dev.tsarev.detach",
            validatedTeams: [:]))
    }

    func testAdHocTestHostCannotPassReleaseAdmission() {
        XCTAssertFalse(
            ServiceManagementMutationAdmission.currentBundleIsReleaseSigned)
    }

    func testSignedReleaseFixturePassesRealSecurityAdmission() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "DETACH_SIGNED_APP_FIXTURE"] else {
            throw XCTSkip("A signed release fixture was not supplied")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))

        XCTAssertTrue(
            ServiceManagementMutationAdmission.releaseSignedBundle(bundle))
    }
}
