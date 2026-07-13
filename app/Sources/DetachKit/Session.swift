import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
}

public enum EffectiveStatus: String, Codable, Sendable {
    case starting, running, recovering
    case completed, failed, interrupted, stopped
    case recoverable, orphaned, corrupt, collision
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EffectiveStatus(rawValue: raw) ?? .unknown
    }
}

public enum AgentTurnState: String, Codable, Sendable {
    case working
    case waiting
    case interrupted
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTurnState(rawValue: raw) ?? .unknown
    }
}

/// The stable accent assigned to one managed tmux session.
///
/// The CLI is the source of truth for this value so terminal and app visuals
/// cannot drift. Keeping the representation deliberately narrow also makes it
/// safe to pass directly to tmux's `#[fg=#RRGGBB]` style syntax.
public struct SessionColor: Equatable, Hashable, Sendable, Codable {
    public let hex: String
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init?(hex: String) {
        let bytes = hex.utf8
        guard bytes.count == 7, bytes.first == 0x23,
              bytes.dropFirst().allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x41...0x46).contains(byte)
                      || (0x61...0x66).contains(byte)
              }),
              let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        red = UInt8((value >> 16) & 0xff)
        green = UInt8((value >> 8) & 0xff)
        blue = UInt8(value & 0xff)
        self.hex = String(format: "#%02X%02X%02X", red, green, blue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let color = SessionColor(hex: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "session_color must use #RRGGBB format")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

public struct Session: Identifiable, Equatable, Sendable, Decodable {
    public var schema: Int
    public var provider: Provider
    public var sessionName: String
    public var name: String
    public var effectiveStatus: EffectiveStatus
    public var metaStatus: String?
    public var agentSessionId: String?
    public var projectDir: String?
    public var createdAt: Date?
    public var lastCheckpointAt: Date?
    public var exitStatus: Int?
    public var finishedAt: Date?
    public var model: String?
    public var contextUsedTokens: Int?
    public var contextWindow: Int?
    public var agentTurnState: AgentTurnState?
    public var agentTurnID: String?
    public var sessionColor: SessionColor?

    public var id: String { sessionName }

    enum CodingKeys: String, CodingKey {
        case schema, provider, name, model
        case sessionName = "session_name"
        case effectiveStatus = "effective_status"
        case metaStatus = "meta_status"
        case agentSessionId = "agent_session_id"
        case projectDir = "project_dir"
        case createdAt = "created_at"
        case lastCheckpointAt = "last_checkpoint_at"
        case exitStatus = "exit_status"
        case finishedAt = "finished_at"
        case contextUsedTokens = "context_used_tokens"
        case contextWindow = "context_window"
        case agentTurnState = "agent_turn_state"
        case agentTurnID = "agent_turn_id"
        case sessionColor = "session_color"
    }
}

public enum SessionListParser {
    public struct ParseResult: Equatable, Sendable {
        public var sessions: [Session]
        public var hadInvalidLines: Bool
    }

    public static func parse(_ jsonl: String) -> ParseResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sessions: [Session] = []
        var invalid = false
        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let session = try? decoder.decode(Session.self, from: data),
                  session.schema == 1 else {
                invalid = true
                continue
            }
            sessions.append(session)
        }
        return ParseResult(sessions: sessions, hadInvalidLines: invalid)
    }
}
