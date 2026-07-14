import Combine
import DetachKit

/// Ephemeral navigation shared by the main and Settings scenes.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsDestination

    init(selectedTab: SettingsDestination = .general) {
        self.selectedTab = selectedTab
    }

    func select(_ destination: SettingsDestination) {
        selectedTab = destination
    }
}
