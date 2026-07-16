import AppKit

/// The Detach prompt mark (chevron + underscore, echoing the app icon) as a
/// template image for the status item. State is encoded by shape, never by
/// color alone: solid glyph with a filled dot = the Mac is held awake, dimmed
/// glyph = it can sleep, an "!" badge = needs attention, outline = unknown.
enum MenuBarGlyph {
    static func image(for icon: MenuBarPresentation.Icon) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(icon)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = nil
        return image
    }

    private static func draw(_ icon: MenuBarPresentation.Icon) {
        switch icon {
        case .active:
            drawPrompt(alpha: 1, outline: false)
            // The filled dot sits where the app icon detaches its window.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12.2, y: 11.2, width: 4.6, height: 4.6)).fill()
        case .canSleep:
            drawPrompt(alpha: 0.5, outline: false)
        case .lowBattery, .attention:
            drawPrompt(alpha: 1, outline: false)
            drawBang()
        case .unknown:
            drawPrompt(alpha: 0.9, outline: true)
        }
    }

    private static func drawPrompt(alpha: CGFloat, outline: Bool) {
        let ink = NSColor.black.withAlphaComponent(alpha)

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

    private static func drawBang() {
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 13.6, y: 10.6, width: 1.9, height: 5.0),
            xRadius: 0.95, yRadius: 0.95).fill()
        NSBezierPath(ovalIn: NSRect(x: 13.55, y: 8.2, width: 2.0, height: 2.0)).fill()
    }
}
