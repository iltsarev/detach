import DetachKit
import SwiftUI

/// One process-lifetime Tips session. It advances the persisted ring exactly
/// once when the app launches, independently of RootView reconstruction.
@MainActor
final class TipSession: ObservableObject {
    @Published private(set) var currentTip: DetachTip?
    @Published private(set) var isDismissed = false

    private let rotation: TipRotation
    private let defaults: UserDefaults
    private let lastShownIdentifierKey: String

    init(
        rotation: TipRotation = TipRotation(),
        defaults: UserDefaults = .standard,
        lastShownIdentifierKey: String = AppSettings.lastShownTipIdentifierKey
    ) {
        self.rotation = rotation
        self.defaults = defaults
        self.lastShownIdentifierKey = lastShownIdentifierKey
        let tip = rotation.next(after: defaults.string(forKey: lastShownIdentifierKey))
        currentTip = tip
        if let tip {
            defaults.set(tip.id, forKey: lastShownIdentifierKey)
        }
    }

    func showNext() {
        let tip = rotation.next(after: currentTip?.id)
        currentTip = tip
        if let tip {
            defaults.set(tip.id, forKey: lastShownIdentifierKey)
        }
    }

    func dismissUntilNextLaunch() {
        isDismissed = true
    }
}

struct TipsBar: View {
    let tip: DetachTip
    let openSettings: (SettingsDestination) -> Void
    let showNext: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Brand.teal)
                .accessibilityLabel(L10n.string("Tip"))

            if let destination = tip.destination {
                Button {
                    openSettings(destination)
                } label: {
                    Text(tip.localizedText())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tip.localizedText())
                .accessibilityHint(L10n.string("Open this setting"))
            } else {
                Text(tip.localizedText())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tip.localizedText())
            }

            Spacer(minLength: 8)

            Button(action: showNext) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.plain)
            .help(L10n.string("Next tip"))
            .accessibilityLabel(L10n.string("Next tip"))

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(L10n.string("Hide tips until next launch"))
            .accessibilityLabel(L10n.string("Hide tips until next launch"))
        }
        .appFont(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider() }
    }
}
