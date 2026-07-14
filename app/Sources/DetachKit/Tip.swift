import Foundation

/// Stable destinations used by tips that link directly to an app setting.
public enum SettingsDestination: String, CaseIterable, Hashable, Sendable {
    case general
    case terminal
    case notifications
    case system
    case updates
}

/// A curated, localizable hint about a Detach feature.
public struct DetachTip: Identifiable, Equatable, Sendable {
    public let id: String
    public let localizationKey: String
    public let destination: SettingsDestination?

    public init(
        id: String,
        localizationKey: String,
        destination: SettingsDestination? = nil
    ) {
        self.id = id
        self.localizationKey = localizationKey
        self.destination = destination
    }

    public func localizedText(
        bundle: Bundle = .main,
        locale: Locale? = nil
    ) -> String {
        L10n.string(localizationKey, bundle: bundle, locale: locale)
    }
}

/// Tips are ordered deliberately: rotation walks this list as a stable ring.
public enum TipCatalog {
    public static let all: [DetachTip] = [
        DetachTip(
            id: "interface",
            localizationKey: "Adjust text size and refresh frequency in General settings.",
            destination: .general),
        DetachTip(
            id: "terminal-selection",
            localizationKey: "Choose which terminal opens Detach commands.",
            destination: .terminal),
        DetachTip(
            id: "tmux-theme",
            localizationKey: "Keep your tmux theme or use Detach session colors.",
            destination: .terminal),
        DetachTip(
            id: "notifications",
            localizationKey: "Get a notification when an agent response is ready.",
            destination: .notifications),
        DetachTip(
            id: "system-health",
            localizationKey: "Check keep-awake and background service health in System settings.",
            destination: .system),
        DetachTip(
            id: "cli-repair",
            localizationKey: "Reinstall the command-line tools from System settings if the CLI needs repair.",
            destination: .system),
        DetachTip(
            id: "automatic-updates",
            localizationKey: "Let Detach check automatically for app updates.",
            destination: .updates),
        DetachTip(
            id: "new-session",
            localizationKey: "Use ＋ to start Codex or Claude in any project."),
    ]
}

/// Deterministic rotation over a curated list of tips.
///
/// Stable unique identifiers are expected. An absent or unknown identifier
/// starts at the beginning; an empty catalog has no next value.
public struct TipRotation: Sendable {
    public let tips: [DetachTip]

    public init(tips: [DetachTip] = TipCatalog.all) {
        self.tips = tips
    }

    public func next(after lastIdentifier: String?) -> DetachTip? {
        guard let first = tips.first else { return nil }
        guard let lastIdentifier,
              let index = tips.firstIndex(where: { $0.id == lastIdentifier }) else {
            return first
        }
        let nextIndex = tips.index(after: index)
        return nextIndex == tips.endIndex ? first : tips[nextIndex]
    }
}
