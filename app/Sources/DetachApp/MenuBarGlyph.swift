import AppKit

/// The Detach prompt mark (chevron + underscore, echoing the app icon) as the
/// status-item image. State is encoded by shape first: solid glyph with a
/// filled dot = the Mac is held awake, dimmed glyph = it can sleep, an "!"
/// badge = needs attention, outline = unknown. Active sessions additionally
/// tint the dot — green while working, orange when a session waits for a
/// reply — color is a secondary channel on top of the shape language.
enum MenuBarGlyph {
    static func image(
        for icon: MenuBarPresentation.Icon,
        dot: MenuBarPresentation.SessionDot
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(icon, dot: dot)
            return true
        }
        // Template rendering only while the glyph is monochrome. A colored
        // session dot needs real color, so those states draw the mark in
        // labelColor inside the block, which resolves against the menu bar's
        // appearance each time the image is composited.
        image.isTemplate = sessionDotColor(dot) == nil
        image.accessibilityDescription = nil
        return image
    }

    private static func sessionDotColor(
        _ dot: MenuBarPresentation.SessionDot
    ) -> NSColor? {
        switch dot {
        case .none: nil
        case .working: .systemGreen
        case .answerReady: .systemOrange
        }
    }

    private static func draw(
        _ icon: MenuBarPresentation.Icon,
        dot: MenuBarPresentation.SessionDot
    ) {
        let sessionColor = sessionDotColor(dot)
        let ink: NSColor = sessionColor == nil ? .black : .labelColor
        switch icon {
        case .active:
            drawPrompt(ink: ink, alpha: 1, outline: false)
            // The dot sits where the app icon detaches its window.
            drawDot(fill: sessionColor ?? ink)
        case .canSleep:
            drawPrompt(ink: ink, alpha: 0.5, outline: false)
            // Shape stays "dimmed = can sleep"; the colored dot only reports
            // running sessions, not protection.
            if let sessionColor { drawDot(fill: sessionColor) }
        case .lowBattery, .attention:
            // The badge owns the corner; the presentation suppresses the
            // session dot for these states so the warning stays unambiguous.
            drawPrompt(ink: ink, alpha: 1, outline: false)
            drawBang(ink: ink)
        case .unknown:
            drawPrompt(ink: ink, alpha: 0.9, outline: true)
            if let sessionColor { drawDot(fill: sessionColor) }
        }
    }

    private static func drawDot(fill: NSColor) {
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12.2, y: 11.2, width: 4.6, height: 4.6)).fill()
    }

    private static func drawPrompt(ink: NSColor, alpha: CGFloat, outline: Bool) {
        let ink = ink.withAlphaComponent(alpha)

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: 3.2, y: 13.2))
        chevron.line(to: NSPoint(x: 8.8, y: 8.6))
        chevron.line(to: NSPoint(x: 3.2, y: 4.0))
        chevron.lineWidth = outline ? 1.3 : 2.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        ink.setStroke()
        chevron.stroke()

        let bar = NSBezierPath(
            roundedRect: NSRect(x: 10.6, y: 3.4, width: 5.2, height: 2.4),
            xRadius: 1.2, yRadius: 1.2)
        if outline {
            bar.lineWidth = 1.1
            bar.stroke()
        } else {
            ink.setFill()
            bar.fill()
        }
    }

    private static func drawBang(ink: NSColor) {
        ink.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 13.6, y: 10.6, width: 1.9, height: 5.0),
            xRadius: 0.95, yRadius: 0.95).fill()
        NSBezierPath(ovalIn: NSRect(x: 13.55, y: 8.2, width: 2.0, height: 2.0)).fill()
    }
}
