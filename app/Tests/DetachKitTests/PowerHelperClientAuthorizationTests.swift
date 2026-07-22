import Darwin
import XCTest
@testable import DetachKit

final class PowerHelperClientAuthorizationPolicyTests: XCTestCase {
    private let policy = PowerHelperClientAuthorizationPolicy()

    func testAllowsOnlyTheActiveConsoleUser() {
        XCTAssertEqual(
            policy.decision(
                clientEffectiveUserIdentifier: 501,
                consoleUserIdentifier: 501),
            .allowed)
    }

    func testRejectsRootEvenWhileARegularConsoleUserIsActive() {
        XCTAssertEqual(
            policy.decision(
                clientEffectiveUserIdentifier: 0,
                consoleUserIdentifier: 501),
            .privilegedClient)
    }

    func testRejectsLoginWindowAndLogoutWithoutAnActiveConsoleUser() {
        XCTAssertEqual(
            policy.decision(
                clientEffectiveUserIdentifier: 501,
                consoleUserIdentifier: 0),
            .noActiveConsoleUser)
        XCTAssertEqual(
            policy.decision(
                clientEffectiveUserIdentifier: 501,
                consoleUserIdentifier: nil),
            .noActiveConsoleUser)
    }

    func testRejectsAnotherLocalUserAfterFastUserSwitching() {
        XCTAssertEqual(
            policy.decision(
                clientEffectiveUserIdentifier: 501,
                consoleUserIdentifier: 502),
            .differentUser)
        XCTAssertEqual(
            policy.decision(
                clientEffectiveUserIdentifier: 502,
                consoleUserIdentifier: 502),
            .allowed)
    }

    func testDecisionRawValuesAreStableForAuditLogging() {
        XCTAssertEqual(PowerHelperClientAuthorizationDecision.allowed.rawValue, "allowed")
        XCTAssertEqual(
            PowerHelperClientAuthorizationDecision.noActiveConsoleUser.rawValue,
            "noActiveConsoleUser")
        XCTAssertEqual(
            PowerHelperClientAuthorizationDecision.privilegedClient.rawValue,
            "privilegedClient")
        XCTAssertEqual(
            PowerHelperClientAuthorizationDecision.differentUser.rawValue,
            "differentUser")
    }

    func testConsoleAdmissionMatchesAuditTokenRelevantKernelFacts() {
        let processUserIdentifier = geteuid()
        var metadata = stat()
        let consoleIsCharacterDevice = Darwin.lstat("/dev/console", &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFCHR
        let expected = processUserIdentifier != 0
            && consoleIsCharacterDevice
            && metadata.st_uid == processUserIdentifier

        XCTAssertEqual(
            PowerHelperConsoleUserAdmission()
                .currentProcessIsActiveConsoleUser(),
            expected)
    }
}
