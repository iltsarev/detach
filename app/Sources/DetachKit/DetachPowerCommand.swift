import Darwin
import Foundation

/// Stable identity for one helper-managed power lease.
public struct PowerLeaseIdentity: Equatable, Hashable, Sendable {
    public let sessionName: String
    public let runToken: String

    public init(sessionName: String, runToken: String) {
        self.sessionName = sessionName
        self.runToken = runToken
    }
}

/// Synchronous client boundary for the privileged closed-lid helper.
///
/// Implementations must be safe to call from the heartbeat runner as well as
/// the command's main thread.
public protocol PowerHelperClient: Sendable {
    func status() throws -> PowerProtectionStatus
    func acquireLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool
    func renewLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool
    func releaseLease(_ identity: PowerLeaseIdentity) throws
}

public struct ChildCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct ChildCommandResult: Equatable, Sendable {
    public let exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

public protocol ChildCommandRunning: Sendable {
    func run(_ command: ChildCommand) throws -> ChildCommandResult
}

public protocol PowerRunReadinessMarking: Sendable {
    func markReady(atPath path: String) throws
}

public struct FilePowerRunReadinessMarker: PowerRunReadinessMarking {
    public init() {}

    public func markReady(atPath path: String) throws {
        try Data().write(
            to: URL(fileURLWithPath: path),
            options: [.atomic])
    }
}

public struct ChildProcessRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL
    public let inheritsStandardIO: Bool

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        inheritsStandardIO: Bool
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.inheritsStandardIO = inheritsStandardIO
    }
}

public protocol ChildProcessLaunching: Sendable {
    func run(_ request: ChildProcessRequest) throws -> Int32
}

public struct POSIXChildProcessLauncher: ChildProcessLaunching {
    private final class ForwardedSignalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?

        func record(_ signal: Int32) {
            lock.lock()
            if value == nil {
                value = signal
            }
            lock.unlock()
        }

        var firstSignal: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public init() {}

    public func run(_ request: ChildProcessRequest) throws -> Int32 {
        let childPID = try spawn(request)

        // Install forwarding only after launch so the provider inherits the
        // default signal dispositions. `detach stop` signals the whole tmux
        // process group; keeping this wrapper alive lets the lease/assertion
        // cleanup unwind after the provider exits.
        let forwardedSignal = ForwardedSignalBox()
        let signalQueue = DispatchQueue(label: "dev.tsarev.detach.power-signals")
        let signalNumbers: [Int32] = [SIGHUP, SIGINT, SIGTERM]
        let previousHandlers = signalNumbers.map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
        }
        let signalSources = signalNumbers.map { signalNumber in
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: signalQueue)
            source.setEventHandler {
                forwardedSignal.record(signalNumber)
                _ = Darwin.kill(childPID, signalNumber)
            }
            source.resume()
            return source
        }

        let waitResult: Result<Int32, Error>
        do {
            waitResult = .success(try wait(for: childPID))
        } catch {
            waitResult = .failure(error)
        }
        signalSources.forEach { $0.cancel() }
        signalQueue.sync {}
        for (signalNumber, previousHandler) in zip(
            signalNumbers, previousHandlers)
        {
            Darwin.signal(signalNumber, previousHandler)
        }

        let waitStatus = try waitResult.get()
        if let signalNumber = forwardedSignal.firstSignal {
            return 128 + signalNumber
        }
        let terminationStatus = waitStatus & 0x7f
        if terminationStatus == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if terminationStatus != 0x7f {
            return 128 + terminationStatus
        }
        throw posixError(
            ECHILD,
            operation: "waitpid returned an unsupported child status")
    }

    private func spawn(_ request: ChildProcessRequest) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        let initializeResult = posix_spawn_file_actions_init(&fileActions)
        guard initializeResult == 0 else {
            throw posixError(
                initializeResult,
                operation: "posix_spawn_file_actions_init")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        let changeDirectoryResult = request.currentDirectoryURL.path.withCString {
            path in
            if #available(macOS 26.0, *) {
                return posix_spawn_file_actions_addchdir(&fileActions, path)
            }
            return posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        guard changeDirectoryResult == 0 else {
            throw posixError(
                changeDirectoryResult,
                operation: "posix_spawn_file_actions_addchdir")
        }

        let argumentStrings =
            [request.executableURL.path] + request.arguments
        let environmentStrings = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var childPID: pid_t = 0
        let spawnResult = try withCStringArray(argumentStrings) {
            argumentPointers in
            try withCStringArray(environmentStrings) {
                environmentPointers in
                request.executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &childPID,
                        executablePath,
                        &fileActions,
                        nil,
                        argumentPointers,
                        environmentPointers)
                }
            }
        }
        guard spawnResult == 0 else {
            throw posixError(spawnResult, operation: "posix_spawn")
        }
        return childPID
    }

    private func wait(for childPID: pid_t) throws -> Int32 {
        var waitStatus: Int32 = 0
        while true {
            let result = waitpid(childPID, &waitStatus, 0)
            if result == childPID {
                return waitStatus
            }
            if result == -1, errno == EINTR {
                continue
            }
            throw posixError(errno, operation: "waitpid")
        }
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        for string in strings {
            guard let pointer = strdup(string) else {
                throw posixError(ENOMEM, operation: "strdup")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw posixError(EINVAL, operation: "CString array")
            }
            return try body(baseAddress)
        }
    }

    private func posixError(
        _ code: Int32,
        operation: String
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation): \(String(cString: strerror(code)))"
            ])
    }
}

/// POSIX-backed child runner used by the `detach-power` executable. The child
/// deliberately inherits the wrapper's process group so interactive providers
/// remain in the tmux pane's foreground process group.
public struct ProcessChildCommandRunner: ChildCommandRunning {
    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let launcher: any ChildProcessLaunching

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true),
        launcher: any ChildProcessLaunching = POSIXChildProcessLauncher()
    ) {
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.launcher = launcher
    }

    public func run(_ command: ChildCommand) throws -> ChildCommandResult {
        let executableURL: URL
        let arguments: [String]
        if command.executable.contains("/") {
            executableURL = URL(fileURLWithPath: command.executable)
            arguments = command.arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            arguments = [command.executable] + command.arguments
        }
        let exitCode = try launcher.run(ChildProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            inheritsStandardIO: true))
        return ChildCommandResult(exitCode: exitCode)
    }
}

/// Runs an operation while periodically invoking its renewable-lease callback.
public protocol PowerHeartbeatRunning: Sendable {
    func run(
        heartbeat: @escaping @Sendable () throws -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult
}

private final class HeartbeatFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func clear() {
        lock.lock()
        storedError = nil
        lock.unlock()
    }
}

/// Dispatch-backed production heartbeat. Transient renewal failures keep
/// retrying and clear after a confirmed renewal. A still-active failure is
/// surfaced after the child finishes; cleanup is always performed by
/// ``DetachPowerCommand``.
public final class DispatchPowerHeartbeatRunner: PowerHeartbeatRunning, @unchecked Sendable {
    public static let defaultInterval: TimeInterval = 30

    private let intervalMilliseconds: Int
    private let queue: DispatchQueue

    public init(
        interval: TimeInterval = DispatchPowerHeartbeatRunner.defaultInterval,
        queue: DispatchQueue = DispatchQueue(label: "dev.tsarev.detach.power-heartbeat")
    ) {
        intervalMilliseconds = max(1, Int(interval * 1_000))
        self.queue = queue
    }

    public func run(
        heartbeat: @escaping @Sendable () throws -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult {
        let failure = HeartbeatFailureBox()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(intervalMilliseconds)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            do {
                try heartbeat()
                failure.clear()
            } catch {
                failure.record(error)
            }
        }
        timer.resume()

        let operationResult = Result { try operation() }
        timer.cancel()
        // Drain any handler already enqueued before inspecting its result.
        queue.sync {}

        switch operationResult {
        case let .failure(error):
            throw error
        case let .success(result):
            if let heartbeatError = failure.error {
                throw heartbeatError
            }
            return result
        }
    }
}

/// Versioned JSON representation emitted by `detach power status --json`.
public struct DetachPowerStatusReport: Equatable, Codable, Sendable {
    public let schema: Int
    public let state: PowerProtectionState
    public let leaseCount: Int
    public let assertionActive: Bool
    public let closedLidProtectionActive: Bool
    public let helperReachable: Bool
    public let transitionInProgress: Bool
    public let lowBattery: Bool

    public init(status: PowerProtectionStatus) {
        schema = 1
        state = status.state
        leaseCount = status.leaseCount
        assertionActive = status.assertionActive
        closedLidProtectionActive = status.closedLidProtectionActive
        helperReachable = status.helperReachable
        transitionInProgress = status.transitionInProgress
        lowBattery = status.lowBattery
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case state
        case leaseCount = "lease_count"
        case assertionActive = "assertion_active"
        case closedLidProtectionActive = "closed_lid_protection_active"
        case helperReachable = "helper_reachable"
        case transitionInProgress = "transition_in_progress"
        case lowBattery = "low_battery"
    }
}

public enum DetachPowerCommandResult: Equatable, Sendable {
    case statusJSON(Data)
    case child(ChildCommandResult)
    case lifecycle

    public var exitCode: Int32 {
        switch self {
        case .statusJSON:
            return 0
        case let .child(result):
            return result.exitCode
        case .lifecycle:
            return 0
        }
    }
}

public enum DetachPowerCommandError: Error, Equatable, Sendable {
    case usage(String)
    case assertionUnavailable
    case helperLeaseUnavailable
}

extension DetachPowerCommandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .usage(message):
            return message
        case .assertionUnavailable:
            return "idle-sleep protection could not be acquired"
        case .helperLeaseUnavailable:
            return "closed-lid protection lease could not be confirmed"
        }
    }
}

/// Parser and lifecycle coordinator for the unprivileged `detach-power`
/// command. It does not communicate with IOKit or launch children directly;
/// all effects cross injectable protocol boundaries.
public struct DetachPowerCommand: Sendable {
    private let helperClient: any PowerHelperClient
    private let assertionController: any IdleSleepAssertionControlling
    private let childRunner: any ChildCommandRunning
    private let heartbeatRunner: any PowerHeartbeatRunning
    private let readinessMarker: any PowerRunReadinessMarking

    public init(
        helperClient: any PowerHelperClient,
        assertionController: any IdleSleepAssertionControlling = PowerAssertionController(),
        childRunner: any ChildCommandRunning = ProcessChildCommandRunner(),
        heartbeatRunner: any PowerHeartbeatRunning = DispatchPowerHeartbeatRunner(),
        readinessMarker: any PowerRunReadinessMarking = FilePowerRunReadinessMarker()
    ) {
        self.helperClient = helperClient
        self.assertionController = assertionController
        self.childRunner = childRunner
        self.heartbeatRunner = heartbeatRunner
        self.readinessMarker = readinessMarker
    }

    public func execute(arguments: [String]) throws -> DetachPowerCommandResult {
        switch arguments.first {
        case "status":
            guard arguments == ["status", "--json"] else {
                throw DetachPowerCommandError.usage("usage: detach-power status --json")
            }
            let report = DetachPowerStatusReport(status: try helperClient.status())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return .statusJSON(try encoder.encode(report))
        case "run":
            let parsed = try parseRunArguments(Array(arguments.dropFirst()))
            return try executeRun(
                identity: parsed.identity,
                command: parsed.command,
                readyFile: parsed.readyFile)
        case "helper":
            guard let lifecycleClient = helperClient
                    as? any PowerHelperLifecycleClient else {
                throw DetachPowerCommandError.usage(
                    "power helper lifecycle client is unavailable")
            }
            switch Array(arguments.dropFirst()) {
            case ["prepare-unregistration"]:
                try lifecycleClient.prepareForUnregistration()
                return .lifecycle
            case ["cancel-unregistration"]:
                try lifecycleClient.cancelUnregistration()
                return .lifecycle
            default:
                throw DetachPowerCommandError.usage(
                    "usage: detach-power helper "
                        + "prepare-unregistration|cancel-unregistration")
            }
        case "release":
            let identity = try parseIdentityArguments(
                Array(arguments.dropFirst()))
            try helperClient.releaseLease(identity)
            return .lifecycle
        default:
            throw DetachPowerCommandError.usage(
                "usage: detach-power status --json | detach-power run "
                    + "--session NAME --run-token TOKEN "
                    + "[--ready-file ABSOLUTE_PATH] -- COMMAND [ARGS...] "
                    + "| detach-power helper "
                    + "prepare-unregistration|cancel-unregistration "
                    + "| detach-power release --session NAME "
                    + "--run-token TOKEN")
        }
    }

    private func executeRun(
        identity: PowerLeaseIdentity,
        command: ChildCommand,
        readyFile: String?
    ) throws -> DetachPowerCommandResult {
        // Both release methods are idempotent. Register cleanup before each
        // acquire so even a partially successful backend operation is paired
        // with a best-effort release.
        defer { _ = try? assertionController.release() }
        _ = try assertionController.acquire()
        guard assertionController.isActive else {
            throw DetachPowerCommandError.assertionUnavailable
        }

        defer { try? helperClient.releaseLease(identity) }
        guard try helperClient.acquireLease(identity, assertionActive: true) else {
            throw DetachPowerCommandError.helperLeaseUnavailable
        }
        guard assertionController.isActive else {
            throw DetachPowerCommandError.assertionUnavailable
        }

        if let readyFile {
            try readinessMarker.markReady(atPath: readyFile)
        }

        let result = try heartbeatRunner.run(
            heartbeat: {
                try renewProtection(identity: identity)
            },
            operation: {
                try childRunner.run(command)
            })
        return .child(result)
    }

    private func renewProtection(identity: PowerLeaseIdentity) throws {
        if !assertionController.isActive {
            let status = try helperClient.status()
            if status.lowBattery {
                _ = try helperClient.renewLease(
                    identity, assertionActive: false)
                return
            }
            _ = try assertionController.acquire()
        }
        guard assertionController.isActive else {
            throw DetachPowerCommandError.assertionUnavailable
        }
        guard try helperClient.renewLease(
            identity, assertionActive: true) else {
            let status = try helperClient.status()
            guard status.lowBattery else {
                throw DetachPowerCommandError.helperLeaseUnavailable
            }
            _ = try assertionController.release()
            _ = try helperClient.renewLease(
                identity, assertionActive: false)
            return
        }
    }

    private func parseRunArguments(
        _ arguments: [String]
    ) throws -> (
        identity: PowerLeaseIdentity,
        command: ChildCommand,
        readyFile: String?
    ) {
        var sessionName: String?
        var runToken: String?
        var readyFile: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let child = Array(arguments.dropFirst(index + 1))
                guard let executable = child.first, !executable.isEmpty else {
                    throw DetachPowerCommandError.usage("run requires a child command after --")
                }
                guard let sessionName, !sessionName.isEmpty else {
                    throw DetachPowerCommandError.usage("run requires --session NAME")
                }
                guard let runToken, !runToken.isEmpty else {
                    throw DetachPowerCommandError.usage("run requires --run-token TOKEN")
                }
                return (
                    PowerLeaseIdentity(sessionName: sessionName, runToken: runToken),
                    ChildCommand(executable: executable, arguments: Array(child.dropFirst())),
                    readyFile)
            }

            switch argument {
            case "--session":
                guard sessionName == nil, index + 1 < arguments.count else {
                    throw DetachPowerCommandError.usage("run requires one --session NAME")
                }
                sessionName = arguments[index + 1]
                index += 2
            case "--run-token":
                guard runToken == nil, index + 1 < arguments.count else {
                    throw DetachPowerCommandError.usage("run requires one --run-token TOKEN")
                }
                runToken = arguments[index + 1]
                index += 2
            case "--ready-file":
                guard readyFile == nil, index + 1 < arguments.count,
                      arguments[index + 1].hasPrefix("/") else {
                    throw DetachPowerCommandError.usage(
                        "--ready-file requires one absolute path")
                }
                readyFile = arguments[index + 1]
                index += 2
            default:
                throw DetachPowerCommandError.usage("unknown run option: \(argument)")
            }
        }

        throw DetachPowerCommandError.usage("run requires -- COMMAND [ARGS...]")
    }

    private func parseIdentityArguments(
        _ arguments: [String]
    ) throws -> PowerLeaseIdentity {
        var sessionName: String?
        var runToken: String?
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw DetachPowerCommandError.usage(
                    "release requires --session NAME and --run-token TOKEN")
            }
            switch arguments[index] {
            case "--session" where sessionName == nil:
                sessionName = arguments[index + 1]
            case "--run-token" where runToken == nil:
                runToken = arguments[index + 1]
            default:
                throw DetachPowerCommandError.usage(
                    "unknown or duplicate release option: \(arguments[index])")
            }
            index += 2
        }
        guard let sessionName, !sessionName.isEmpty,
              let runToken, !runToken.isEmpty else {
            throw DetachPowerCommandError.usage(
                "release requires --session NAME and --run-token TOKEN")
        }
        return PowerLeaseIdentity(
            sessionName: sessionName, runToken: runToken)
    }
}
