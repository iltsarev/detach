import AppKit
import XCTest
@testable import DetachApp

final class MenuBarGlyphTests: XCTestCase {
    func testEveryStateProducesANonemptyTemplateImageWithoutSessions() throws {
        let icons: [MenuBarPresentation.Icon] = [
            .active(sessionCount: nil),
            .canSleep,
            .lowBattery,
            .attention,
            .unknown,
        ]

        for icon in icons {
            let image = MenuBarGlyph.image(for: icon, dot: .none)
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

    func testSessionDotDisablesTemplateRendering() {
        // A colored dot needs real color; the monochrome states must keep the
        // adaptive template contract.
        XCTAssertFalse(MenuBarGlyph.image(
            for: .active(sessionCount: 1), dot: .working).isTemplate)
        XCTAssertFalse(MenuBarGlyph.image(
            for: .active(sessionCount: 1), dot: .answerReady).isTemplate)
        XCTAssertTrue(MenuBarGlyph.image(
            for: .active(sessionCount: 1), dot: .none).isTemplate)
    }

    func testSessionDotColorsAreDistinctFromEachOtherAndFromMonochrome() throws {
        let plain = try bitmapData(for: .active(sessionCount: nil), dot: .none)
        let working = try bitmapData(for: .active(sessionCount: nil), dot: .working)
        let answerReady = try bitmapData(
            for: .active(sessionCount: nil), dot: .answerReady)

        XCTAssertNotEqual(working, answerReady)
        XCTAssertNotEqual(working, plain)
        XCTAssertNotEqual(answerReady, plain)
    }

    func testSessionDotAppearsOnDimmedAndOutlineShapes() throws {
        // The colored dot reports sessions independently of protection, so
        // "can sleep" and "unknown" shapes gain a dot only when colored.
        for icon in [MenuBarPresentation.Icon.canSleep, .unknown] {
            let plain = try bitmapData(for: icon, dot: .none)
            let working = try bitmapData(for: icon, dot: .working)
            XCTAssertNotEqual(plain, working)
        }
    }

    func testSessionDotColorsSurviveRendering() throws {
        // The green/orange fill must actually reach pixels, not only flip the
        // template flag.
        XCTAssertTrue(try contains(
            .working, in: MenuBarGlyph.image(
                for: .active(sessionCount: nil), dot: .working)))
        XCTAssertTrue(try contains(
            .answerReady, in: MenuBarGlyph.image(
                for: .active(sessionCount: nil), dot: .answerReady)))
    }

    private func contains(
        _ dot: MenuBarPresentation.SessionDot,
        in image: NSImage
    ) throws -> Bool {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y),
                      color.alphaComponent > 0.5 else { continue }
                let rgb = color.usingColorSpace(.deviceRGB)
                guard let rgb else { continue }
                switch dot {
                case .working:
                    if rgb.greenComponent > 0.5,
                       rgb.greenComponent > rgb.redComponent + 0.2,
                       rgb.greenComponent > rgb.blueComponent + 0.2 {
                        return true
                    }
                case .answerReady:
                    if rgb.redComponent > 0.7,
                       rgb.greenComponent > 0.3,
                       rgb.blueComponent < 0.3 {
                        return true
                    }
                case .none:
                    break
                }
            }
        }
        return false
    }

    private func bitmapData(
        for icon: MenuBarPresentation.Icon,
        dot: MenuBarPresentation.SessionDot = .none
    ) throws -> Data {
        let image = MenuBarGlyph.image(for: icon, dot: dot)
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
