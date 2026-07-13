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
