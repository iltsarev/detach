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
