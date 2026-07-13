import SwiftUI
import DetachKit

/// Brand palette — matches the app icon (white plate, teal → indigo → coral).
enum Brand {
    static let teal = Color(red: 0.05, green: 0.72, blue: 0.62)
    static let indigo = Color(red: 0.33, green: 0.36, blue: 0.88)
    static let coral = Color(red: 1.00, green: 0.45, blue: 0.30)

    static let gradient = LinearGradient(
        colors: [teal, indigo, coral],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func tint(for provider: Provider) -> Color {
        switch provider {
        case .codex: teal
        case .claude: coral
        }
    }
}

enum SessionIdentity {
    static func color(_ color: SessionColor) -> Color {
        Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255)
    }

    /// Finished sessions keep their identity hue while receding behind active
    /// work. Failure remains prominent through the separate red status marker.
    static func emphasis(for status: EffectiveStatus) -> Double {
        switch status {
        case .completed, .stopped, .interrupted:
            0.52
        case .recoverable, .orphaned, .corrupt, .collision, .unknown:
            0.72
        case .starting, .running, .recovering, .failed:
            1
        }
    }
}

struct TmuxSessionColorBadge: View {
    let session: Session

    var body: some View {
        if let sessionColor = session.sessionColor {
            let color = SessionIdentity.color(sessionColor)
            let emphasis = SessionIdentity.emphasis(for: session.effectiveStatus)
            HStack(spacing: 5) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(color.opacity(emphasis))
                Text("tmux")
                    .foregroundStyle(.secondary)
            }
            .appFont(.caption2, weight: .semibold)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12 * emphasis)))
            .overlay(Capsule().strokeBorder(color.opacity(0.32 * emphasis)))
            .help(L10n.format("Session base color: %@", sessionColor.hex))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("Session identity color"))
            .accessibilityValue(sessionColor.hex)
        }
    }
}
