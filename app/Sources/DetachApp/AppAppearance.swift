import AppKit
import DetachKit

/// The app-wide Light/Dark choice. `system` leaves `NSApp.appearance` unset,
/// so every window, sheet, panel, and menu follows macOS. Terminal surfaces
/// have a separate appearance preference.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"
    static let defaultValue = AppAppearance.system

    var id: String { rawValue }

    /// An unknown or damaged stored value falls back to the system appearance.
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    var title: String {
        switch self {
        case .system: L10n.string("Match System")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    @MainActor
    func apply(to application: NSApplication) {
        application.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }

    @MainActor
    static func applyStoredValue(from defaults: UserDefaults, to application: NSApplication) {
        AppAppearance(storedValue: defaults.string(forKey: storageKey))
            .apply(to: application)
    }
}
