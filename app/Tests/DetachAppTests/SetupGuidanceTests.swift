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

    private func blocker(checks: [DiagnosticCheck]) -> SetupBlocker? {
        SetupGuidance.blocker(distributionMatchesBundle: true, checks: checks)
    }

    private func check(_ id: String, summary: String = "missing") -> DiagnosticCheck {
        DiagnosticCheck(
            id: id, section: .base, label: id, required: true,
            status: .error, path: nil, summary: summary)
    }
}
