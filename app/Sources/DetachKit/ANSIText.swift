import AppKit

/// Converts terminal output with ANSI SGR escape sequences (tmux capture-pane -e)
/// into an NSAttributedString. Non-SGR CSI sequences and OSC sequences are stripped.
public enum ANSIParser {
    /// Default canvas for callers that do not select an appearance.
    public static let terminalBackground = TerminalPalette.dark.background

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
        defaultBackground: NSColor = ANSIParser.terminalBackground,
        ansiColors: [NSColor] = TerminalPalette.dark.ansiColors
    ) -> NSAttributedString {
        precondition(ansiColors.count == 16)
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
                            apply(params, state: &state, colors: ansiColors)
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

    private static func apply(_ params: String, state: inout SGRState, colors: [NSColor]) {
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
            case 30...37: state.fg = colors[codes[i] - 30]
            case 90...97: state.fg = colors[codes[i] - 90 + 8]
            case 39: state.fg = nil
            case 40...47: state.bg = colors[codes[i] - 40]
            case 100...107: state.bg = colors[codes[i] - 100 + 8]
            case 49: state.bg = nil
            case 38, 48:
                let isForeground = codes[i] == 38
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    let color = xterm(codes[i + 2], colors: colors)
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

    static func xterm(
        _ n: Int, colors: [NSColor] = TerminalPalette.dark.ansiColors
    ) -> NSColor {
        switch n {
        case 0...15: return colors[n]
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
