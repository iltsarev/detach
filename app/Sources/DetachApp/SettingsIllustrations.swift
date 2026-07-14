import AppKit
import DetachKit
import SwiftUI

/// Colored rounded-square toolbar-tab icons, in the language of the
/// System Settings sidebar. Rendered once per symbol and cached.
@MainActor
enum SettingsTabIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(systemName: String, color: NSColor) -> NSImage {
        let key = "\(systemName)|\(color.description)"
        if let cached = cache[key] { return cached }
        // The toolbar scales the image to fill its fixed tab-icon slot, so the
        // plate is drawn inset within the canvas: the transparent margin is
        // what keeps neighboring tabs and the selection card from crowding it.
        let side: CGFloat = 24
        let plateInset: CGFloat = 2.5
        let image = NSImage(
            size: NSSize(width: side, height: side),
            flipped: false
        ) { rect in
            let plate = rect.insetBy(dx: plateInset, dy: plateInset)
            NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).addClip()
            color.setFill()
            plate.fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(
                systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                symbol.isTemplate = false
                let size = symbol.size
                symbol.draw(in: NSRect(
                    x: (rect.width - size.width) / 2,
                    y: (rect.height - size.height) / 2,
                    width: size.width,
                    height: size.height))
            }
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

/// Dot-plus-word component status, teal when healthy, orange otherwise.
struct StatusIndicator: View {
    let healthy: Bool

    private var color: Color { healthy ? Brand.teal : .orange }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(healthy ? L10n.string("Ready") : L10n.string("Needs attention"))
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A sample session-list row rendered with its own preview font environment.
struct SessionRowPreviewCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Brand.teal).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "my-project · claude")
                    .appFont(.body, weight: .semibold)
                Text(L10n.string("Answer ready · 2 min ago"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Text size preview"))
    }
}

/// Miniature terminal screenshot acting as one side of the tmux theme picker,
/// in the manner of the system Light/Dark appearance chooser.
struct TmuxThemeThumbnail: View {
    let title: String
    let statusText: String
    let detachStyled: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        line(width: 46, color: Color(red: 0.25, green: 0.56, blue: 0.37))
                        line(width: 62, color: Color(white: 0.52))
                        line(width: 40, color: Color(white: 0.28))
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusBar
                }
                .frame(width: 128, height: 76)
                .background(Color(red: 0.08, green: 0.085, blue: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1))
                Text(title)
                    .appFont(.caption, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func line(width: CGFloat, color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: 4)
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.system(size: 8, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 14)
        .background(detachStyled ? Brand.teal : Color(white: 0.2))
        .foregroundStyle(detachStyled ? Color.black.opacity(0.6) : Color.white.opacity(0.55))
    }
}

/// A miniature Mac display with a Detach banner arriving in the top-right
/// corner — shows where notifications will appear.
struct NotificationBannerIllustration: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.85, green: 0.89, blue: 0.97),
                    Color(red: 0.90, green: 0.86, blue: 0.95),
                    Color(red: 0.96, green: 0.89, blue: 0.85),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                menuBar
                HStack {
                    Spacer()
                    banner
                        .padding(.top, 8)
                        .padding(.trailing, 10)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var menuBar: some View {
        HStack(spacing: 5) {
            Capsule().fill(.white.opacity(0.7)).frame(width: 14, height: 3)
            Capsule().fill(.white.opacity(0.55)).frame(width: 8, height: 3)
            Capsule().fill(.white.opacity(0.55)).frame(width: 10, height: 3)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 12)
        .background(.white.opacity(0.3))
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Detach")
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.string("The agent replied in “my-project”"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.92)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        // The banner card stays light even in Dark Mode, so its text must
        // resolve against a light scheme or it becomes white-on-white.
        .environment(\.colorScheme, .light)
    }
}

/// Night sky, a crescent moon, and a closed MacBook lid: the Mac appears
/// asleep while Detach keeps the agent running.
struct NightSceneIllustration: View {
    private static let stars: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.2), CGPoint(x: 0.2, y: 0.55),
        CGPoint(x: 0.38, y: 0.14), CGPoint(x: 0.62, y: 0.24),
        CGPoint(x: 0.72, y: 0.66), CGPoint(x: 0.9, y: 0.6),
    ]

    private let skyBottom = Color(red: 0.21, green: 0.24, blue: 0.42)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.13, green: 0.15, blue: 0.29), skyBottom],
                    startPoint: .top, endPoint: .bottom)
                ForEach(Array(Self.stars.enumerated()), id: \.offset) { star in
                    Circle()
                        .fill(.white.opacity(0.8))
                        .frame(width: 2, height: 2)
                        .position(
                            x: star.element.x * size.width,
                            y: star.element.y * size.height)
                }
                moon.position(x: size.width * 0.85, y: size.height * 0.3)
                Text(verbatim: "z z z")
                    .font(.system(size: 11, weight: .bold))
                    .italic()
                    .foregroundStyle(Color(red: 0.67, green: 0.7, blue: 0.87))
                    .position(x: size.width * 0.62, y: size.height * 0.34)
                lid.position(x: size.width / 2, y: size.height - 16)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var moon: some View {
        ZStack {
            Circle().fill(Color(red: 0.96, green: 0.95, blue: 0.87))
            Circle().fill(skyBottom).offset(x: -6, y: 3)
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
    }

    private var lid: some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                .fill(Color(red: 0.64, green: 0.68, blue: 0.79))
                .frame(width: 84, height: 3)
            UnevenRoundedRectangle(
                topLeadingRadius: 2, bottomLeadingRadius: 5,
                bottomTrailingRadius: 5, topTrailingRadius: 2)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.72, green: 0.76, blue: 0.86),
                        Color(red: 0.55, green: 0.59, blue: 0.72),
                    ],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 100, height: 7)
        }
    }
}
