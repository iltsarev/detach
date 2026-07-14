import XCTest
@testable import DetachApp
import DetachKit

@MainActor
final class TipSessionTests: XCTestCase {
    private let tips = [
        DetachTip(id: "one", localizationKey: "One", destination: .general),
        DetachTip(id: "two", localizationKey: "Two", destination: .terminal),
    ]

    func testEachAppSessionAdvancesThePersistedRotationOnce() throws {
        let defaults = try isolatedDefaults()
        let rotation = TipRotation(tips: tips)

        let firstLaunch = TipSession(
            rotation: rotation,
            defaults: defaults,
            lastShownIdentifierKey: "last")
        XCTAssertEqual(firstLaunch.currentTip?.id, "one")
        XCTAssertEqual(defaults.string(forKey: "last"), "one")

        let secondLaunch = TipSession(
            rotation: rotation,
            defaults: defaults,
            lastShownIdentifierKey: "last")
        XCTAssertEqual(secondLaunch.currentTip?.id, "two")
        XCTAssertEqual(defaults.string(forKey: "last"), "two")
    }

    func testManualNextPersistsAndDismissOnlyAffectsCurrentSession() throws {
        let defaults = try isolatedDefaults()
        let rotation = TipRotation(tips: tips)

        let session = TipSession(
            rotation: rotation,
            defaults: defaults,
            lastShownIdentifierKey: "last")

        session.showNext()
        XCTAssertEqual(session.currentTip?.id, "two")
        XCTAssertEqual(defaults.string(forKey: "last"), "two")

        session.dismissUntilNextLaunch()
        XCTAssertTrue(session.isDismissed)
        XCTAssertEqual(defaults.string(forKey: "last"), "two")

        let nextLaunch = TipSession(
            rotation: rotation,
            defaults: defaults,
            lastShownIdentifierKey: "last")
        XCTAssertFalse(nextLaunch.isDismissed)
        XCTAssertEqual(nextLaunch.currentTip?.id, "one")
    }

    func testSettingsNavigationSelectsTipDestination() {
        let navigation = SettingsNavigation()

        navigation.select(.updates)

        XCTAssertEqual(navigation.selectedTab, .updates)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "TipSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
