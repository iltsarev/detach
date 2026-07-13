import AppKit
import XCTest
@testable import DetachApp

final class TextSizeTests: XCTestCase {
    func testDefaultIsOnePointAboveTheNativeMacBodySize() {
        XCTAssertEqual(AppFontSize.defaultValue, 14)
        XCTAssertTrue(AppFontSize.allowedRange.contains(AppFontSize.defaultValue))
    }

    func testPointSizeIsRoundedAndClampedToSupportedRange() {
        XCTAssertEqual(AppFontSize.clamped(14.4), 14)
        XCTAssertEqual(AppFontSize.clamped(14.6), 15)
        XCTAssertEqual(AppFontSize.clamped(1), AppFontSize.allowedRange.lowerBound)
        XCTAssertEqual(AppFontSize.clamped(100), AppFontSize.allowedRange.upperBound)
    }

    func testSemanticRolesScaleFromNumericBaseSize() {
        let small = AppFontRole.caption.pointSize(base: 13)
        let body = AppFontRole.body.pointSize(base: 13)
        let title = AppFontRole.title2.pointSize(base: 13)

        XCTAssertLessThan(small, body)
        XCTAssertGreaterThan(title, body)
        XCTAssertEqual(AppFontRole.body.pointSize(base: 18), 18)
    }

    func testLargerPointSizeIncreasesMinimumLayouts() {
        let standard = AppFontSize.minimumWindowSize(for: AppFontSize.defaultValue)
        let large = AppFontSize.minimumWindowSize(for: 20)

        XCTAssertGreaterThan(large.width, standard.width)
        XCTAssertGreaterThan(large.height, standard.height)
        XCTAssertGreaterThan(
            AppFontSize.settingsWidth(for: 20),
            AppFontSize.settingsWidth(for: AppFontSize.defaultValue))
        XCTAssertLessThanOrEqual(AppFontSize.minimumWindowSize(for: 22).width, 840)
        XCTAssertGreaterThan(AppFontSize.settingsIdealHeight, AppFontSize.settingsMinimumHeight)
    }

    func testLogResizeUsesExactPointSizeAndPreservesTraitsAndColors() throws {
        let regular = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let color = NSColor.systemGreen
        let source = NSMutableAttributedString(
            string: "plain bold",
            attributes: [.font: regular, .foregroundColor: color])
        source.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))

        let result = LogTextView.resizedText(source, to: 17)
        let plainFont = try XCTUnwrap(
            result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let boldFont = try XCTUnwrap(
            result.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)

        XCTAssertEqual(plainFont.pointSize, 17, accuracy: 0.001)
        XCTAssertEqual(boldFont.pointSize, 17, accuracy: 0.001)
        XCTAssertFalse(NSFontManager.shared.traits(of: plainFont).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        XCTAssertEqual(
            result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            color)
        XCTAssertEqual(regular.pointSize, 10, accuracy: 0.001)
    }

    func testInvalidLogPointSizeKeepsAttributedStringIdentity() {
        let source = NSAttributedString(string: "log")
        XCTAssertTrue(LogTextView.resizedText(source, to: 0) === source)
    }
}
