import XCTest
import DetachKit
@testable import DetachApp

final class SetupGuidanceTests: XCTestCase {
    func testMissingToolsAreGroupedInsteadOfOfferingRepair() {
        XCTAssertEqual(
            blocker(checks: [check("tmux"), check("jq")]),
            .installTools(["tmux", "jq"]))
    }

    func testProviderGetsDedicatedGuidance() {
        XCTAssertEqual(blocker(checks: [check("provider")]), .chooseProvider)
    }

    func testMissingAmphetaminePrerequisitesGetOfficialInstallGuidance() {
        XCTAssertEqual(
            blocker(checks: [
                check("amphetamine_app"),
                check("amphetamine_power_protect"),
            ]),
            .installAmphetamine([.app, .powerProtect]))
        XCTAssertEqual(
            blocker(checks: [check("amphetamine_power_protect")]),
            .installAmphetamine([.powerProtect]))
    }

    func testAmphetaminePrerequisitesTakePriorityOverOtherExternalTools() {
        XCTAssertEqual(
            blocker(checks: [check("tmux"), check("amphetamine_app")]),
            .installAmphetamine([.app]))
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

    private func blocker(checks: [DiagnosticCheck]) -> SetupBlocker? {
        SetupGuidance.blocker(distributionMatchesBundle: true, checks: checks)
    }

    private func check(_ id: String, summary: String = "missing") -> DiagnosticCheck {
        DiagnosticCheck(
            id: id, section: .base, label: id, required: true,
            status: .error, path: nil, summary: summary)
    }
}
