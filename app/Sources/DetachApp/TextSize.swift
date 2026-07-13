import SwiftUI

/// One numeric base size, in points, drives both SwiftUI text and terminal logs.
enum AppFontSize {
    static let storageKey = "fontPointSize"
    /// The native macOS body size is 13 pt; Detach starts just one point
    /// larger while keeping the familiar density of the previous interface.
    static let defaultValue = 14.0
    static let allowedRange = 11.0...22.0

    static func clamped(_ value: Double) -> Double {
        min(max(value.rounded(), allowedRange.lowerBound), allowedRange.upperBound)
    }

    static func minimumWindowSize(for value: Double) -> CGSize {
        let growth = max(0, clamped(value) - defaultValue)
        // Let content wrap before growing the minimum aggressively. This keeps
        // the window usable on small displays and macOS' "Larger Text" modes.
        return CGSize(width: 760 + growth * 8, height: 440 + growth * 8)
    }

    static func settingsWidth(for value: Double) -> CGFloat {
        let growth = max(0, clamped(value) - defaultValue)
        return 560 + growth * 25
    }

    /// Settings scrolls vertically, so its minimum must remain usable even on
    /// a smaller display instead of growing with the font size.
    static let settingsMinimumHeight: CGFloat = 460
    static let settingsIdealHeight: CGFloat = 680
}

enum AppFontRole {
    case caption2
    case caption
    case body
    case headline
    case title3
    case title2
    case heroIcon

    func pointSize(base: CGFloat) -> CGFloat {
        switch self {
        case .caption2: max(8, base * 0.75)
        case .caption: max(9, base * 0.85)
        case .body: base
        case .headline: base * 1.08
        case .title3: base * 1.25
        case .title2: base * 1.5
        case .heroIcon: base * 3.2
        }
    }
}

private struct AppFontPointSizeKey: EnvironmentKey {
    static let defaultValue = CGFloat(AppFontSize.defaultValue)
}

extension EnvironmentValues {
    var appFontPointSize: CGFloat {
        get { self[AppFontPointSizeKey.self] }
        set { self[AppFontPointSizeKey.self] = newValue }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appFontPointSize) private var baseSize
    let role: AppFontRole
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(
            size: role.pointSize(base: baseSize),
            weight: weight,
            design: design))
    }
}

extension View {
    /// Applies the exact persisted point size as the interface's body font.
    func appFontSize(_ value: Double) -> some View {
        let pointSize = CGFloat(AppFontSize.clamped(value))
        return environment(\.appFontPointSize, pointSize)
            .environment(\.font, .system(size: pointSize))
    }

    func appFont(
        _ role: AppFontRole,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(AppFontModifier(role: role, weight: weight, design: design))
    }
}
