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

    /// One status color shared by the sidebar dots and the detail status pill.
    static func statusColor(for session: Session) -> Color {
        if session.isWaitingForUser { return .orange }
        switch session.effectiveStatus {
        case .running, .starting, .recovering: return Brand.teal
        case .completed, .stopped: return .secondary.opacity(0.6)
        case .failed, .interrupted: return .red
        case .recoverable, .orphaned, .corrupt, .collision, .unknown: return .orange
        }
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

/// Small circle carrying the three brand colors; used as a discreet signature.
struct TriColorDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(AngularGradient(
                colors: [Brand.teal, Brand.indigo, Brand.coral, Brand.teal],
                center: .center))
            .frame(width: size, height: size)
    }
}
