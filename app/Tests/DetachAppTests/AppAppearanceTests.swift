import AppKit
import XCTest
@testable import DetachApp

@MainActor
final class AppAppearanceTests: XCTestCase {
    private var originalAppearance: NSAppearance?

    override func setUp() async throws {
        originalAppearance = NSApplication.shared.appearance
    }

    override func tearDown() async throws {
        NSApplication.shared.appearance = originalAppearance
    }

    func testDefaultFollowsTheSystem() {
        XCTAssertEqual(AppAppearance.defaultValue, .system)
        XCTAssertEqual(AppAppearance(storedValue: nil), .system)
    }

    func testStoredValuesDecodeAndUnknownValuesFallBackToSystem() {
        XCTAssertEqual(AppAppearance(storedValue: "system"), .system)
        XCTAssertEqual(AppAppearance(storedValue: "light"), .light)
        XCTAssertEqual(AppAppearance(storedValue: "dark"), .dark)
        XCTAssertEqual(AppAppearance(storedValue: "Dark"), .system)
        XCTAssertEqual(AppAppearance(storedValue: ""), .system)
    }

    func testChoicesMapToAquaAppearances() {
        XCTAssertNil(AppAppearance.system.appearanceName)
        XCTAssertEqual(AppAppearance.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearance.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
    }

    func testApplyForcesAndThenReleasesTheApplicationAppearance() {
        let application = NSApplication.shared

        AppAppearance.dark.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .darkAqua)
        XCTAssertEqual(
            application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .darkAqua)

        AppAppearance.light.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .aqua)

        AppAppearance.system.apply(to: application)
        XCTAssertNil(application.appearance)
    }

    func testStoredValueIsAppliedFromTheGivenDefaults() throws {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let application = NSApplication.shared

        defaults.set("dark", forKey: AppAppearance.storageKey)
        AppAppearance.applyStoredValue(from: defaults, to: application)
        XCTAssertEqual(application.appearance?.name, .darkAqua)

        defaults.set("unexpected", forKey: AppAppearance.storageKey)
        AppAppearance.applyStoredValue(from: defaults, to: application)
        XCTAssertNil(application.appearance)
    }
}
