import SwiftUI

struct SettingsView: View {
    @AppStorage("detachPath") private var detachPath = AppSettings.defaultDetachPath
    @AppStorage("pollInterval") private var pollInterval = 2.0

    var body: some View {
        Form {
            TextField("Путь к detach", text: $detachPath)
            Slider(value: $pollInterval, in: 1...10, step: 1) {
                Text("Интервал обновления: \(Int(pollInterval)) с")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
