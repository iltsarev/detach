import XCTest
@testable import DetachKit

final class TipRotationTests: XCTestCase {
    private let tips = [
        DetachTip(id: "one", localizationKey: "One"),
        DetachTip(id: "two", localizationKey: "Two"),
        DetachTip(id: "three", localizationKey: "Three"),
    ]

    func testEmptyCatalogHasNoNextTip() {
        XCTAssertNil(TipRotation(tips: []).next(after: nil))
        XCTAssertNil(TipRotation(tips: []).next(after: "missing"))
    }

    func testSingleTipReturnsItself() {
        let tip = DetachTip(id: "only", localizationKey: "Only")
        let rotation = TipRotation(tips: [tip])

        XCTAssertEqual(rotation.next(after: nil), tip)
        XCTAssertEqual(rotation.next(after: tip.id), tip)
    }

    func testUnknownIdentifierStartsAtFirstTip() {
        let rotation = TipRotation(tips: tips)

        XCTAssertEqual(rotation.next(after: "removed")?.id, "one")
    }

    func testRotationVisitsWholeCatalogThenWraps() throws {
        let rotation = TipRotation(tips: tips)
        var lastIdentifier: String?
        var visited: [String] = []

        for _ in tips.indices {
            let tip = try XCTUnwrap(rotation.next(after: lastIdentifier))
            visited.append(tip.id)
            lastIdentifier = tip.id
        }

        XCTAssertEqual(visited, tips.map(\.id))
        XCTAssertEqual(rotation.next(after: lastIdentifier)?.id, tips[0].id)
    }

    func testMultipleTipsNeverRepeatAdjacent() throws {
        let rotation = TipRotation(tips: tips)
        var previous = try XCTUnwrap(rotation.next(after: nil))

        for _ in 0..<(tips.count * 3) {
            let next = try XCTUnwrap(rotation.next(after: previous.id))
            XCTAssertNotEqual(next.id, previous.id)
            previous = next
        }
    }

    func testCatalogIdentifiersAreUnique() {
        let identifiers = TipCatalog.all.map(\.id)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testCatalogContainsEightTipsAndLinksEverySettingsTab() {
        let destinations = Set(TipCatalog.all.compactMap(\.destination))

        XCTAssertEqual(TipCatalog.all.count, 8)
        XCTAssertEqual(destinations, Set(SettingsDestination.allCases))
    }

    func testTipLocalizedTextUsesRequestedBundleAndLocale() {
        let tip = DetachTip(id: "test", localizationKey: "Untranslated test tip")

        XCTAssertEqual(
            tip.localizedText(bundle: Bundle(for: Self.self), locale: Locale(identifier: "en")),
            L10n.string(
                tip.localizationKey,
                bundle: Bundle(for: Self.self),
                locale: Locale(identifier: "en")))
    }
}
