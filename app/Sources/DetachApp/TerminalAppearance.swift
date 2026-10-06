import AppKit
import SwiftUI
import SwiftTerm
import DetachKit

enum TerminalAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "terminalAppearance"
    static let defaultValue = TerminalAppearance.dark
    var id: String { rawValue }

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    var title: String {
        switch self {
        case .system: L10n.string("Auto")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    func palette(system: TerminalPalette) -> TerminalPalette {
        switch self {
        case .system: system
        case .light: .light
        case .dark: .dark
        }
    }
}

/// NSApp.effectiveAppearance includes the app override. Read macOS separately
/// and refresh on its appearance event, activation, and wake; no polling.
@MainActor
final class SystemTerminalAppearance: NSObject, ObservableObject {
    static let shared = SystemTerminalAppearance()
    @Published private(set) var palette: TerminalPalette
    private let readStyle: () -> String?

    init(readStyle: @escaping () -> String? = {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
    }) {
        self.readStyle = readStyle
        palette = readStyle() == "Dark" ? .dark : .light
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func refresh() {
        let next: TerminalPalette = readStyle() == "Dark" ? .dark : .light
        if palette != next { palette = next }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

private struct TerminalPaletteKey: EnvironmentKey {
    static let defaultValue = TerminalPalette.dark
}

extension EnvironmentValues {
    var terminalPalette: TerminalPalette {
        get { self[TerminalPaletteKey.self] }
        set { self[TerminalPaletteKey.self] = newValue }
    }
}

private struct TerminalAppearanceModifier: ViewModifier {
    @AppStorage(TerminalAppearance.storageKey, store: AppSettings.defaults)
    private var storedValue = TerminalAppearance.defaultValue.rawValue
    @ObservedObject private var system = SystemTerminalAppearance.shared

    func body(content: Content) -> some View {
        content.environment(\.terminalPalette,
            TerminalAppearance(storedValue: storedValue).palette(system: system.palette))
    }
}

extension View {
    func terminalAppearance() -> some View {
        modifier(TerminalAppearanceModifier())
    }
}

extension TerminalPalette {
    func apply(to view: TerminalView) {
        view.appearance = appearance
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = foreground
        view.selectedTextBackgroundColor = selection
        view.selectedTextForegroundColor = foreground
        view.installColors(ansiColors.map { color in
            let rgb = color.usingColorSpace(.sRGB)!
            return SwiftTerm.Color(
                red: UInt16((rgb.redComponent * 65535).rounded()),
                green: UInt16((rgb.greenComponent * 65535).rounded()),
                blue: UInt16((rgb.blueComponent * 65535).rounded()))
        })
        view.needsDisplay = true
    }
}
