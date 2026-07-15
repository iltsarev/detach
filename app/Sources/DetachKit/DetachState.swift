import CoreFoundation
import Foundation

public enum DetachStateError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidMetadata
    case staleRunToken
    case unsupportedScalar
}

/// A JSON scalar used by the shell-facing state helper.
///
/// Metadata mutations are deliberately limited to scalar values. This covers
/// the fields Detach changes while allowing the original JSON object (including
/// fields written by a newer Detach version) to be retained verbatim in
/// meaning when it is re-encoded.
public enum DetachStateScalar: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null
}

public enum SessionMetadataDocument {
    public struct Change: Equatable, Sendable {
        public var key: String
        public var value: DetachStateScalar

        public init(key: String, value: DetachStateScalar) {
            self.key = key
            self.value = value
        }
    }

    /// Applies the existing schema-1 usability rule used for `meta.json` and
    /// its checkpoint fallback.
    public static func isUsable(
        _ data: Data,
        expectedSessionName: String
    ) -> Bool {
        guard let object = try? decodeObject(data),
              integer(from: object["schema"]) == 1,
              object["session_name"] as? String == expectedSessionName,
              object["project_dir"] is String else {
            return false
        }
        return true
    }

    /// Patches top-level metadata without decoding it through a fixed Codable
    /// model, so unknown keys and explicit JSON nulls survive the update.
    public static func patch(
        _ data: Data,
        expectedRunToken: String? = nil,
        changes: [Change]
    ) throws -> Data {
        var object = try decodeObject(data)

        if let expectedRunToken,
           object["run_token"] as? String != expectedRunToken {
            throw DetachStateError.staleRunToken
        }

        for change in changes {
            object[change.key] = foundationValue(change.value)
        }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw DetachStateError.invalidMetadata
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw DetachStateError.invalidMetadata
        }
    }

    /// Creates a new top-level metadata object from typed scalar changes.
    /// File creation and the no-overwrite policy remain the command layer's
    /// responsibility so this operation stays independent of the filesystem.
    public static func create(changes: [Change]) throws -> Data {
        var object: [String: Any] = [:]
        for change in changes {
            object[change.key] = foundationValue(change.value)
        }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw DetachStateError.invalidMetadata
        }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw DetachStateError.invalidMetadata
        }
    }

    /// Applies the provider/session identity predicate used when discovering
    /// an existing Detach session. Metadata from before the provider field was
    /// introduced belongs to Codex.
    public static func matchesSession(
        _ data: Data,
        provider: Provider,
        expectedSessionID: String
    ) -> Bool {
        guard let object = try? decodeObject(data) else { return false }

        let storedProvider: String
        if let value = object["provider"], !(value is NSNull) {
            guard let value = value as? String else { return false }
            storedProvider = value
        } else {
            storedProvider = Provider.codex.rawValue
        }
        guard storedProvider == provider.rawValue else { return false }

        let storedSessionID: String
        if let value = object["agent_session_id"], !(value is NSNull) {
            guard let value = value as? String else { return false }
            storedSessionID = value
        } else if let value = object["codex_session_id"], !(value is NSNull) {
            guard let value = value as? String else { return false }
            storedSessionID = value
        } else {
            return false
        }
        return storedSessionID.lowercased() == expectedSessionID.lowercased()
    }

    /// Reads the first non-null scalar, matching jq's ordered `//` fallbacks
    /// while keeping `false` and numeric zero as real values. Dots traverse
    /// nested JSON objects.
    public static func scalar(
        in data: Data,
        paths: [String]
    ) throws -> DetachStateScalar? {
        try scalar(inJSONObject: decodeObject(data), paths: paths)
    }

    static func scalar(
        inJSONObject object: [String: Any],
        paths: [String]
    ) throws -> DetachStateScalar? {
        for path in paths {
            guard let value = value(atDottedPath: path, in: object),
                  !(value is NSNull) else {
                continue
            }
            guard let scalar = scalarValue(value) else {
                throw DetachStateError.unsupportedScalar
            }
            return scalar
        }
        return nil
    }

    private static func value(
        atDottedPath path: String,
        in object: [String: Any]
    ) -> Any? {
        let components = path.split(
            separator: ".",
            omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var value: Any = object
        for component in components {
            guard let dictionary = value as? [String: Any],
                  let nextValue = dictionary[String(component)] else {
                return nil
            }
            value = nextValue
        }
        return value
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DetachStateError.invalidMetadata
            }
            return object
        } catch let error as DetachStateError {
            throw error
        } catch {
            throw DetachStateError.invalidJSON
        }
    }

    private static func foundationValue(_ scalar: DetachStateScalar) -> Any {
        switch scalar {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    private static func scalarValue(_ value: Any) -> DetachStateScalar? {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if let integer = integer(from: value) {
                return .integer(integer)
            }
            return .number(value.doubleValue)
        }
        return nil
    }

    private static func integer(from value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else {
            return nil
        }
        return Int(double)
    }
}

public struct TranscriptSummary: Equatable, Sendable {
    public var model: String?
    public var contextUsed: Int?
    public var contextWindow: Int?
    public var agentTurnState: AgentTurnState?
    public var agentTurnID: String?

    public init(
        model: String? = nil,
        contextUsed: Int? = nil,
        contextWindow: Int? = nil,
        agentTurnState: AgentTurnState? = nil,
        agentTurnID: String? = nil
    ) {
        self.model = model
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
        self.agentTurnState = agentTurnState
        self.agentTurnID = agentTurnID
    }
}

public enum TranscriptDocument {
    private static let streamChunkSize = 64 * 1_024

    /// Finds the first valid object record containing a non-null scalar at one
    /// of the ordered dotted paths. Malformed and non-object lines are ignored.
    public static func firstScalar(
        in data: Data,
        paths: [String]
    ) throws -> DetachStateScalar? {
        var emitted = false
        return try firstScalar(paths: paths) {
            guard !emitted else { return nil }
            emitted = true
            return data
        }
    }

    /// File-backed variant used by the runtime. It never materializes the
    /// transcript or all decoded records at once.
    public static func firstScalar(
        inFileAt url: URL,
        paths: [String]
    ) throws -> DetachStateScalar? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try firstScalar(paths: paths) {
            try handle.read(upToCount: streamChunkSize)
        }
    }

    /// Stream-backed variant for stdin and focused tests.
    public static func firstScalar(
        reading handle: FileHandle,
        paths: [String]
    ) throws -> DetachStateScalar? {
        try firstScalar(paths: paths) {
            try handle.read(upToCount: streamChunkSize)
        }
    }

    /// Validates every non-empty JSONL record and the provider-specific root
    /// identity contract. Claude permits records without `sessionId`, but at
    /// least one record must identify the expected session and no record may
    /// identify a different one.
    public static func isValid(
        _ data: Data,
        provider: Provider,
        expectedSessionID: String
    ) -> Bool {
        var emitted = false
        return (try? isValid(
            provider: provider,
            expectedSessionID: expectedSessionID
        ) {
            guard !emitted else { return nil }
            emitted = true
            return data
        }) ?? false
    }

    /// Validates a transcript directly from disk with bounded memory.
    public static func isValid(
        fileAt url: URL,
        provider: Provider,
        expectedSessionID: String
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try isValid(
            provider: provider,
            expectedSessionID: expectedSessionID
        ) {
            try handle.read(upToCount: streamChunkSize)
        }
    }

    /// Validates stdin without `readToEnd()`. The caller retains ownership of
    /// the handle because the process-wide standard input must not be closed.
    public static func isValid(
        reading handle: FileHandle,
        provider: Provider,
        expectedSessionID: String
    ) throws -> Bool {
        try isValid(
            provider: provider,
            expectedSessionID: expectedSessionID
        ) {
            try handle.read(upToCount: streamChunkSize)
        }
    }

    /// Incremental validation state machine. `nextChunk` is internal so tests
    /// can prove that a long transcript is consumed lazily rather than first
    /// being assembled into one `Data` value.
    static func isValid(
        provider: Provider,
        expectedSessionID: String,
        nextChunk: () throws -> Data?
    ) throws -> Bool {
        var foundExpectedClaudeID = false
        var providerContractValid = true
        let scan = try scanRecords(
            tolerateInvalid: false,
            nextChunk: nextChunk
        ) { record, recordIndex in
            switch provider {
            case .codex:
                guard recordIndex == 0 else { return true }
                guard let payload = record["payload"] as? [String: Any] else {
                    providerContractValid = false
                    return false
                }
                let identifier = payload["id"] as? String
                    ?? payload["session_id"] as? String
                providerContractValid = identifier == expectedSessionID
                return providerContractValid

            case .claude:
                guard let rawIdentifier = record["sessionId"] else {
                    return true
                }
                guard let identifier = rawIdentifier as? String,
                      identifier == expectedSessionID else {
                    providerContractValid = false
                    return false
                }
                foundExpectedClaudeID = true
                return true
            }
        }

        guard !scan.sawInvalid,
              scan.recordCount > 0,
              providerContractValid else {
            return false
        }
        switch provider {
        case .codex: return true
        case .claude: return foundExpectedClaudeID
        }
    }

    /// Reduces a bounded transcript tail. Invalid first/last fragments are
    /// ignored because a byte tail commonly begins in the middle of a record.
    public static func summary(
        ofTail data: Data,
        provider: Provider
    ) -> TranscriptSummary {
        var result = TranscriptSummary()
        var emitted = false
        _ = try? scanRecords(
            tolerateInvalid: true,
            nextChunk: {
                guard !emitted else { return nil }
                emitted = true
                return data
            }
        ) { record, _ in
            switch provider {
            case .codex: reduceCodex(record, into: &result)
            case .claude: reduceClaude(record, into: &result)
            }
            return true
        }

        if result.model?.isEmpty == true { result.model = nil }
        if result.agentTurnID?.isEmpty != false {
            result.agentTurnState = nil
            result.agentTurnID = nil
        }
        return result
    }

    private struct RecordScanResult {
        var recordCount = 0
        var sawInvalid = false
    }

    private static func firstScalar(
        paths: [String],
        nextChunk: () throws -> Data?
    ) throws -> DetachStateScalar? {
        var result: DetachStateScalar?
        _ = try scanRecords(
            tolerateInvalid: true,
            nextChunk: nextChunk
        ) { record, _ in
            result = try SessionMetadataDocument.scalar(
                inJSONObject: record,
                paths: paths)
            return result == nil
        }
        return result
    }

    /// Splits arbitrary chunks into lines while retaining only an unfinished
    /// record. Decoded Foundation objects are scoped to one iteration and are
    /// never accumulated in an array.
    private static func scanRecords(
        tolerateInvalid: Bool,
        nextChunk: () throws -> Data?,
        visit: ([String: Any], Int) throws -> Bool
    ) throws -> RecordScanResult {
        var result = RecordScanResult()
        var unfinishedLine = Data()

        func consume(_ line: Data) throws -> Bool {
            guard !line.isEmpty,
                  !line.allSatisfy({ byte in
                      byte == 0x20 || byte == 0x09 || byte == 0x0D
                  }) else {
                return true
            }

            return try autoreleasepool {
                let parsed: Any
                do {
                    parsed = try JSONSerialization.jsonObject(with: line)
                } catch {
                    result.sawInvalid = true
                    return tolerateInvalid
                }
                guard let object = parsed as? [String: Any] else {
                    result.sawInvalid = true
                    return tolerateInvalid
                }
                let index = result.recordCount
                result.recordCount += 1
                return try visit(object, index)
            }
        }

        while true {
            var reachedEnd = false
            var stoppedEarly = false
            try autoreleasepool {
                guard let chunk = try nextChunk(), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                var lineStart = chunk.startIndex
                for cursor in chunk.indices where chunk[cursor] == 0x0A {
                    let fragment = chunk[lineStart..<cursor]
                    let line: Data
                    if unfinishedLine.isEmpty {
                        line = Data(fragment)
                    } else {
                        unfinishedLine.append(contentsOf: fragment)
                        line = unfinishedLine
                        unfinishedLine = Data()
                    }
                    guard try consume(line) else {
                        stoppedEarly = true
                        return
                    }
                    lineStart = chunk.index(after: cursor)
                }
                if lineStart != chunk.endIndex {
                    unfinishedLine.append(contentsOf: chunk[lineStart...])
                }
            }
            if stoppedEarly { return result }
            if reachedEnd { break }
        }

        if !unfinishedLine.isEmpty {
            _ = try consume(unfinishedLine)
        }
        return result
    }

    private static func reduceCodex(
        _ record: [String: Any],
        into result: inout TranscriptSummary
    ) {
        guard let payload = record["payload"] as? [String: Any] else { return }

        if let model = payload["model"] as? String {
            result.model = model
        }

        if payload["type"] as? String == "token_count" {
            let info = payload["info"] as? [String: Any]
            let usage = info?["last_token_usage"] as? [String: Any]
            result.contextUsed = safeSum(
                integer(usage?["input_tokens"]),
                integer(usage?["output_tokens"]))
            result.contextWindow = integer(info?["model_context_window"])
        }

        guard record["type"] as? String == "event_msg",
              let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty,
              let event = payload["type"] as? String else {
            return
        }
        switch event {
        case "task_started", "turn_started":
            result.agentTurnState = .working
            result.agentTurnID = turnID
        case "task_complete", "turn_complete":
            result.agentTurnState = .waiting
            result.agentTurnID = turnID
        case "turn_aborted":
            result.agentTurnState = .interrupted
            result.agentTurnID = turnID
        default:
            break
        }
    }

    private static func reduceClaude(
        _ record: [String: Any],
        into result: inout TranscriptSummary
    ) {
        let type = record["type"] as? String
        let message = record["message"] as? [String: Any]

        if type == "assistant" {
            result.model = message?["model"] as? String ?? ""
            let usage = message?["usage"] as? [String: Any]
            result.contextUsed = safeSum(
                integer(usage?["input_tokens"]),
                integer(usage?["cache_read_input_tokens"]),
                integer(usage?["cache_creation_input_tokens"]))
        }

        guard !isJSONTrue(record["isSidechain"]),
              let turnID = record["uuid"] as? String,
              !turnID.isEmpty else {
            return
        }

        if type == "system", record["subtype"] as? String == "turn_duration" {
            result.agentTurnState = .waiting
            result.agentTurnID = turnID
            return
        }

        guard type == "user",
              !isJSONTrue(record["isMeta"]),
              message?["role"] as? String == "user",
              !containsToolResult(message?["content"]) else {
            return
        }
        result.agentTurnState = .working
        result.agentTurnID = turnID
    }

    private static func containsToolResult(_ value: Any?) -> Bool {
        guard let content = value as? [Any] else { return false }
        return content.contains { item in
            (item as? [String: Any])?["type"] as? String == "tool_result"
        }
    }

    private static func isJSONTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return 0
        }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else {
            return 0
        }
        return Int(double)
    }

    private static func safeSum(_ values: Int...) -> Int {
        values.reduce(into: 0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? 0 : sum
        }
    }
}
