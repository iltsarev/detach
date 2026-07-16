import Foundation

public enum DetachStateCommandError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidInteger(String)
    case invalidNumber(String)
    case invalidBoolean(String)
    case invalidProvider(String)
    case invalidAgentTurnState(String)
    case invalidPowerState(String)
    case invalidSessionColor(String)
    case invalidTranscript
    case unusableMetadata
    case metadataMismatch
    case invalidStorageInventory
    case invalidStorageReport
    case unsafeStorageSelection(String)
}

/// The command contract shared by the `detach-state` executable and unit
/// tests. Successful commands return the exact bytes to write to stdout.
public enum DetachStateCommand {
    public static func run(arguments: [String]) throws -> Data {
        try execute(arguments: arguments, injectedStandardInput: nil)
    }

    static func run(
        arguments: [String],
        standardInput: Data
    ) throws -> Data {
        try execute(arguments: arguments, injectedStandardInput: standardInput)
    }

    private static func execute(
        arguments: [String],
        injectedStandardInput: Data?
    ) throws -> Data {
        guard arguments.count >= 2 else {
            throw DetachStateCommandError.invalidArguments
        }

        switch (arguments[0], arguments[1]) {
        case ("emit", "context"):
            return try emitContext(Array(arguments.dropFirst(2)))
        case ("emit", "session"):
            return try emitSession(Array(arguments.dropFirst(2)))
        case ("meta", "get"):
            return try metaGet(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("meta", "usable"):
            return try metaUsable(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("meta", "create"):
            return try metaCreate(Array(arguments.dropFirst(2)))
        case ("meta", "patch"):
            return try metaPatch(Array(arguments.dropFirst(2)))
        case ("meta", "matches"):
            return try metaMatches(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("jsonl", "first"):
            return try jsonlFirst(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("jsonl", "validate"):
            return try jsonlValidate(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("jsonl", "summary"):
            return try jsonlSummary(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("storage", "report"):
            return try storageReport(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("storage", "plan"):
            return try storagePlan(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("health", "evaluate"):
            return try healthEvaluate(Array(arguments.dropFirst(2)))
        case ("maintenance", "reconcile"):
            return try maintenanceReconcile(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        default:
            throw DetachStateCommandError.invalidArguments
        }
    }

    private static func storageReport(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        var stateRoot: String?
        var providerRoots: [Provider: String] = [:]
        var excludedRoots: [String] = []
        var inventoryPath: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            guard index < arguments.count else {
                throw DetachStateCommandError.invalidArguments
            }
            let value = arguments[index]
            index += 1
            switch option {
            case "--state-root" where stateRoot == nil:
                stateRoot = value
            case "--codex-root" where providerRoots[.codex] == nil:
                providerRoots[.codex] = value
            case "--claude-root" where providerRoots[.claude] == nil:
                providerRoots[.claude] = value
            case "--exclude-root":
                excludedRoots.append(value)
            case "--sessions" where inventoryPath == nil:
                inventoryPath = value
            default:
                throw DetachStateCommandError.invalidArguments
            }
        }
        guard let stateRoot,
              providerRoots[.codex] != nil,
              providerRoots[.claude] != nil,
              let inventoryPath else {
            throw DetachStateCommandError.invalidArguments
        }
        let inventory = try inputData(atPath: inventoryPath, standardInput: standardInput)
        do {
            return try encodeJSON(StorageInspector.report(
                stateRoot: stateRoot,
                providerRoots: providerRoots,
                excludedRoots: excludedRoots,
                inventory: inventory))
        } catch StorageInspectionError.invalidInventory {
            throw DetachStateCommandError.invalidStorageInventory
        }
    }

    private static func storagePlan(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard let reportPath = arguments.first else {
            throw DetachStateCommandError.invalidArguments
        }
        var selectAll = false
        var sessionNames: [String] = []
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--all" where !selectAll && sessionNames.isEmpty:
                selectAll = true
                index += 1
            case "--session" where !selectAll && index + 1 < arguments.count:
                sessionNames.append(arguments[index + 1])
                index += 2
            default:
                throw DetachStateCommandError.invalidArguments
            }
        }
        guard selectAll || !sessionNames.isEmpty else {
            throw DetachStateCommandError.invalidArguments
        }
        let reportData = try inputData(atPath: reportPath, standardInput: standardInput)
        do {
            return try encodeJSON(StorageInspector.cleanupPlan(
                reportData: reportData,
                selectAll: selectAll,
                sessionNames: sessionNames))
        } catch StorageInspectionError.unsafeSelection(let name) {
            throw DetachStateCommandError.unsafeStorageSelection(name)
        } catch {
            throw DetachStateCommandError.invalidStorageReport
        }
    }

    private static func healthEvaluate(_ arguments: [String]) throws -> Data {
        let allowed = Set([
            "--metadata-valid", "--runtime-identity-expected", "--meta-status",
            "--tmux", "--run-token",
            "--worker", "--provider-process", "--heartbeat", "--checkpoint",
            "--checkpoint-recoverable", "--agent-session-known",
        ])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count,
                  allowed.contains(arguments[index]),
                  values[arguments[index]] == nil else {
                throw DetachStateCommandError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard values.count == allowed.count,
              let metadataRaw = values["--metadata-valid"],
              let identityExpectedRaw = values["--runtime-identity-expected"],
              let statusRaw = values["--meta-status"],
              let status = EffectiveStatus(rawValue: statusRaw),
              let tmuxRaw = values["--tmux"],
              let tmux = TmuxHealthState(rawValue: tmuxRaw),
              let tokenRaw = values["--run-token"],
              let token = RunTokenHealthState(rawValue: tokenRaw),
              let workerRaw = values["--worker"],
              let worker = ProcessHealthState(rawValue: workerRaw),
              let providerRaw = values["--provider-process"],
              let providerProcess = ProcessHealthState(rawValue: providerRaw),
              let heartbeatRaw = values["--heartbeat"],
              let heartbeat = FreshnessState(rawValue: heartbeatRaw),
              let checkpointRaw = values["--checkpoint"],
              let checkpoint = FreshnessState(rawValue: checkpointRaw),
              let recoverableRaw = values["--checkpoint-recoverable"],
              let knownRaw = values["--agent-session-known"] else {
            throw DetachStateCommandError.invalidArguments
        }
        return try encodeJSON(SessionHealthEvaluator.evaluate(SessionHealthEvidence(
            metadataValid: try boolean(metadataRaw),
            runtimeIdentityExpected: try boolean(identityExpectedRaw),
            metaStatus: status,
            tmuxState: tmux,
            runTokenState: token,
            workerState: worker,
            providerState: providerProcess,
            heartbeatFreshness: heartbeat,
            checkpointFreshness: checkpoint,
            checkpointRecoverable: try boolean(recoverableRaw),
            agentSessionKnown: try boolean(knownRaw))))
    }

    private static func maintenanceReconcile(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 1 else {
            throw DetachStateCommandError.invalidArguments
        }
        let inventory = try inputData(atPath: arguments[0], standardInput: standardInput)
        do {
            return try encodeJSON(SessionMaintenancePlanner.reconcile(inventory: inventory))
        } catch StorageInspectionError.invalidInventory {
            throw DetachStateCommandError.invalidStorageInventory
        }
    }

    private static func emitContext(_ arguments: [String]) throws -> Data {
        guard arguments.count == 3 else {
            throw DetachStateCommandError.invalidArguments
        }
        return try encodeJSONObject([
            "session_name": arguments[0],
            "project_dir": arguments[1],
            "live": try boolean(arguments[2]),
        ])
    }

    private static func emitSession(_ arguments: [String]) throws -> Data {
        guard arguments.count >= 3 else {
            throw DetachStateCommandError.invalidArguments
        }
        let provider = try provider(arguments[0])
        let sessionName = arguments[1]
        let prefix = "detach-\(provider.rawValue)-"
        let name = sessionName.hasPrefix(prefix)
            ? String(sessionName.dropFirst(prefix.count))
            : sessionName

        var object: [String: Any] = [
            "schema": 1,
            "provider": provider.rawValue,
            "session_name": sessionName,
            "name": name,
            "session_color": NSNull(),
            "effective_status": arguments[2],
            "meta_status": NSNull(),
            "agent_session_id": NSNull(),
            "project_dir": NSNull(),
            "created_at": NSNull(),
            "last_checkpoint_at": NSNull(),
            "exit_status": NSNull(),
            "finished_at": NSNull(),
            "model": NSNull(),
            "context_used_tokens": NSNull(),
            "context_window": NSNull(),
            "agent_turn_state": NSNull(),
            "agent_turn_id": NSNull(),
            "power_protection_state": NSNull(),
            "health_reason": NSNull(),
            "health_actions": NSNull(),
            "reconcile_action": NSNull(),
            "ownership_proven": NSNull(),
            "cleanup_eligible": NSNull(),
            "worker_pid": NSNull(),
            "provider_pid": NSNull(),
            "worker_heartbeat_at": NSNull(),
            "heartbeat_fresh": NSNull(),
            "checkpoint_fresh": NSNull(),
        ]

        var seen: Set<String> = []
        var index = 3
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count,
                  seen.insert(option).inserted else {
                throw DetachStateCommandError.invalidArguments
            }
            let value = arguments[index + 1]

            switch option {
            case "--meta-status":
                object["meta_status"] = optionalString(value)
            case "--agent-session-id":
                object["agent_session_id"] = optionalString(value)
            case "--project-dir":
                object["project_dir"] = optionalString(value)
            case "--created-at":
                object["created_at"] = optionalString(value)
            case "--last-checkpoint-at":
                object["last_checkpoint_at"] = optionalString(value)
            case "--exit-status":
                object["exit_status"] = try integer(value)
            case "--finished-at":
                object["finished_at"] = optionalString(value)
            case "--model":
                object["model"] = optionalString(value)
            case "--context-used":
                let value = try integer(value)
                object["context_used_tokens"] = value == 0 ? NSNull() : value
            case "--context-window":
                let value = try integer(value)
                object["context_window"] = value == 0 ? NSNull() : value
            case "--agent-turn-state":
                if isNullPlaceholder(value) {
                    object["agent_turn_state"] = NSNull()
                } else {
                    guard AgentTurnState(rawValue: value) != nil else {
                        throw DetachStateCommandError.invalidAgentTurnState(value)
                    }
                    object["agent_turn_state"] = value
                }
            case "--agent-turn-id":
                object["agent_turn_id"] = optionalString(value)
            case "--session-color":
                if isNullPlaceholder(value) {
                    object["session_color"] = NSNull()
                } else {
                    guard SessionColor(hex: value) != nil else {
                        throw DetachStateCommandError.invalidSessionColor(value)
                    }
                    object["session_color"] = value
                }
            case "--power-state":
                if isNullPlaceholder(value) {
                    object["power_protection_state"] = NSNull()
                } else {
                    guard PowerProtectionState(rawValue: value) != nil else {
                        throw DetachStateCommandError.invalidPowerState(value)
                    }
                    object["power_protection_state"] = value
                }
            case "--health-json":
                let decoder = JSONDecoder()
                guard let data = value.data(using: .utf8),
                      let health = try? decoder.decode(SessionHealthAssessment.self, from: data),
                      health.schema == 1,
                      health.effectiveStatus.rawValue == arguments[2] else {
                    throw DetachStateCommandError.invalidArguments
                }
                object["health_reason"] = health.reason.rawValue
                object["health_actions"] = health.actions.map(\.rawValue)
                object["reconcile_action"] = health.reconcileAction.rawValue
                object["ownership_proven"] = health.ownershipProven
                object["cleanup_eligible"] = health.cleanupEligible
                object["heartbeat_fresh"] = health.heartbeatFresh
                object["checkpoint_fresh"] = health.checkpointFresh
            case "--worker-pid":
                object["worker_pid"] = isNullPlaceholder(value)
                    ? NSNull() : try integer(value)
            case "--provider-pid":
                object["provider_pid"] = isNullPlaceholder(value)
                    ? NSNull() : try integer(value)
            case "--worker-heartbeat-at":
                object["worker_heartbeat_at"] = optionalString(value)
            default:
                throw DetachStateCommandError.invalidArguments
            }
            index += 2
        }

        return try encodeJSONObject(object)
    }

    private static func metaGet(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count >= 2 else {
            throw DetachStateCommandError.invalidArguments
        }
        let data = try inputData(
            atPath: arguments[0],
            standardInput: standardInput)
        guard let scalar = try SessionMetadataDocument.scalar(
            in: data,
            paths: Array(arguments.dropFirst())) else {
            return Data()
        }
        return Data((render(scalar) + "\n").utf8)
    }

    private static func metaUsable(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 2 else {
            throw DetachStateCommandError.invalidArguments
        }
        let data = try inputData(
            atPath: arguments[0],
            standardInput: standardInput)
        guard SessionMetadataDocument.isUsable(
            data,
            expectedSessionName: arguments[1]) else {
            throw DetachStateCommandError.unusableMetadata
        }
        return Data()
    }

    private static func metaCreate(_ arguments: [String]) throws -> Data {
        guard let path = arguments.first else {
            throw DetachStateCommandError.invalidArguments
        }
        let mutation = try metaMutationArguments(
            Array(arguments.dropFirst()),
            allowRunToken: false)
        let data = try SessionMetadataDocument.create(changes: mutation.changes)
        try writeNewAtomically(data, to: fileURL(path))
        return Data()
    }

    private static func metaPatch(_ arguments: [String]) throws -> Data {
        guard let path = arguments.first else {
            throw DetachStateCommandError.invalidArguments
        }
        let mutation = try metaMutationArguments(
            Array(arguments.dropFirst()),
            allowRunToken: true)
        let url = fileURL(path)
        let original = try Data(contentsOf: url)
        let updated = try SessionMetadataDocument.patch(
            original,
            expectedRunToken: mutation.expectedRunToken,
            changes: mutation.changes)
        try updated.write(to: url, options: .atomic)
        return Data()
    }

    private struct MetaMutationArguments {
        var expectedRunToken: String?
        var changes: [SessionMetadataDocument.Change]
    }

    private static func metaMutationArguments(
        _ arguments: [String],
        allowRunToken: Bool
    ) throws -> MetaMutationArguments {
        var result = MetaMutationArguments(expectedRunToken: nil, changes: [])
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--run-token":
                guard allowRunToken,
                      index + 1 < arguments.count,
                      result.expectedRunToken == nil else {
                    throw DetachStateCommandError.invalidArguments
                }
                result.expectedRunToken = arguments[index + 1]
                index += 2

            case "--string":
                let (key, value) = try pair(arguments, after: index)
                result.changes.append(.init(key: key, value: .string(value)))
                index += 3

            case "--integer":
                let (key, rawValue) = try pair(arguments, after: index)
                guard let value = Int(rawValue) else {
                    throw DetachStateCommandError.invalidInteger(rawValue)
                }
                result.changes.append(.init(key: key, value: .integer(value)))
                index += 3

            case "--number":
                let (key, rawValue) = try pair(arguments, after: index)
                guard let value = Double(rawValue), value.isFinite else {
                    throw DetachStateCommandError.invalidNumber(rawValue)
                }
                result.changes.append(.init(key: key, value: .number(value)))
                index += 3

            case "--bool":
                let (key, rawValue) = try pair(arguments, after: index)
                result.changes.append(.init(
                    key: key,
                    value: .bool(try boolean(rawValue))))
                index += 3

            case "--null":
                guard index + 1 < arguments.count else {
                    throw DetachStateCommandError.invalidArguments
                }
                result.changes.append(.init(key: arguments[index + 1], value: .null))
                index += 2

            default:
                throw DetachStateCommandError.invalidArguments
            }
        }

        guard !result.changes.isEmpty else {
            throw DetachStateCommandError.invalidArguments
        }
        return result
    }

    private static func metaMatches(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 3 else {
            throw DetachStateCommandError.invalidArguments
        }
        let data = try inputData(
            atPath: arguments[0],
            standardInput: standardInput)
        guard SessionMetadataDocument.matchesSession(
            data,
            provider: try provider(arguments[1]),
            expectedSessionID: arguments[2]) else {
            throw DetachStateCommandError.metadataMismatch
        }
        return Data()
    }

    private static func jsonlFirst(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count >= 2 else {
            throw DetachStateCommandError.invalidArguments
        }
        let path = arguments[0]
        let paths = Array(arguments.dropFirst())
        let scalar: DetachStateScalar?
        if path == "/dev/stdin" || path == "-" {
            if let standardInput {
                scalar = try TranscriptDocument.firstScalar(
                    in: standardInput, paths: paths)
            } else {
                scalar = try TranscriptDocument.firstScalar(
                    reading: .standardInput, paths: paths)
            }
        } else {
            scalar = try TranscriptDocument.firstScalar(
                inFileAt: fileURL(path), paths: paths)
        }
        guard let scalar else {
            return Data()
        }
        return Data((render(scalar) + "\n").utf8)
    }

    private static func jsonlValidate(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 3 else {
            throw DetachStateCommandError.invalidArguments
        }
        let provider = try provider(arguments[0])
        let path = arguments[1]
        let expectedSessionID = arguments[2]
        let valid: Bool
        if path == "/dev/stdin" || path == "-" {
            if let standardInput {
                valid = TranscriptDocument.isValid(
                    standardInput,
                    provider: provider,
                    expectedSessionID: expectedSessionID)
            } else {
                valid = try TranscriptDocument.isValid(
                    reading: .standardInput,
                    provider: provider,
                    expectedSessionID: expectedSessionID)
            }
        } else {
            valid = try TranscriptDocument.isValid(
                fileAt: fileURL(path),
                provider: provider,
                expectedSessionID: expectedSessionID)
        }
        guard valid else {
            throw DetachStateCommandError.invalidTranscript
        }
        return Data()
    }

    private static func jsonlSummary(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 2 ||
                (arguments.count == 3 && arguments[2] == "--tsv") else {
            throw DetachStateCommandError.invalidArguments
        }
        let provider = try provider(arguments[0])
        let summary = TranscriptDocument.summary(
            ofTail: try tail(
                atPath: arguments[1],
                maximumByteCount: 262_144,
                standardInput: standardInput),
            provider: provider)

        if arguments.count == 3 {
            let fields: [(String, String?)] = [
                ("model", summary.model),
                ("context_used", summary.contextUsed.map(String.init)),
                ("context_window", summary.contextWindow.map(String.init)),
                ("agent_turn_state", summary.agentTurnState?.rawValue),
                ("agent_turn_id", summary.agentTurnID),
            ]
            let output = fields.compactMap { key, value in
                value.map { "\(key)\t\($0)\n" }
            }.joined()
            return Data(output.utf8)
        }

        let object: [String: Any] = [
            "model": summary.model ?? NSNull(),
            "context_used": summary.contextUsed ?? NSNull(),
            "context_window": summary.contextWindow ?? NSNull(),
            "agent_turn_state": summary.agentTurnState?.rawValue ?? NSNull(),
            "agent_turn_id": summary.agentTurnID ?? NSNull(),
        ]
        var output = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        output.append(0x0A)
        return output
    }

    private static func pair(
        _ arguments: [String],
        after index: Int
    ) throws -> (String, String) {
        guard index + 2 < arguments.count else {
            throw DetachStateCommandError.invalidArguments
        }
        return (arguments[index + 1], arguments[index + 2])
    }

    private static func provider(_ rawValue: String) throws -> Provider {
        guard let provider = Provider(rawValue: rawValue) else {
            throw DetachStateCommandError.invalidProvider(rawValue)
        }
        return provider
    }

    private static func boolean(_ rawValue: String) throws -> Bool {
        switch rawValue {
        case "true": true
        case "false": false
        default: throw DetachStateCommandError.invalidBoolean(rawValue)
        }
    }

    private static func integer(_ rawValue: String) throws -> Int {
        guard let value = Int(rawValue) else {
            throw DetachStateCommandError.invalidInteger(rawValue)
        }
        return value
    }

    private static func optionalString(_ value: String) -> Any {
        isNullPlaceholder(value) ? NSNull() : value
    }

    private static func isNullPlaceholder(_ value: String) -> Bool {
        value.isEmpty || value == "-" || value == "?"
    }

    private static func render(_ scalar: DetachStateScalar) -> String {
        switch scalar {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    private static func inputData(
        atPath path: String,
        standardInput: Data?
    ) throws -> Data {
        guard path == "/dev/stdin" || path == "-" else {
            return try Data(contentsOf: fileURL(path))
        }
        if let standardInput {
            return standardInput
        }
        return try FileHandle.standardInput.readToEnd() ?? Data()
    }

    private static func encodeJSONObject(_ object: [String: Any]) throws -> Data {
        var output = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        output.append(0x0A)
        return output
    }

    private static func encodeJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = try encoder.encode(value)
        output.append(0x0A)
        return output
    }

    /// Publishes a fully-written file with an atomic no-overwrite operation.
    /// A hard link is atomic on the destination filesystem and fails if the
    /// destination already exists; the private temporary name is always
    /// removed afterwards.
    private static func writeNewAtomically(_ data: Data, to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: temporaryURL, to: url)
    }

    private static func tail(
        atPath path: String,
        maximumByteCount: UInt64,
        standardInput: Data?
    ) throws -> Data {
        if path == "/dev/stdin" || path == "-" {
            let limit = Int(maximumByteCount)
            if let standardInput {
                let count = min(standardInput.count, limit)
                return Data(standardInput.suffix(count))
            }
            var boundedTail = Data()
            while let chunk = try FileHandle.standardInput.read(
                upToCount: 64 * 1_024), !chunk.isEmpty {
                boundedTail.append(chunk)
                if boundedTail.count > limit {
                    boundedTail = Data(boundedTail.suffix(limit))
                }
            }
            return boundedTail
        }

        let url = fileURL(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > maximumByteCount ? size - maximumByteCount : 0)
        return try handle.readToEnd() ?? Data()
    }
}
