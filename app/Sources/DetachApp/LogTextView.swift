import SwiftUI
import AppKit
import DetachKit

/// Non-wrapping NSTextView-backed log view: text is laid out once per content
/// update, so window resizes stay cheap even with thousands of styled runs.
struct LogTextView: NSViewRepresentable {
    @Environment(\.appFontPointSize) private var fontPointSize
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView()
        Self.apply(
            text: text,
            pointSize: fontPointSize,
            to: scrollView,
            coordinator: context.coordinator)
        return scrollView
    }

    static func makeScrollView() -> NSScrollView {
        let scrollView = LogScrollView()
        scrollView.setAccessibilityIdentifier("session-preview-log")
        let textView = NSTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        scrollView.documentView = textView
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
        Self.apply(
            text: text,
            pointSize: fontPointSize,
            to: scrollView,
            coordinator: context.coordinator)
    }

    static func apply(
        text: NSAttributedString,
        pointSize: CGFloat,
        to scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        // Identity check keeps resize frames free of O(n) text work.
        guard coordinator.lastText !== text
                || coordinator.lastFontPointSize != pointSize else { return }
        coordinator.lastText = text
        coordinator.lastFontPointSize = pointSize

        // Terminal semantics: pinned to the bottom → follow the tail;
        // scrolled up → keep the current offset (both axes). The tail intent
        // comes from the user's last scroll, not from geometry: text applied
        // before the first layout sees a zero-height viewport.
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let oldHeight = textView.frame.height
        let logScrollView = scrollView as? LogScrollView
        let wasAtBottom = logScrollView?.followsTail
            ?? (oldHeight <= visible.height + 1 || visible.maxY >= oldHeight - 5)

        storage.setAttributedString(Self.resizedText(text, to: pointSize))
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

/// Scroll view that keeps showing the end of the log across layout passes
/// until the user scrolls away, like a terminal. SwiftUI can apply cached text
/// before the view has a size; `tile()` then restores the tail once it does.
final class LogScrollView: NSScrollView {
    private(set) var followsTail = true
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Only user scrolling (wheel, trackpad, scroller) changes the intent;
        // window resizes and text updates do not.
        for name in [NSScrollView.didLiveScrollNotification,
                     NSScrollView.didEndLiveScrollNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: self, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTailIntent() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func tile() {
        super.tile()
        if followsTail { scrollToTail() }
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateTailIntent()
    }

    func scrollToTail() {
        guard let document = documentView else { return }
        let clip = contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        guard abs(clip.bounds.origin.y - maxY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: maxY))
        reflectScrolledClipView(clip)
    }

    private func updateTailIntent() {
        guard let document = documentView else { return }
        let visible = contentView.bounds
        followsTail = document.frame.height <= visible.height + 1
            || visible.maxY >= document.frame.height - 5
    }
}
