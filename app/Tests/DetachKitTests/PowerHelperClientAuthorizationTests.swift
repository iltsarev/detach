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
}
