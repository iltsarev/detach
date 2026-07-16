import SwiftUI
import AppKit
import DetachKit

/// Non-wrapping NSTextView-backed log view: text is laid out once per content
/// update, so window resizes stay cheap even with thousands of styled runs.
struct LogTextView: NSViewRepresentable {
    @Environment(\.appFontPointSize) private var fontPointSize
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = ANSIParser.terminalBackground
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = textView.backgroundColor
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastText: NSAttributedString?
        var lastFontPointSize: CGFloat?
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        // Identity check keeps resize frames free of O(n) text work.
        guard context.coordinator.lastText !== text
                || context.coordinator.lastFontPointSize != fontPointSize else { return }
        context.coordinator.lastText = text
        context.coordinator.lastFontPointSize = fontPointSize

        // Terminal semantics: pinned to the bottom → follow the tail;
        // scrolled up → keep the current offset (both axes).
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let oldHeight = textView.frame.height
        let wasAtBottom = oldHeight <= visible.height + 1 || visible.maxY >= oldHeight - 5

        storage.setAttributedString(Self.resizedText(text, to: fontPointSize))
        // Force layout so the new document height is real before we scroll.
        layoutManager.ensureLayout(for: container)
        textView.sizeToFit()
        let newHeight = textView.frame.height

        let maxY = max(0, newHeight - visible.height)
        let targetY = wasAtBottom ? maxY : min(visible.origin.y, maxY)
        clipView.scroll(to: NSPoint(x: visible.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Scales fonts while leaving ANSI-derived colors and other attributes
    /// untouched. Kept separate from layout so the behavior is unit-testable.
    static func resizedText(
        _ text: NSAttributedString,
        to pointSize: CGFloat
    ) -> NSAttributedString {
        guard pointSize > 0 else { return text }

        let scaled = NSMutableAttributedString(attributedString: text)
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let font = value as? NSFont,
                  let resized = NSFont(
                    descriptor: font.fontDescriptor,
                    size: pointSize) else { return }
            scaled.addAttribute(.font, value: resized, range: range)
        }
        return scaled
    }
}
