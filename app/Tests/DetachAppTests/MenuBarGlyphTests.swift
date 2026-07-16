import AppKit
import XCTest
@testable import DetachApp

final class MenuBarGlyphTests: XCTestCase {
    func testEveryStateProducesANonemptyTemplateImage() throws {
        let icons: [MenuBarPresentation.Icon] = [
            .active(sessionCount: nil),
            .canSleep,
            .lowBattery,
            .attention,
            .unknown,
        ]

        for icon in icons {
            let image = MenuBarGlyph.image(for: icon)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(image.isTemplate)
            XCTAssertGreaterThan(try maximumAlpha(in: image), 0)
        }
    }

    func testShapeCodedStatesHaveDistinctBitmaps() throws {
        let active = try bitmapData(for: .active(sessionCount: nil))
        let canSleep = try bitmapData(for: .canSleep)
        let attention = try bitmapData(for: .attention)
        let unknown = try bitmapData(for: .unknown)

        XCTAssertNotEqual(active, canSleep)
        XCTAssertNotEqual(active, attention)
        XCTAssertNotEqual(active, unknown)
        XCTAssertNotEqual(canSleep, attention)
        XCTAssertNotEqual(canSleep, unknown)
        XCTAssertNotEqual(attention, unknown)
    }

    private func bitmapData(
        for icon: MenuBarPresentation.Icon
    ) throws -> Data {
        let image = MenuBarGlyph.image(for: icon)
        return try XCTUnwrap(image.tiffRepresentation)
    }

    private func maximumAlpha(in image: NSImage) throws -> CGFloat {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var maximum: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                maximum = max(
                    maximum,
                    bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return maximum
    }
}
