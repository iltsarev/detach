import Darwin
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
    case unsafeEventSignal
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
        case ("meta", "snapshot"):
            return try metaSnapshot(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("meta", "snapshots"):
            return try metaSnapshots(
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
        case ("jsonl", "validate-cached"):
            return try jsonlValidateCached(Array(arguments.dropFirst(2)))
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
        case ("health", "session"):
            return try healthSession(Array(arguments.dropFirst(2)))
        case ("health", "sessions"):
            return try healthSessions(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("maintenance", "reconcile"):
            return try maintenanceReconcile(
                Array(arguments.dropFirst(2)),
                standardInput: injectedStandardInput)
        case ("events", "publish"):
            return try eventPublish(Array(arguments.dropFirst(2)))
        default:
            throw DetachStateCommandError.invalidArguments
        }
    }

    private static func eventPublish(_ arguments: [String]) throws -> Data {
        guard arguments.count == 1 else {
            throw DetachStateCommandError.invalidArguments
        }
        do {
            try SessionEventSignal.publish(atPath: arguments[0])
        } catch {
            throw DetachStateCommandError.unsafeEventSignal
        }
        return Data()
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

    private static func healthEvaluate(_ originalArguments: [String]) throws -> Data {
        var arguments = originalArguments
        let envelope = arguments.last == "--envelope"
        if envelope { arguments.removeLast() }
        let assessment = try healthAssessment(arguments)
        let encoded = try encodeJSON(assessment)
        guard envelope else { return encoded }
        var output = Data((assessment.effectiveStatus.rawValue + "\n").utf8)
        output.append(encoded)
        return output
    }

    /// Evaluates typed health and emits the matching public session object in
    /// one helper process. Arguments after `--` are the normal emit-session
    /// arguments without the effective status or health payload.
    private static func healthSession(_ arguments: [String]) throws -> Data {
        guard let separator = arguments.firstIndex(of: "--") else {
            throw DetachStateCommandError.invalidArguments
        }
        let assessment = try healthAssessment(Array(arguments[..<separator]))
        var sessionArguments = Array(arguments[arguments.index(after: separator)...])
        guard sessionArguments.count >= 2 else {
            throw DetachStateCommandError.invalidArguments
        }
        sessionArguments.insert(assessment.effectiveStatus.rawValue, at: 2)
        if assessment.effectiveStatus == .collision,
           let colorIndex = sessionArguments[3...]
            .firstIndex(of: "--session-color"),
           sessionArguments.indices.contains(colorIndex + 1) {
            sessionArguments[colorIndex + 1] = ""
        }
        sessionArguments.append("--health-json")
        sessionArguments.append(String(
            decoding: try encodeJSON(assessment),
            as: UTF8.self))
        var output = Data((assessment.effectiveStatus.rawValue + "\n").utf8)
        output.append(try emitSession(sessionArguments))
        return output
    }

    /// Evaluates a NUL-safe stream of health-session argument arrays in one
    /// process. Each record starts with its decimal argument count. A final
    /// zero count proves that the shell producer reached normal completion.
    private static func healthSessions(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 1 else {
            throw DetachStateCommandError.invalidArguments
        }
        let input = try inputData(
            atPath: arguments[0],
            standardInput: standardInput)
        let components = input.split(
            separator: 0,
            omittingEmptySubsequences: false)
        guard components.last?.isEmpty == true else {
            throw DetachStateCommandError.invalidArguments
        }
        let fields = components.dropLast()
        var index = fields.startIndex
        var complete = false
        var output = Data()
        while index < fields.endIndex {
            guard let countText = String(
                    data: Data(fields[index]),
                    encoding: .utf8),
                  let count = Int(countText),
                  count >= 0,
                  count <= 256 else {
                throw DetachStateCommandError.invalidArguments
            }
            index = fields.index(after: index)
            if count == 0 {
                guard index == fields.endIndex else {
                    throw DetachStateCommandError.invalidArguments
                }
                complete = true
                break
            }
            guard fields.distance(from: index, to: fields.endIndex) >= count else {
                throw DetachStateCommandError.invalidArguments
            }
            var sessionArguments: [String] = []
            sessionArguments.reserveCapacity(count)
            for _ in 0..<count {
                guard let value = String(
                        data: Data(fields[index]),
                        encoding: .utf8) else {
                    throw DetachStateCommandError.invalidArguments
                }
                sessionArguments.append(value)
                index = fields.index(after: index)
            }
            let envelope = try healthSession(sessionArguments)
            guard let newline = envelope.firstIndex(of: 0x0A) else {
                throw DetachStateCommandError.invalidArguments
            }
            output.append(envelope[envelope.index(after: newline)...])
        }
        guard complete else {
            throw DetachStateCommandError.invalidArguments
        }
        return output
    }

    private static func healthAssessment(
        _ arguments: [String]
    ) throws -> SessionHealthAssessment {
        let required = Set([
            "--metadata-valid", "--runtime-identity-expected", "--meta-status",
            "--tmux", "--run-token",
            "--worker", "--provider-process", "--heartbeat", "--checkpoint",
            "--checkpoint-recoverable", "--agent-session-known",
        ])
        let processInspection = Set([
            "--inspect-processes", "--worker-pid", "--provider-pid", "--pane-pid",
        ])
        let allowed = required.union(processInspection)
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
        guard required.allSatisfy({ values[$0] != nil }),
              let metadataRaw = values["--metadata-valid"],
              let identityExpectedRaw = values["--runtime-identity-expected"],
              let statusRaw = values["--meta-status"],
              let status = EffectiveStatus(rawValue: statusRaw),
              let tmuxRaw = values["--tmux"],
              let tmux = TmuxHealthState(rawValue: tmuxRaw),
              let tokenRaw = values["--run-token"],
              let token = RunTokenHealthState(rawValue: tokenRaw),
              let workerRaw = values["--worker"],
              var worker = ProcessHealthState(rawValue: workerRaw),
              let providerRaw = values["--provider-process"],
              var providerProcess = ProcessHealthState(rawValue: providerRaw),
              let heartbeatRaw = values["--heartbeat"],
              let heartbeat = FreshnessState(rawValue: heartbeatRaw),
              let checkpointRaw = values["--checkpoint"],
              let checkpoint = FreshnessState(rawValue: checkpointRaw),
              let recoverableRaw = values["--checkpoint-recoverable"],
              let knownRaw = values["--agent-session-known"] else {
            throw DetachStateCommandError.invalidArguments
        }
        if let inspectRaw = values["--inspect-processes"] {
            guard try boolean(inspectRaw),
                  processInspection.allSatisfy({ values[$0] != nil }),
                  let workerPID = values["--worker-pid"],
                  let providerPID = values["--provider-pid"],
                  let panePID = values["--pane-pid"] else {
                throw DetachStateCommandError.invalidArguments
            }
            let processHealth = SessionProcessHealthInspector.inspect(
                tmuxState: tmux,
                workerPID: workerPID,
                providerPID: providerPID,
                panePID: panePID)
            worker = processHealth.worker
            providerProcess = processHealth.provider
        } else if !processInspection.isDisjoint(with: values.keys) {
            throw DetachStateCommandError.invalidArguments
        }
        return SessionHealthEvaluator.evaluate(SessionHealthEvidence(
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
            agentSessionKnown: try boolean(knownRaw)))
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
            "display_name": NSNull(),
            "session_color": NSNull(),
            "effective_status": arguments[2],
            "meta_status": NSNull(),
            "agent_session_id": NSNull(),
            "project_dir": NSNull(),
            "created_at": NSNull(),
            "last_checkpoint_at": NSNull(),
            "exit_status": NSNull(),
            "finished_at": NSNull(),
            "stop_requested_at": NSNull(),
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
            case "--display-name":
                object["display_name"] = value.isEmpty ? NSNull() : value
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
            case "--stop-requested-at":
                object["stop_requested_at"] = optionalString(value)
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

    private static let metadataSnapshotFields: [(String, [String])] = [
        ("status", ["status"]),
        ("display_name", ["display_name"]),
        ("project_dir", ["project_dir"]),
        ("last_checkpoint_at", ["last_checkpoint_at"]),
        ("agent_session_id", ["agent_session_id", "codex_session_id"]),
        ("created_at", ["created_at"]),
        ("finished_at", ["finished_at"]),
        ("exit_status", ["exit_status"]),
        ("worker_pid", ["worker_pid"]),
        ("provider_pid", ["provider_pid"]),
        ("worker_heartbeat_at", ["worker_heartbeat_at"]),
        ("session_color", ["session_color"]),
        ("transcript_path", ["transcript_path", "rollout_path"]),
        ("run_token", ["run_token"]),
        ("worker_heartbeat_epoch", ["worker_heartbeat_epoch"]),
        ("last_checkpoint_epoch", ["last_checkpoint_epoch"]),
        ("health_schema", ["health_schema"]),
        ("stop_requested_at", ["stop_requested_at"]),
    ]

    /// Emits fixed key/value pairs separated by NUL bytes. The final complete
    /// marker lets a Bash process-substitution consumer detect helper failure
    /// even though Bash cannot directly observe that producer's exit status.
    private static func metaSnapshot(
        _ arguments: [String],
        standardInput: Data?
    ) throws -> Data {
        guard arguments.count == 2 else {
            throw DetachStateCommandError.invalidArguments
        }
        let data = try inputData(
            atPath: arguments[0],
            standardInput: standardInput)
        guard let values = try SessionMetadataDocument.usableScalars(
            in: data,
            expectedSessionName: arguments[1],
            pathGroups: metadataSnapshotFields.map(\.1)) else {
            throw DetachStateCommandError.unusableMetadata
        }
        var output = Data()
        for ((name, _), value) in zip(metadataSnapshotFields, values) {
            appendNULTerminated(name, to: &output)
            appendNULTerminated(value.map(render) ?? "", to: &output)
        }
        appendNULTerminated("snapshot_complete", to: &output)
        appendNULTerminated("true", to: &output)
        return output
    }

    /// Enumerates one validated sessions root in one process. Output uses NUL
    /// delimiters so metadata values can contain tabs and newlines.
    private static func metaSnapshots(
        _ arguments: [String],
        standardInput _: Data?
    ) throws -> Data {
        guard arguments.count == 1
                || (arguments.count == 2
                    && arguments[1] == "--with-transcript-summary") else {
            throw DetachStateCommandError.invalidArguments
        }
        let includesTranscriptSummary = arguments.count == 2
        let sessions = try metadataSnapshots(at: arguments[0])
        var output = Data()
        for (session, values) in sessions {
            appendNULTerminated(session, to: &output)
            appendNULTerminated(values == nil ? "false" : "true", to: &output)
            for value in values ?? Array(repeating: nil, count: metadataSnapshotFields.count) {
                appendNULTerminated(value.map(render) ?? "", to: &output)
            }
            if includesTranscriptSummary {
                for value in transcriptSummarySnapshotValues(
                    session: session,
                    metadataValues: values) {
                    appendNULTerminated(value, to: &output)
                }
            }
        }
        appendNULTerminated("", to: &output)
        appendNULTerminated("true", to: &output)
        return output
    }

    /// Batches the bounded transcript tail parse into the metadata helper.
    /// The shell list path used to launch one helper process per session for
    /// these five values. A failed or absent transcript stays an empty summary
    /// and never invalidates the independently validated metadata record.
    private static func transcriptSummarySnapshotValues(
        session: String,
        metadataValues: [DetachStateScalar?]?
    ) -> [String] {
        let empty = Array(repeating: "", count: 5)
        guard let metadataValues,
              let transcriptIndex = metadataSnapshotFields.firstIndex(where: {
                  $0.0 == "transcript_path"
              }),
              metadataValues.indices.contains(transcriptIndex),
              case .string(let transcriptPath)? = metadataValues[transcriptIndex]
        else { return empty }

        let provider: Provider
        if session.hasPrefix("detach-codex-") {
            provider = .codex
        } else if session.hasPrefix("detach-claude-") {
            provider = .claude
        } else {
            return empty
        }
        // The removed shell path required a regular file before it read the
        // transcript. A FIFO or device here would block the whole list, so
        // open without blocking and check the opened descriptor itself.
        guard transcriptPath.hasPrefix("/"),
              let tail = try? regularFileTail(
                atPath: transcriptPath,
                maximumByteCount: 262_144) else { return empty }
        let summary = TranscriptDocument.summary(ofTail: tail, provider: provider)
        return [
            summary.model ?? "",
            summary.contextUsed.map(String.init) ?? "",
            summary.contextWindow.map(String.init) ?? "",
            summary.agentTurnState?.rawValue ?? "",
            summary.agentTurnID ?? "",
        ]
    }

    private static func metadataSnapshotValues(
        in directory: Int32,
        session: String
    ) throws -> [DetachStateScalar?]? {
        if let data = readOwnedMetadataFile(in: directory, name: "meta.json"),
           let values = try? SessionMetadataDocument.usableScalars(
            in: data,
            expectedSessionName: session,
            pathGroups: metadataSnapshotFields.map(\.1)) {
            return values
        }
        var checkpointMetadata = stat()
        let checkpointStatus = fstatat(
            directory, "checkpoint", &checkpointMetadata, AT_SYMLINK_NOFOLLOW)
        if checkpointStatus != 0 {
            guard errno == ENOENT else {
                throw DetachStateCommandError.invalidArguments
            }
            return nil
        }
        guard isDirectory(checkpointMetadata),
              !isSymbolicLink(checkpointMetadata),
              checkpointMetadata.st_uid == geteuid() else {
            throw DetachStateCommandError.invalidArguments
        }
        let checkpoint = openat(
            directory, "checkpoint", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard checkpoint >= 0 else {
            throw DetachStateCommandError.invalidArguments
        }
        defer { close(checkpoint) }
        var openedCheckpoint = stat()
        let checkpointMatches = fstat(checkpoint, &openedCheckpoint) == 0
            && isDirectory(openedCheckpoint)
            && openedCheckpoint.st_uid == geteuid()
            && openedCheckpoint.st_dev == checkpointMetadata.st_dev
            && openedCheckpoint.st_ino == checkpointMetadata.st_ino
        guard checkpointMatches else { throw DetachStateCommandError.invalidArguments }
        if let data = readOwnedMetadataFile(in: checkpoint, name: "meta.json") {
            if let values = try? SessionMetadataDocument.usableScalars(
                in: data,
                expectedSessionName: session,
                pathGroups: metadataSnapshotFields.map(\.1)) {
                return values
            }
        }
        return nil
    }

    static func metadataSnapshots(
        at root: String
    ) throws -> [(String, [DetachStateScalar?]?)] {
        let components = root.split(separator: "/", omittingEmptySubsequences: false)
        guard root.hasPrefix("/"),
              root != "/",
              !root.hasSuffix("/"),
              !root.contains("\n"),
              !root.contains("\r"),
              !components.contains("."),
              !components.contains("..") else {
            throw DetachStateCommandError.invalidArguments
        }
        let rootDescriptor = open(
            root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw DetachStateCommandError.invalidArguments
        }
        defer { close(rootDescriptor) }
        var rootMetadata = stat()
        let rootIsOwnedDirectory = fstat(rootDescriptor, &rootMetadata) == 0
            && isDirectory(rootMetadata)
            && rootMetadata.st_uid == geteuid()
        guard rootIsOwnedDirectory else { throw DetachStateCommandError.invalidArguments }
        let enumerationDescriptor = dup(rootDescriptor)
        guard enumerationDescriptor >= 0 else { throw DetachStateCommandError.invalidArguments }
        guard let directory = fdopendir(enumerationDescriptor) else {
            close(enumerationDescriptor); throw DetachStateCommandError.invalidArguments
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        var sessions: [(String, [DetachStateScalar?]?)] = []
        for name in names.sorted() {
            var item = stat()
            if fstatat(rootDescriptor, name, &item, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw DetachStateCommandError.invalidArguments }
                continue
            }
            if isSymbolicLink(item) {
                throw DetachStateCommandError.invalidArguments
            }
            guard isDirectory(item) else { continue }
            guard item.st_uid == geteuid(), validSessionIdentifier(name) else {
                throw DetachStateCommandError.invalidArguments
            }
            let session = openat(
                rootDescriptor, name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard session >= 0 else {
                throw DetachStateCommandError.invalidArguments
            }
            var opened = stat()
            let sessionMatches = fstat(session, &opened) == 0
                && isDirectory(opened)
                && opened.st_uid == geteuid()
                && opened.st_dev == item.st_dev
                && opened.st_ino == item.st_ino
            guard sessionMatches else {
                close(session); throw DetachStateCommandError.invalidArguments
            }
            let values: [DetachStateScalar?]?
            do {
                values = try metadataSnapshotValues(in: session, session: name)
            } catch {
                close(session)
                throw error
            }
            close(session)
            sessions.append((name, values))
        }
        return sessions
    }

    /// Returns only transcript files recorded by usable Detach metadata.
    /// The event watcher still observes the provider roots so it can follow
    /// files that appear after startup, but this allowlist prevents unrelated
    /// Codex or Claude sessions from waking the app.
    static func managedTranscriptPaths(
        atStateRoot stateRoot: String,
        allowedRoots: [String]
    ) -> Set<String> {
        managedTranscriptPaths(
            sessionsRoots: SessionEventWatchConfiguration
                .defaultSessionsRoots(stateRoot: stateRoot),
            allowedRoots: allowedRoots)
    }

    static func managedTranscriptPaths(
        sessionsRoots: [String],
        allowedRoots: [String]
    ) -> Set<String> {
        guard let transcriptIndex = metadataSnapshotFields.firstIndex(where: {
            $0.0 == "transcript_path"
        }) else { return [] }

        var result: Set<String> = []
        for sessionsRoot in sessionsRoots {
            guard let snapshots = try? metadataSnapshots(at: sessionsRoot) else {
                continue
            }
            for (_, values) in snapshots {
                guard let values,
                      values.indices.contains(transcriptIndex),
                      case .string(let rawPath)? = values[transcriptIndex] else {
                    continue
                }
                let standardized = URL(fileURLWithPath: rawPath)
                    .standardizedFileURL.path
                guard standardized == rawPath else { continue }
                let path = SessionEventWatchConfiguration.canonicalPath(rawPath)
                guard allowedRoots.contains(where: {
                    path == $0 || path.hasPrefix($0 + "/")
                }) else { continue }
                result.insert(path)
            }
        }
        return result
    }

    private static func readOwnedMetadataFile(
        in directory: Int32,
        name: String
    ) -> Data? {
        let descriptor = openat(
            directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var item = stat()
        let maximumBytes: off_t = 1_048_576
        guard fstat(descriptor, &item) == 0,
              isRegularFile(item),
              item.st_uid == geteuid(),
              item.st_size >= 0,
              item.st_size <= maximumBytes else { return nil }
        var data = Data(count: Int(item.st_size))
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return item.st_size == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
        return complete ? data : nil
    }

    private static func isDirectory(_ item: stat) -> Bool {
        item.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ item: stat) -> Bool {
        item.st_mode & S_IFMT == S_IFREG
    }

    private static func isSymbolicLink(_ item: stat) -> Bool {
        item.st_mode & S_IFMT == S_IFLNK
    }

    private static func validSessionIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("detach-codex-") || value.hasPrefix("detach-claude-") else {
            return false
        }
        let prefix = value.hasPrefix("detach-codex-") ? "detach-codex-" : "detach-claude-"
        let suffix = value.dropFirst(prefix.count)
        guard (1...48).contains(suffix.utf8.count),
              let first = suffix.utf8.first,
              asciiAlphanumeric(first) else { return false }
        return suffix.utf8.dropFirst().allSatisfy {
            asciiAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func asciiAlphanumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
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

    private struct TranscriptValidationIdentity: Codable, Equatable {
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64

        init?(_ item: stat) {
            guard isRegularFile(item),
                  item.st_uid == geteuid(),
                  item.st_size > 0 else { return nil }
            device = UInt64(item.st_dev)
            inode = UInt64(item.st_ino)
            size = Int64(item.st_size)
            modificationSeconds = Int64(item.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(item.st_mtimespec.tv_nsec)
        }
    }

    private struct TranscriptValidationReceipt: Codable, Equatable {
        var schema: Int
        var provider: String
        var expectedSessionID: String
        var valid: Bool
        var identity: TranscriptValidationIdentity
    }

    /// Caches only a health assessment for one immutable checkpoint file.
    /// Restore paths continue to use `jsonl validate` and parse every record.
    /// The receipt is ignored as soon as any opened-file identity field changes.
    private static func jsonlValidateCached(_ arguments: [String]) throws -> Data {
        guard arguments.count == 3 else {
            throw DetachStateCommandError.invalidArguments
        }
        let selectedProvider = try provider(arguments[0])
        let path = arguments[1]
        let expectedSessionID = arguments[2]
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.contains("\n"),
              !path.contains("\r"),
              !components.contains("."),
              !components.contains(".."),
              !expectedSessionID.isEmpty else {
            throw DetachStateCommandError.invalidArguments
        }

        let url = fileURL(path)
        let parentPath = url.deletingLastPathComponent().path
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty,
              fileName.utf8.count <= Int(NAME_MAX) else {
            throw DetachStateCommandError.invalidArguments
        }
        let directory = open(
            parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw DetachStateCommandError.invalidTranscript
        }
        defer { close(directory) }
        var directoryMetadata = stat()
        guard fstat(directory, &directoryMetadata) == 0,
              isDirectory(directoryMetadata),
              directoryMetadata.st_uid == geteuid() else {
            throw DetachStateCommandError.invalidTranscript
        }

        let descriptor = openat(
            directory, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DetachStateCommandError.invalidTranscript
        }
        defer { close(descriptor) }
        var beforeMetadata = stat()
        guard fstat(descriptor, &beforeMetadata) == 0,
              let before = TranscriptValidationIdentity(beforeMetadata) else {
            throw DetachStateCommandError.invalidTranscript
        }

        let receiptName = ".detach-jsonl-validation.json"
        if let receiptData = readOwnedMetadataFile(
                in: directory, name: receiptName),
           let receipt = try? JSONDecoder().decode(
                TranscriptValidationReceipt.self, from: receiptData),
           receipt.schema == 1,
           receipt.provider == selectedProvider.rawValue,
           receipt.expectedSessionID == expectedSessionID,
           receipt.identity == before {
            guard receipt.valid else {
                throw DetachStateCommandError.invalidTranscript
            }
            return Data()
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let valid = try TranscriptDocument.isValid(
            reading: handle,
            provider: selectedProvider,
            expectedSessionID: expectedSessionID)
        var afterMetadata = stat()
        guard fstat(descriptor, &afterMetadata) == 0,
              let after = TranscriptValidationIdentity(afterMetadata),
              before == after else {
            throw DetachStateCommandError.invalidTranscript
        }

        let receipt = TranscriptValidationReceipt(
            schema: 1,
            provider: selectedProvider.rawValue,
            expectedSessionID: expectedSessionID,
            valid: valid,
            identity: after)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if var receiptData = try? encoder.encode(receipt) {
            receiptData.append(0x0A)
            try? replaceOwnedFileAtomically(
                receiptData, in: directory, name: receiptName)
        }
        guard valid else {
            throw DetachStateCommandError.invalidTranscript
        }
        return Data()
    }

    private static func replaceOwnedFileAtomically(
        _ data: Data,
        in directory: Int32,
        name: String
    ) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw DetachStateCommandError.invalidArguments
        }
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DetachStateCommandError.invalidArguments
        }
        defer {
            close(descriptor)
            unlinkat(directory, temporaryName, 0)
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              renameat(directory, temporaryName, directory, name) == 0 else {
            throw DetachStateCommandError.invalidArguments
        }
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

    private static func appendNULTerminated(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
        data.append(0)
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

    /// Reads the tail of one regular file without a path race. The
    /// non-blocking open cannot stall on a FIFO or device, and the check runs
    /// on the descriptor that is read, not on a name that may be replaced.
    private static func regularFileTail(
        atPath path: String,
        maximumByteCount: UInt64
    ) throws -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              isRegularFile(metadata),
              metadata.st_size > 0 else { return nil }
        let size = UInt64(metadata.st_size)
        try handle.seek(toOffset: size > maximumByteCount ? size - maximumByteCount : 0)
        return try handle.readToEnd() ?? Data()
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
