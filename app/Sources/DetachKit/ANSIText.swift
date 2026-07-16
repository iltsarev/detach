import AppKit

/// Converts terminal output with ANSI SGR escape sequences (tmux capture-pane -e)
/// into an NSAttributedString. Non-SGR CSI sequences and OSC sequences are stripped.
public enum ANSIParser {
    /// The dark canvas every terminal preview draws on; reverse video swaps
    /// against it so highlights survive outside a real terminal.
    public static let terminalBackground = NSColor(
        srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)

    private struct SGRState {
        var fg: NSColor?
        var bg: NSColor?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var reverse = false
        var strikethrough = false
    }

    public static func parse(
        _ raw: String,
        font: NSFont,
        boldFont: NSFont,
        defaultColor: NSColor,
        defaultBackground: NSColor = ANSIParser.terminalBackground
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var state = SGRState()
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var foreground = state.fg ?? defaultColor
            var background = state.bg
            if state.reverse {
                background = state.fg ?? defaultColor
                foreground = state.bg ?? defaultBackground
            }
            if state.dim { foreground = foreground.withAlphaComponent(0.55) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: state.bold ? boldFont : font,
                .foregroundColor: foreground,
            ]
            if let background { attributes[.backgroundColor] = background }
            if state.italic { attributes[.obliqueness] = 0.18 }
            if state.underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if state.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: buffer, attributes: attributes))
            buffer = ""
        }

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\u{1B}" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else { break }
                if raw[next] == "[" {
                    // CSI sequence: parameters, then one final byte in @...~
                    var scan = raw.index(after: next)
                    var params = ""
                    while scan < raw.endIndex, !("@"..."~" ~= raw[scan]) {
                        params.append(raw[scan])
                        scan = raw.index(after: scan)
                    }
                    if scan < raw.endIndex {
                        if raw[scan] == "m" {
                            flush()
                            apply(params, state: &state)
                        }
                        index = raw.index(after: scan)
                    } else {
                        index = scan
                    }
                    continue
                }
                if raw[next] == "]" {
                    // OSC sequence: swallow until BEL or ESC \
                    var scan = raw.index(after: next)
                    while scan < raw.endIndex {
                        if raw[scan] == "\u{07}" { scan = raw.index(after: scan); break }
                        if raw[scan] == "\u{1B}" {
                            scan = raw.index(after: scan)
                            if scan < raw.endIndex { scan = raw.index(after: scan) }
                            break
                        }
                        scan = raw.index(after: scan)
                    }
                    index = scan
                    continue
                }
                // Other two-character escape: skip both.
                index = raw.index(after: next)
                continue
            }
            buffer.append(character)
            index = raw.index(after: index)
        }
        flush()
        return result
    }

    private static func apply(_ params: String, state: inout SGRState) {
        var codes = params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var i = 0
        while i < codes.count {
            switch codes[i] {
            case 0: state = SGRState()
            case 1: state.bold = true
            case 2: state.dim = true
            case 3: state.italic = true
            case 4: state.underline = true
            case 7: state.reverse = true
            case 9: state.strikethrough = true
            case 22: state.bold = false; state.dim = false
            case 23: state.italic = false
            case 24: state.underline = false
            case 27: state.reverse = false
            case 29: state.strikethrough = false
            case 30...37: state.fg = basic[codes[i] - 30]
            case 90...97: state.fg = bright[codes[i] - 90]
            case 39: state.fg = nil
            case 40...47: state.bg = basic[codes[i] - 40]
            case 100...107: state.bg = bright[codes[i] - 100]
            case 49: state.bg = nil
            case 38, 48:
                let isForeground = codes[i] == 38
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    let color = xterm(codes[i + 2])
                    if isForeground { state.fg = color } else { state.bg = color }
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    let color = NSColor(srgbRed: CGFloat(codes[i + 2]) / 255,
                                        green: CGFloat(codes[i + 3]) / 255,
                                        blue: CGFloat(codes[i + 4]) / 255, alpha: 1)
                    if isForeground { state.fg = color } else { state.bg = color }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    // Palette tuned for a dark background.
    private static let basic: [NSColor] = [
        NSColor(srgbRed: 0.45, green: 0.47, blue: 0.51, alpha: 1), // black → visible gray
        NSColor(srgbRed: 0.93, green: 0.42, blue: 0.41, alpha: 1), // red
        NSColor(srgbRed: 0.36, green: 0.80, blue: 0.47, alpha: 1), // green
        NSColor(srgbRed: 0.87, green: 0.75, blue: 0.35, alpha: 1), // yellow
        NSColor(srgbRed: 0.39, green: 0.60, blue: 0.94, alpha: 1), // blue
        NSColor(srgbRed: 0.78, green: 0.49, blue: 0.87, alpha: 1), // magenta
        NSColor(srgbRed: 0.32, green: 0.78, blue: 0.78, alpha: 1), // cyan
        NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1), // white
    ]

    private static let bright: [NSColor] = [
        NSColor(srgbRed: 0.58, green: 0.60, blue: 0.64, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.50, green: 0.91, blue: 0.60, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.86, blue: 0.49, alpha: 1),
        NSColor(srgbRed: 0.54, green: 0.72, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.88, green: 0.62, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.47, green: 0.90, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1),
    ]

    static func xterm(_ n: Int) -> NSColor {
        switch n {
        case 0...7: return basic[n]
        case 8...15: return bright[n - 8]
        case 16...231:
            let value = n - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(srgbRed: levels[value / 36] / 255,
                           green: levels[(value % 36) / 6] / 255,
                           blue: levels[value % 6] / 255, alpha: 1)
        case 232...255:
            let gray = CGFloat(8 + 10 * (n - 232)) / 255
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        default:
            return .textColor
        }
    }
}
