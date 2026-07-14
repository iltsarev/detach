import XCTest
@testable import DetachApp
import DetachKit

final class TipSessionTests: XCTestCase {
    private let tips = [
        DetachTip(id: "one", localizationKey: "One"),
        DetachTip(id: "two", localizationKey: "Two"),
    ]

    @MainActor
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

    @MainActor
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
