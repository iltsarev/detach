import XCTest
@testable import DetachApp
@testable import DetachKit

@MainActor
final class PetNavigationTests: XCTestCase {
    func testPrimaryActionOpensOneHighestPrioritySession() {
        let input = activity(id: "input", state: .needsInput)
        let blocked = activity(id: "blocked", state: .blocked)

        XCTAssertEqual(
            PetPrimaryActionResolver.resolve([blocked, input]),
            .open(input))
        XCTAssertEqual(PetPrimaryActionResolver.resolve([]), .open(nil))
    }

    func testPrimaryActionOffersChoiceForEqualTopPrioritySessions() {
        XCTAssertEqual(PetPrimaryActionResolver.resolve([
            activity(id: "first", state: .needsInput),
            activity(id: "second", state: .needsInput),
            activity(id: "working", state: .running),
        ]), .choose)
    }

    func testPetPointerIntentDistinguishesTapFromDrag() {
        var tap = PetPointerIntent()
        tap.begin(at: NSPoint(x: 10, y: 20))
        tap.update(to: NSPoint(x: 12, y: 22))
        XCTAssertTrue(tap.shouldActivate)

        var drag = PetPointerIntent()
        drag.begin(at: NSPoint(x: 10, y: 20))
        drag.update(to: NSPoint(x: 16, y: 20))
        XCTAssertFalse(drag.shouldActivate)

        drag.end()
        drag.begin(at: NSPoint(x: 30, y: 40))
        XCTAssertTrue(drag.shouldActivate)
    }

    func testActivityOpensTheExactSession() {
        let suiteName = "detach-pet-navigation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: URL(fileURLWithPath: "/nonexistent"))
        let navigation = MainNavigation()
        let activity = PetActivity(
            sessionID: "claude-review",
            title: "Review",
            provider: .claude,
            state: .ready,
            recencyAt: nil)
        var opened = false

        PetSessionNavigator.open(
            activity,
            coordinator: coordinator,
            navigation: navigation,
            openMainWindow: { opened = true })

        XCTAssertEqual(navigation.requestedSessionID, "claude-review")
        XCTAssertTrue(opened)
    }

    func testNeedsInputNavigationRequestsExactSession() {
        let suiteName = "detach-pet-navigation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: URL(fileURLWithPath: "/nonexistent"))
        let navigation = MainNavigation()
        let activity = activity(id: "input", state: .needsInput)

        PetSessionNavigator.open(
            activity,
            coordinator: coordinator,
            navigation: navigation,
            openMainWindow: {})

        XCTAssertEqual(navigation.requestedSessionID, "input")
    }

    func testIdlePetStillOpensTheMainWindow() {
        let suiteName = "detach-pet-navigation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: URL(fileURLWithPath: "/nonexistent"))
        let navigation = MainNavigation()
        var opened = false

        PetSessionNavigator.open(
            nil,
            coordinator: coordinator,
            navigation: navigation,
            openMainWindow: { opened = true })

        XCTAssertNil(navigation.requestedSessionID)
        XCTAssertTrue(opened)
    }

    func testPetWindowContextActionsOpenSettingsAndHidePet() {
        let suiteName = "detach-pet-context-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = PetCoordinator(
            defaults: defaults,
            libraryRoot: URL(fileURLWithPath: "/nonexistent"))
        coordinator.isEnabled = true
        var openedSettings = false

        PetWindowContextActionHandler.perform(
            .openSettings,
            coordinator: coordinator,
            openPetSettings: { openedSettings = true })

        XCTAssertTrue(openedSettings)
        XCTAssertTrue(coordinator.isEnabled)

        PetWindowContextActionHandler.perform(
            .hide,
            coordinator: coordinator,
            openPetSettings: { XCTFail("Hide must not open Settings") })

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: PetCoordinator.enabledKey))
    }

    private func activity(id: String, state: PetActivityState) -> PetActivity {
        PetActivity(
            sessionID: id,
            title: id,
            provider: .claude,
            state: state,
            recencyAt: nil)
    }
}
