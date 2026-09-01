import Foundation
import DetachKit

enum PetGenerationPhase: Equatable {
    case unavailable
    case idle
    case starting
    case running
    case attention

    static func resolve(
        isAvailable: Bool,
        isStarting: Bool,
        pendingPetID: String,
        pendingSessionID: String,
        pendingSessionStatus: EffectiveStatus?,
        pendingTurnState: AgentTurnState?
    ) -> PetGenerationPhase {
        if isStarting { return .starting }
        if !pendingPetID.isEmpty && !pendingSessionID.isEmpty {
            guard let pendingSessionStatus else { return .running }
            switch PetGenerationSessionMonitor.state(
                status: pendingSessionStatus,
                turnState: pendingTurnState) {
            case .attention, .stopped:
                return .attention
            case .active:
                return .running
            }
        }
        return isAvailable ? .idle : .unavailable
    }
}

struct RandomPetGenerationRequest: Equatable, Sendable {
    let petID: String
    let sessionName: String
    let prompt: String

    func codexProviderArguments(runtimeHelperURL: URL) -> [String] {
        let server = "mcp_servers.detach_workspace_dependencies"
        return [
            "--disable", "tool_search_always_defer_mcp_tools",
            "-c", "\(server).command=\(Self.tomlString(runtimeHelperURL.path))",
            "-c", "\(server).args=[\(Self.tomlString("mcp")),\(Self.tomlString("workspace-dependencies"))]",
            "-c", "\(server).enabled_tools=[\(Self.tomlString("load_workspace_dependencies"))]",
            "-c", "\(server).default_tools_approval_mode=\(Self.tomlString("approve"))",
            "-c", "\(server).required=true",
        ]
    }

    static func random(
        libraryRoot: URL,
        identifier: UUID = UUID()
    ) -> RandomPetGenerationRequest {
        make(
            libraryRoot: libraryRoot,
            identifier: identifier,
            character: characters.randomElement()!,
            style: styles.randomElement()!,
            palette: palettes.randomElement()!,
            personality: personalities.randomElement()!)
    }

    static func make(
        libraryRoot: URL,
        identifier: UUID,
        character: String,
        style: String,
        palette: String,
        personality: String
    ) -> RandomPetGenerationRequest {
        let token = identifier.uuidString.lowercased()
        let petID = "detach-random-\(token)"
        let target = libraryRoot.appendingPathComponent(
            petID,
            isDirectory: true)
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-pet-\(token)", isDirectory: true)
        let prompt = """
        Используй $hatch-pet и полностью выполни его workflow и QA. Создай нового случайного анимированного питомца формата v2, не задавая мне уточняющих вопросов: все оставшиеся творческие решения прими самостоятельно.

        Случайный образ: \(character).
        Стиль: \(style).
        Палитра: \(palette).
        Характер: \(personality).

        Не копируй бренды, логотипы, известных персонажей или существующих питомцев. Придумай короткое дружелюбное displayName. Используй package id строго `\(petID)` и рабочую папку `\(runDirectory.path)`. После прохождения всех обязательных проверок установи готовый пакет строго в `\(target.path)`. Не изменяй и не перезаписывай другие пакеты в `\(libraryRoot.path)`. Не удаляй внешние временные файлы и не запрашивай разрешение ради необязательной очистки. Если QA не проходит, исправляй артефакты и повторяй проверки, пока остаётся безопасный способ продолжить. Заверши задачу только когда pet.json и spritesheet v2 установлены вместе и финальная валидация успешна.
        """
        return RandomPetGenerationRequest(
            petID: petID,
            sessionName: "Random pet \(token.prefix(8))",
            prompt: prompt)
    }

    private static func tomlString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: encoded += "\\b"
            case 0x09: encoded += "\\t"
            case 0x0a: encoded += "\\n"
            case 0x0c: encoded += "\\f"
            case 0x0d: encoded += "\\r"
            case 0x22: encoded += "\\\""
            case 0x5c: encoded += "\\\\"
            case 0x00...0x1f, 0x7f:
                encoded += String(format: "\\u%04X", scalar.value)
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        encoded += "\""
        return encoded
    }

    private static let characters = [
        "пухлый космический аксолотль",
        "добродушный робот-светлячок",
        "маленький лесной дух с ушами-листьями",
        "облачный дракончик",
        "сова-механик",
        "кот-алхимик",
        "живой чайник-исследователь",
        "крошечный грибной хранитель",
    ]

    private static let styles = [
        "pixel art",
        "мягкая плюшевая игрушка",
        "глиняная фигурка",
        "яркий стикер",
        "миниатюрная 3D-игрушка",
    ]

    private static let palettes = [
        "бирюзовая, коралловая и кремовая",
        "фиолетовая, янтарная и графитовая",
        "мятная, лимонная и тёмно-синяя",
        "терракотовая, небесно-голубая и молочная",
        "малиновая, лавандовая и угольная",
    ]

    private static let personalities = [
        "любопытный и немного застенчивый",
        "бодрый, внимательный и находчивый",
        "спокойный, добрый и сосредоточенный",
        "озорной, но очень ответственный",
        "мечтательный и терпеливый",
    ]
}

enum PetGenerationSupport {
    static func skillURL(for libraryRoot: URL) -> URL {
        libraryRoot.deletingLastPathComponent()
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("hatch-pet", isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    static func isAvailable(
        libraryRoot: URL,
        runtimeHelperURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = skillURL(for: libraryRoot)
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && fileManager.isExecutableFile(atPath: runtimeHelperURL.path)
    }

    static func runtimeHelperURL(detachPath: String) -> URL {
        URL(fileURLWithPath: detachPath)
            .deletingLastPathComponent()
            .appendingPathComponent("detach-state")
    }
}

enum PetGenerationSessionMonitor {
    static let missingPollLimit = 5

    enum State: Equatable {
        case active
        case attention
        case stopped
    }

    static func state(
        status: EffectiveStatus,
        turnState: AgentTurnState?
    ) -> State {
        switch status {
        case .starting, .running, .recovering:
            switch turnState {
            case .waiting, .needsInput, .interrupted:
                return .attention
            case .working, .unknown, nil:
                return .active
            }
        case .hung, .recoverable, .unknown:
            return .attention
        case .completed, .failed, .interrupted, .stopped,
             .orphaned, .corrupt, .collision:
            return .stopped
        }
    }
}
