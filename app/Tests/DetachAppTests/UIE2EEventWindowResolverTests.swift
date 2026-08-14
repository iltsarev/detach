import AppKit
import XCTest
@testable import DetachApp

@MainActor
final class UIE2EEventWindowResolverTests: XCTestCase {
    func testViewResolvesItsOwningWindowWhenWindowsOverlap() {
        let behind = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let owner = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 40, height: 20))
        owner.contentView?.addSubview(view)
        let point = NSPoint(x: owner.frame.midX, y: owner.frame.midY)

        XCTAssertTrue(behind.frame.intersects(owner.frame))
        XCTAssertIdentical(UIE2EEventWindowResolver.owner(of: view), owner)
        XCTAssertIdentical(
            UIE2EEventWindowResolver.resolve(
                owningWindow: UIE2EEventWindowResolver.owner(of: view),
                at: point,
                candidates: [behind, owner]),
            owner)
    }

    func testDetachedViewHasNoOwningWindow() {
        let view = NSView(frame: .zero)
        let candidate = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let point = NSPoint(x: candidate.frame.midX, y: candidate.frame.midY)

        XCTAssertNil(UIE2EEventWindowResolver.owner(of: view))
        XCTAssertIdentical(
            UIE2EEventWindowResolver.resolve(
                owningWindow: nil,
                at: point,
                candidates: [candidate]),
            candidate)
    }

    func testAttachedSheetWinsOverItsAccessibilityOwner() {
        let owner = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let sheet = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 200, height: 200),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        owner.beginSheet(sheet)
        defer { owner.endSheet(sheet) }
        let point = NSPoint(x: sheet.frame.midX, y: sheet.frame.midY)

        XCTAssertTrue(owner.frame.contains(point))
        XCTAssertIdentical(sheet.sheetParent, owner)
        XCTAssertIdentical(
            UIE2EEventWindowResolver.resolve(
                owningWindow: owner,
                at: point,
                candidates: [sheet, owner]),
            sheet)
    }

    func testClippedControlUsesTheRealScrollerTrackTowardIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: .titled,
            backing: .buffered,
            defer: false)
        let scrollView = NSScrollView(
            frame: NSRect(x: 20, y: 20, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 600))
        let measuredView = NSView(
            frame: NSRect(x: 20, y: 560, width: 100, height: 24))
        documentView.addSubview(measuredView)
        scrollView.documentView = documentView
        window.contentView?.addSubview(scrollView)
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let viewport = try XCTUnwrap(UIE2EEventWindowResolver.screenFrame(
            scrollView.contentView.bounds,
            in: scrollView.contentView))
        let clippedControl = CGRect(
            x: viewport.midX - 50,
            y: viewport.minY - 14,
            width: 100,
            height: 24)

        XCTAssertFalse(UIE2EEventWindowResolver.isSafelyVisible(
            clippedControl,
            from: measuredView))
        let pageFrame = try XCTUnwrap(UIE2EEventWindowResolver.scrollPageFrame(
            toward: clippedControl,
            from: measuredView))
        let scroller = try XCTUnwrap(scrollView.verticalScroller)
        let scrollerFrame = try XCTUnwrap(UIE2EEventWindowResolver.screenFrame(
            scroller.bounds,
            in: scroller))
        XCTAssertTrue(scrollerFrame.contains(CGPoint(
            x: pageFrame.midX,
            y: pageFrame.midY)))
        XCTAssertLessThan(pageFrame.midY, viewport.midY)

        let visibleControl = CGRect(
            x: viewport.midX - 50,
            y: viewport.midY - 12,
            width: 100,
            height: 24)
        XCTAssertTrue(UIE2EEventWindowResolver.isSafelyVisible(
            visibleControl,
            from: measuredView))
        XCTAssertNil(UIE2EEventWindowResolver.scrollPageFrame(
            toward: visibleControl,
            from: measuredView))
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
