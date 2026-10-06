import AppKit

/// Concrete terminal colors, independent of the application appearance.
public enum TerminalPalette: Equatable {
    case light
    case dark

    public var appearance: NSAppearance {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)!
    }

    public var background: NSColor {
        self == .dark
            ? NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    }

    public var foreground: NSColor {
        NSColor(white: self == .dark ? 0.85 : 0.12, alpha: 1)
    }

    public var selection: NSColor {
        self == .dark
            ? NSColor(srgbRed: 0.22, green: 0.30, blue: 0.44, alpha: 1)
            : NSColor(srgbRed: 0.73, green: 0.83, blue: 0.97, alpha: 1)
    }

    public var ansiColors: [NSColor] {
        self == .dark ? Self.darkBasic + Self.darkBright : Self.lightColors
    }

    // The log cache retains these semantic colors. The visible view resolves
    // them in its own appearance, including reverse video and dim text.
    public static let adaptiveForeground = adaptive { $0.foreground }
    public static let adaptiveBackground = adaptive { $0.background }
    public static let adaptiveANSIColors = (0..<16).map { index in
        adaptive { $0.ansiColors[index] }
    }

    private static func adaptive(_ color: @escaping (TerminalPalette) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
        }
    }

    private static let lightColors: [NSColor] = [
        color(0x24292f), color(0xa32025), color(0x246c2c), color(0x755600),
        color(0x2059b0), color(0x803b95), color(0x12676c), color(0x5c6066),
        color(0x626870), color(0xb52b31), color(0x267533), color(0x806000),
        color(0x2866c0), color(0x9046a5), color(0x16777c), color(0x717780),
    ]

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    // Palette tuned for a dark background.
    private static let darkBasic: [NSColor] = [
        NSColor(srgbRed: 0.45, green: 0.47, blue: 0.51, alpha: 1), // black → visible gray
        NSColor(srgbRed: 0.93, green: 0.42, blue: 0.41, alpha: 1), // red
        NSColor(srgbRed: 0.36, green: 0.80, blue: 0.47, alpha: 1), // green
        NSColor(srgbRed: 0.87, green: 0.75, blue: 0.35, alpha: 1), // yellow
        NSColor(srgbRed: 0.39, green: 0.60, blue: 0.94, alpha: 1), // blue
        NSColor(srgbRed: 0.78, green: 0.49, blue: 0.87, alpha: 1), // magenta
        NSColor(srgbRed: 0.32, green: 0.78, blue: 0.78, alpha: 1), // cyan
        NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1), // white
    ]

    private static let darkBright: [NSColor] = [
        NSColor(srgbRed: 0.58, green: 0.60, blue: 0.64, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.50, green: 0.91, blue: 0.60, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.86, blue: 0.49, alpha: 1),
        NSColor(srgbRed: 0.54, green: 0.72, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.88, green: 0.62, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.47, green: 0.90, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1),
    ]

}
