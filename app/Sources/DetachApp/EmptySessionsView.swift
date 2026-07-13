import SwiftUI
import DetachKit

struct EmptySessionExample: Equatable, Identifiable {
    let provider: Provider
    let directoryCommand: String
    let launchCommand: String

    var id: Provider { provider }
}

enum EmptySessionsGuide {
    static func examples(detachCommand: String) -> [EmptySessionExample] {
        Provider.allCases.map {
            EmptySessionExample(
                provider: $0,
                directoryCommand: "cd ~/my/repo",
                launchCommand: "\(detachCommand) \($0.rawValue)")
        }
    }
}

struct EmptySessionsView: View {
    let detachPath: String

    private var examples: [EmptySessionExample] {
        EmptySessionsGuide.examples(
            detachCommand: (detachPath as NSString).abbreviatingWithTildeInPath)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 7) {
                    Text("Запусти первую сессию")
                        .appFont(.title2, weight: .bold)
                    Text("Открой свой терминал, перейди в папку проекта и запусти Codex или Claude.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TerminalGuideView(examples: examples)

                VStack(spacing: 6) {
                    Label("Сессия появится здесь автоматически", systemImage: "sparkles")
                        .appFont(.body, weight: .medium)
                        .foregroundStyle(Brand.indigo)
                    Text("Терминал можно закрыть — Detach продолжит работу в фоне. Или нажми ＋, чтобы выбрать проект в приложении.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.vertical, 42)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [Brand.teal.opacity(0.055), Brand.indigo.opacity(0.035), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
    }
}

private struct TerminalGuideView: View {
    let examples: [EmptySessionExample]

    var body: some View {
        VStack(spacing: 0) {
            terminalTitleBar

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(examples.enumerated()), id: \.element.id) { index, example in
                    if index > 0 {
                        Rectangle()
                            .fill(.white.opacity(0.09))
                            .frame(height: 1)
                    }
                    commandExample(example)
                }
            }
            .padding(22)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.075, green: 0.085, blue: 0.12)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.gradient, lineWidth: 1.2)
                .opacity(0.7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Brand.indigo.opacity(0.16), radius: 18, y: 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Примеры команд для запуска Detach")
    }

    private var terminalTitleBar: some View {
        HStack(spacing: 7) {
            Circle().fill(Brand.coral).frame(width: 10, height: 10)
            Circle().fill(Color.yellow.opacity(0.9)).frame(width: 10, height: 10)
            Circle().fill(Brand.teal).frame(width: 10, height: 10)
            Spacer()
            Label("Терминал", systemImage: "terminal")
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.white.opacity(0.62))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 15)
        .frame(height: 40)
        .background(.white.opacity(0.055))
    }

    private func commandExample(_ example: EmptySessionExample) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(example.provider.rawValue.capitalized)
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(Brand.tint(for: example.provider))

            commandRow(example.directoryCommand, accent: false)
            commandRow(example.launchCommand, accent: true)
        }
    }

    private func commandRow(_ command: String, accent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("$")
                .foregroundStyle(Brand.teal)
            Text(command)
                .foregroundStyle(accent ? Color.white : Color.white.opacity(0.78))
                .textSelection(.enabled)
        }
        .appFont(.body, weight: accent ? .semibold : .regular, design: .monospaced)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
