import Darwin
import Foundation

// Swift imports Darwin's `struct flock` under the same name as flock(2), so
// bind the process-scoped BSD syscall explicitly.
@_silgen_name("flock")
private func systemFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

public struct RootCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct RootCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol RootCommandRunning: Sendable {
    func run(_ command: RootCommand) throws -> RootCommandResult
}

private final class BoundedRootCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < maximumBytes else { return }
        data.append(chunk.prefix(maximumBytes - data.count))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct RootProcessCommandRunner: RootCommandRunning {
    public static let defaultTimeout: TimeInterval = 2
    public static let defaultTerminationGrace: TimeInterval = 1
    public static let defaultMaximumOutputBytes = 65_536

    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let maximumOutputBytes: Int

    public init(
        timeout: TimeInterval = RootProcessCommandRunner.defaultTimeout,
        terminationGrace: TimeInterval =
            RootProcessCommandRunner.defaultTerminationGrace,
        maximumOutputBytes: Int =
            RootProcessCommandRunner.defaultMaximumOutputBytes
    ) {
        self.timeout = max(0.01, timeout)
        self.terminationGrace = max(0.01, terminationGrace)
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    public func run(_ command: RootCommand) throws -> RootCommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let output = BoundedRootCommandOutput(
            maximumBytes: maximumOutputBytes)
        let errorOutput = BoundedRootCommandOutput(
            maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()
        Self.drain(stdout.fileHandleForReading, into: output, group: readers)
        Self.drain(stderr.fileHandleForReading, into: errorOutput, group: readers)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(terminationGrace)
            while process.isRunning && Date() < killDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        readers.wait()
        if timedOut {
            throw PowerHelperPlatformError.commandTimedOut(
                executable: command.executable)
        }
        return RootCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: output.string,
            standardError: errorOutput.string)
    }

    private static func drain(
        _ handle: FileHandle,
        into output: BoundedRootCommandOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                guard let chunk = try? handle.read(upToCount: 4_096),
                      !chunk.isEmpty else { return }
                output.append(chunk)
            }
        }
    }
}

public enum PowerHelperPlatformError: Error, Equatable, Sendable {
    case commandFailed(executable: String, exitCode: Int32, message: String)
    case unrecognizedPMSetOutput
    case insecureStatePath
    case stateTooLarge
    case fileSystem(operation: String, code: Int32)
    case bootSessionUnavailable(code: Int32)
    case unrecognizedBootSession
    case commandTimedOut(executable: String)
    case insecureLifetimeLock
    case lifetimeLockBusy
    case lifetimeLockFileSystem(operation: String, code: Int32)
    case insecureSystemHandoffLock
    case systemHandoffLockBusy
    case systemHandoffLockFileSystem(operation: String, code: Int32)
}

extension PowerHelperPlatformError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .commandFailed(executable, exitCode, message):
            let suffix = message.isEmpty ? "" : ": \(message)"
            return "\(executable) failed with status \(exitCode)\(suffix)"
        case .unrecognizedPMSetOutput:
            return "pmset returned an unrecognized power status"
        case .insecureStatePath:
            return "power helper state path is not secure"
        case .stateTooLarge:
            return "power helper state file is too large"
        case let .fileSystem(operation, code):
            return "power helper state \(operation) failed with errno \(code)"
        case let .bootSessionUnavailable(code):
            return "boot session lookup failed with errno \(code)"
        case .unrecognizedBootSession:
            return "macOS returned an invalid boot session identifier"
        case let .commandTimedOut(executable):
            return "\(executable) timed out"
        case .insecureLifetimeLock:
            return "power helper lifetime lock is not secure"
        case .lifetimeLockBusy:
            return "another power helper process still holds the lifetime lock"
        case let .lifetimeLockFileSystem(operation, code):
            return "power helper lifetime lock \(operation) failed with errno \(code)"
        case .insecureSystemHandoffLock:
            return "power helper system handoff lock is not secure"
        case .systemHandoffLockBusy:
            return "another user is already updating the power helper"
        case let .systemHandoffLockFileSystem(operation, code):
            return "power helper system handoff lock \(operation) failed with errno \(code)"
        }
    }
}

public enum PowerHelperLifetimeBarrierStatus: Equatable, Sendable {
    /// The stable file exists and no process holds its kernel lock.
    case released
    /// A helper process still holds the exclusive kernel lock.
    case busy
    /// The stable file does not exist. Callers must decide whether their
    /// durable transaction and boot-session evidence make that safe.
    case missing
}

/// Ownership token whose descriptor holds the helper's exclusive kernel lock.
/// The lock is deliberately released only when this object is destroyed or the
/// process exits; the stable file itself is never unlinked.
public final class PowerHelperLifetimeBarrierLease: @unchecked Sendable {
    let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = systemFileLock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }
}

/// Kernel-backed process-lifetime barrier shared by the root helper and app.
/// The helper creates and exclusively locks a fixed root-owned `0644` file.
/// The app opens the same file read-only and attempts `LOCK_EX | LOCK_NB`, so
/// probing never creates, writes, chmods, or unlinks filesystem state.
public struct PowerHelperLifetimeBarrier: Sendable {
    public static let defaultFileURL = URL(
        fileURLWithPath: "/var/run/dev.tsarev.detach.power-helper.lock")

    private static let requiredMode: mode_t = 0o644
    private let fileURL: URL
    private let expectedOwner: UInt32

    public init(
        fileURL: URL = PowerHelperLifetimeBarrier.defaultFileURL,
        expectedOwner: UInt32 = 0
    ) {
        self.fileURL = fileURL
        self.expectedOwner = expectedOwner
    }

    /// Acquires the helper side of the barrier without waiting. A second root
    /// helper fails closed instead of running concurrently with the first.
    public func acquire() throws -> PowerHelperLifetimeBarrierLease {
        let descriptor = try openForAcquisition()
        do {
            try validate(descriptor)
            guard systemFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if Self.isBusyError(code) {
                    throw PowerHelperPlatformError.lifetimeLockBusy
                }
                throw PowerHelperPlatformError.lifetimeLockFileSystem(
                    operation: "flock", code: code)
            }
            return PowerHelperLifetimeBarrierLease(
                fileDescriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Non-mutating app-side probe. Missing is distinct from released so a
    /// same-boot interrupted transaction can fail closed; a later boot can use
    /// its separately persisted boot-session evidence to accept `.missing`.
    public func status() throws -> PowerHelperLifetimeBarrierStatus {
        let descriptor = Darwin.open(
            fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            if code == ELOOP {
                throw PowerHelperPlatformError.insecureLifetimeLock
            }
            throw PowerHelperPlatformError.lifetimeLockFileSystem(
                operation: "open", code: code)
        }
        defer { _ = Darwin.close(descriptor) }
        try validate(descriptor)

        guard systemFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if Self.isBusyError(code) { return .busy }
            throw PowerHelperPlatformError.lifetimeLockFileSystem(
                operation: "flock", code: code)
        }
        defer { _ = systemFileLock(descriptor, LOCK_UN) }
        return .released
    }

    /// Convenience for callers that do not need to distinguish busy from
    /// missing. Missing intentionally returns false.
    public func isReleased() throws -> Bool {
        try status() == .released
    }

    private func openForAcquisition() throws -> Int32 {
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Darwin.open(
            fileURL.path, createFlags, Self.requiredMode)
        if descriptor >= 0 {
            guard Darwin.fchmod(descriptor, Self.requiredMode) == 0 else {
                let code = errno
                _ = Darwin.close(descriptor)
                throw PowerHelperPlatformError.lifetimeLockFileSystem(
                    operation: "fchmod", code: code)
            }
            return descriptor
        }

        let createError = errno
        guard createError == EEXIST else {
            if createError == ELOOP {
                throw PowerHelperPlatformError.insecureLifetimeLock
            }
            throw PowerHelperPlatformError.lifetimeLockFileSystem(
                operation: "create", code: createError)
        }
        descriptor = Darwin.open(
            fileURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw PowerHelperPlatformError.insecureLifetimeLock
            }
            throw PowerHelperPlatformError.lifetimeLockFileSystem(
                operation: "open", code: code)
        }
        return descriptor
    }

    private func validate(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw PowerHelperPlatformError.lifetimeLockFileSystem(
                operation: "fstat", code: errno)
        }
        let mode = metadata.st_mode
        guard (mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              UInt32(metadata.st_uid) == expectedOwner,
              (mode & mode_t(0o777)) == Self.requiredMode else {
            throw PowerHelperPlatformError.insecureLifetimeLock
        }
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0 else {
            throw PowerHelperPlatformError.lifetimeLockFileSystem(
                operation: "fcntl", code: errno)
        }
        guard descriptorFlags & FD_CLOEXEC != 0 else {
            throw PowerHelperPlatformError.insecureLifetimeLock
        }
    }

    private static func isBusyError(_ code: Int32) -> Bool {
        code == EWOULDBLOCK || code == EAGAIN
    }
}

/// Ownership token for the machine-wide app-side helper replacement lock.
/// Unlike a per-user journal lock, this root-created inode is shared by every
/// logged-in user. The kernel releases the lock if the owning app crashes.
public final class PowerHelperSystemHandoffLease: @unchecked Sendable {
    private let fileDescriptor: Int32

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = systemFileLock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }
}

/// A root-created, world-readable but immutable-by-users inode used only as a
/// BSD `flock` rendezvous. Apps open it read-only and hold an exclusive lock
/// across the complete asynchronous SMAppService unregister/register handoff.
/// This serializes app processes belonging to different logged-in users.
public struct PowerHelperSystemHandoffLock: Sendable {
    public static let defaultFileURL = URL(
        fileURLWithPath: "/var/run/dev.tsarev.detach.power-helper.handoff.lock")

    private static let requiredMode: mode_t = 0o644
    private let fileURL: URL
    private let expectedOwner: UInt32

    public init(
        fileURL: URL = PowerHelperSystemHandoffLock.defaultFileURL,
        expectedOwner: UInt32 = 0
    ) {
        self.fileURL = fileURL
        self.expectedOwner = expectedOwner
    }

    /// Called by the privileged helper before it accepts XPC. Existing paths
    /// are validated, never repaired or replaced, so every user sees one stable
    /// kernel inode for the whole boot.
    public func ensureExists() throws {
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Darwin.open(
            fileURL.path, createFlags, Self.requiredMode)
        var created = descriptor >= 0
        if descriptor < 0 {
            let createError = errno
            guard createError == EEXIST else {
                if createError == ELOOP {
                    throw PowerHelperPlatformError.insecureSystemHandoffLock
                }
                throw fileSystemError("create", createError)
            }
            descriptor = Darwin.open(
                fileURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            created = false
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw PowerHelperPlatformError.insecureSystemHandoffLock
            }
            throw fileSystemError("open", code)
        }
        defer { _ = Darwin.close(descriptor) }

        if created {
            guard Darwin.fchmod(descriptor, Self.requiredMode) == 0 else {
                throw fileSystemError("fchmod", errno)
            }
        }
        try validate(descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw fileSystemError("fsync", errno)
        }
        if created {
            let directory = fileURL.deletingLastPathComponent()
            let directoryDescriptor = Darwin.open(
                directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryDescriptor >= 0 else {
                throw fileSystemError("open directory", errno)
            }
            defer { _ = Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw fileSystemError("fsync directory", errno)
            }
        }
    }

    /// Returns nil only before any helper from this protocol generation has
    /// created the root-owned rendezvous file. That pristine-install shape is
    /// handled separately by the app; an existing file is never recreated.
    public func acquire() throws -> PowerHelperSystemHandoffLease? {
        let descriptor = Darwin.open(
            fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP {
                throw PowerHelperPlatformError.insecureSystemHandoffLock
            }
            throw fileSystemError("open", code)
        }
        do {
            try validate(descriptor)
            guard systemFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw PowerHelperPlatformError.systemHandoffLockBusy
                }
                throw fileSystemError("flock", code)
            }
            return PowerHelperSystemHandoffLease(fileDescriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func validate(_ descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw fileSystemError("fstat", errno)
        }
        let mode = metadata.st_mode
        guard mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              UInt32(metadata.st_uid) == expectedOwner,
              mode & mode_t(0o777) == Self.requiredMode else {
            throw PowerHelperPlatformError.insecureSystemHandoffLock
        }
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0 else { throw fileSystemError("fcntl", errno) }
        guard flags & FD_CLOEXEC != 0 else {
            throw PowerHelperPlatformError.insecureSystemHandoffLock
        }
    }

    private func fileSystemError(
        _ operation: String,
        _ code: Int32
    ) -> PowerHelperPlatformError {
        .systemHandoffLockFileSystem(operation: operation, code: code)
    }
}

/// Reads the kernel's per-boot UUID without launching a process. The value
/// changes across reboot and remains stable across login/logout.
public struct SysctlBootSessionReader: PowerBootSessionReading {
    public init() {}

    public func currentBootSessionIdentifier() throws -> String {
        let name = "kern.bootsessionuuid"
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            throw PowerHelperPlatformError.bootSessionUnavailable(code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname(name, bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            throw PowerHelperPlatformError.bootSessionUnavailable(code: errno)
        }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        guard UUID(uuidString: value) != nil else {
            throw PowerHelperPlatformError.unrecognizedBootSession
        }
        return value.lowercased()
    }
}

/// Root-only adapter for the narrow closed-lid setting. No shell is involved,
/// and every write is limited to `pmset -a disablesleep 0|1`.
public struct PMSetClosedLidProtectionController: ClosedLidProtectionControlling {
    private let runner: any RootCommandRunning

    public init(runner: any RootCommandRunning = RootProcessCommandRunner()) {
        self.runner = runner
    }

    public func protectionIsEnabled() throws -> Bool {
        let result = try runPMSet(["-g"])
        let matchingLines = result.standardOutput.split(whereSeparator: \.isNewline)
            .filter { line in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard let name = fields.first?.lowercased() else { return false }
                return name == "sleepdisabled" || name == "disablesleep"
            }
        guard matchingLines.count <= 1 else {
            throw PowerHelperPlatformError.unrecognizedPMSetOutput
        }
        guard let line = matchingLines.first else { return false }
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2 else {
            throw PowerHelperPlatformError.unrecognizedPMSetOutput
        }
        if fields[1] == "1" { return true }
        if fields[1] == "0" { return false }
        throw PowerHelperPlatformError.unrecognizedPMSetOutput
    }

    public func setProtectionEnabled(_ enabled: Bool) throws {
        _ = try runPMSet(["-a", "disablesleep", enabled ? "1" : "0"])
    }

    private func runPMSet(_ arguments: [String]) throws -> RootCommandResult {
        let command = RootCommand(executable: "/usr/bin/pmset", arguments: arguments)
        let result = try runner.run(command)
        guard result.exitCode == 0 else {
            throw PowerHelperPlatformError.commandFailed(
                executable: command.executable,
                exitCode: result.exitCode,
                message: String(result.standardError.prefix(512))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}

/// Conservative low-battery guard using the system pmset utility bundled with
/// macOS. A parsing failure is thrown so callers fail closed.
public struct PMSetBatterySafetyReader: PowerBatterySafetyReading {
    public static let defaultThresholdPercent = 10

    private let thresholdPercent: Int
    private let runner: any RootCommandRunning

    public init(
        thresholdPercent: Int = PMSetBatterySafetyReader.defaultThresholdPercent,
        runner: any RootCommandRunning = RootProcessCommandRunner()
    ) {
        self.thresholdPercent = min(100, max(0, thresholdPercent))
        self.runner = runner
    }

    public func isLowBattery() throws -> Bool {
        let command = RootCommand(
            executable: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let result = try runner.run(command)
        guard result.exitCode == 0 else {
            throw PowerHelperPlatformError.commandFailed(
                executable: command.executable,
                exitCode: result.exitCode,
                message: String(result.standardError.prefix(512))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let output = result.standardOutput
        if output.contains("'AC Power'") { return false }
        guard output.contains("'Battery Power'") else {
            throw PowerHelperPlatformError.unrecognizedPMSetOutput
        }

        let percentages = output.split(whereSeparator: \.isWhitespace)
            .compactMap { field -> Int? in
                guard field.hasSuffix("%;") || field.hasSuffix("%") else {
                    return nil
                }
                return Int(field.drop(while: { !$0.isNumber }).prefix(while: \.isNumber))
            }
        guard let lowest = percentages.min() else {
            throw PowerHelperPlatformError.unrecognizedPMSetOutput
        }
        return lowest <= thresholdPercent
    }
}

/// Atomic JSON store for `/var/db/dev.tsarev.detach/power-state.json`.
public final class SecureFilePowerHelperStateStore:
    PowerHelperStateStoring, @unchecked Sendable
{
    public static let defaultFileURL = URL(
        fileURLWithPath: "/var/db/dev.tsarev.detach/power-state.json")
    public static let maximumBytes = 1_048_576

    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = SecureFilePowerHelperStateStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> PowerHelperPersistentState? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        try rejectSymbolicLink(fileURL)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PowerHelperPlatformError.insecureStatePath
        }
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumBytes {
            throw PowerHelperPlatformError.stateTooLarge
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PowerHelperPersistentState.self, from: data)
    }

    public func save(_ state: PowerHelperPersistentState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        if fileManager.fileExists(atPath: fileURL.path) {
            try rejectSymbolicLink(fileURL)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumBytes else {
            throw PowerHelperPlatformError.stateTooLarge
        }
        try atomicWrite(data, to: fileURL)
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try rejectSymbolicLink(directory)
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw PowerHelperPlatformError.insecureStatePath
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw PowerHelperPlatformError.insecureStatePath
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw PowerHelperPlatformError.fileSystem(
                operation: "open", code: errno)
        }
        var shouldUnlink = true
        defer {
            Darwin.close(descriptor)
            if shouldUnlink { Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor, baseAddress.advanced(by: offset),
                    rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw PowerHelperPlatformError.fileSystem(
                        operation: "write", code: errno)
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PowerHelperPlatformError.fileSystem(
                operation: "fsync", code: errno)
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw PowerHelperPlatformError.fileSystem(
                operation: "rename", code: errno)
        }
        shouldUnlink = false
        let directoryDescriptor = Darwin.open(
            destination.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw PowerHelperPlatformError.fileSystem(
                operation: "open directory", code: errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw PowerHelperPlatformError.fileSystem(
                operation: "fsync directory", code: errno)
        }
    }
}

/// Code requirement installed directly on the NSXPC listener. Foundation
/// validates the connection's audit token and signature as one operation,
/// avoiding PID lookup and PID-reuse races in privileged code.
public enum PowerHelperCodeSigningRequirement {
    public static let clientIdentifier = "dev.tsarev.detach.power"

    public static func client(teamIdentifier: String) -> String? {
        guard teamIdentifier.utf8.count == 10,
              teamIdentifier.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57)
              }) else { return nil }
        return "anchor apple generic and identifier \"\(clientIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
