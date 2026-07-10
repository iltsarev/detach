import SwiftUI

struct OnboardingView: View {
    let detachPath: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(Brand.gradient)
            Text("detach CLI не найден").font(.title3.weight(.bold))
            Text("Искали по пути: \(detachPath)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Установи harness (install-блок в README.md репозитория) или укажи путь в настройках (⌘,).")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            SettingsLink { Text("Открыть настройки") }
        }
        .padding(30)
    }
}
