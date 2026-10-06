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

/// Status colors retain contrast on both light and dark sidebar surfaces.
enum SessionPalette {
    static let attention = adaptive(light: 0x986700, dark: 0xE8BE58)
    static let ready = adaptive(light: 0x287C4B, dark: 0x6DCA91)
    static let error = adaptive(light: 0xBD3B42, dark: 0xF28B82)
    static let secondary = adaptive(light: 0x565D65, dark: 0xADB1B8)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

enum SessionIdentity {
    static func color(_ color: SessionColor) -> Color {
        Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255)
    }

    /// One status color shared by the sidebar symbols and the detail status pill.
    static func statusColor(for session: Session) -> Color {
        switch session.statusSignal {
        case .working, .inputRequired: return SessionPalette.attention
        case .ready: return SessionPalette.ready
        case .error: return SessionPalette.error
        case .stopped, .waiting, .unknown, .recoverable: return SessionPalette.secondary
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
        case .starting, .running, .recovering, .hung, .failed:
            1
        }
    }
}

enum SessionDetailSignalPresentation {
    static let identityMarkerWidth: CGFloat = 4
    static let identityMarkerHeight: CGFloat = 24

    /// These strengths match the dense, muted-edge, and faint tmux blends.
    static func identityTintPercent(for status: EffectiveStatus) -> UInt8 {
        switch status {
        case .completed, .stopped, .interrupted:
            25
        case .recoverable, .orphaned, .corrupt, .collision, .unknown:
            45
        case .starting, .running, .recovering, .hung, .failed:
            55
        }
    }

    static func powerColor(for state: PowerProtectionState?) -> Color {
        switch state ?? .unknown {
        case .protected:
            Brand.teal
        case .transitioning, .lowBattery, .temperature:
            .orange
        case .unavailable:
            .red
        case .allowed, .unknown:
            Color.white.opacity(0.70)
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
