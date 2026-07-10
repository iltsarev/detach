import XCTest
import AppKit
@testable import DetachKit

final class ANSIParserTests: XCTestCase {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    let defaultColor = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)

    func parse(_ raw: String) -> NSAttributedString {
        ANSIParser.parse(raw, font: font, boldFont: boldFont, defaultColor: defaultColor)
    }

    func colorRuns(_ attributed: NSAttributedString) -> [NSColor] {
        var out: [NSColor] = []
        attributed.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            out.append(value as! NSColor)
        }
        return out
    }

    func fontRuns(_ attributed: NSAttributedString) -> [NSFont] {
        var out: [NSFont] = []
        attributed.enumerateAttribute(
            .font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            out.append(value as! NSFont)
        }
        return out
    }

    func testPlainTextPassesThrough() {
        let result = parse("hello world")
        XCTAssertEqual(result.string, "hello world")
        XCTAssertEqual(colorRuns(result), [defaultColor])
    }

    func testBasicColorAndReset() {
        let result = parse("a \u{1B}[32mgreen\u{1B}[0m b")
        XCTAssertEqual(result.string, "a green b")
        let runs = colorRuns(result)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0], defaultColor)
        XCTAssertNotEqual(runs[1], defaultColor)
        XCTAssertEqual(runs[2], defaultColor)
    }

    func testXterm256AndTruecolor() {
        let result = parse("\u{1B}[38;5;196mred\u{1B}[38;2;10;20;30mrgb")
        XCTAssertEqual(result.string, "redrgb")
        let runs = colorRuns(result)
        XCTAssertEqual(runs.count, 2)
        XCTAssertNotEqual(runs[0], defaultColor)
        XCTAssertNotEqual(runs[1], defaultColor)
        XCTAssertNotEqual(runs[0], runs[1])
    }

    func testBoldTracksOnOff() {
        let result = parse("\u{1B}[1mbold\u{1B}[22m normal")
        let runs = fontRuns(result)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0], boldFont)
        XCTAssertEqual(runs[1], font)
    }

    func testNonSGRSequencesAreStripped() {
        // Cursor movement CSI, OSC title sequence, and a bare two-byte escape.
        let raw = "\u{1B}[2Ka\u{1B}]0;title\u{07}b\u{1B}Mc"
        XCTAssertEqual(parse(raw).string, "abc")
    }

    func testUnterminatedEscapeDoesNotCrash() {
        XCTAssertEqual(parse("x\u{1B}[38;5").string, "x")
        XCTAssertEqual(parse("x\u{1B}").string, "x")
    }

    func testXtermPaletteBounds() {
        _ = ANSIParser.xterm(0)
        _ = ANSIParser.xterm(15)
        _ = ANSIParser.xterm(16)
        _ = ANSIParser.xterm(231)
        _ = ANSIParser.xterm(232)
        _ = ANSIParser.xterm(255)
        _ = ANSIParser.xterm(999)
    }
}
