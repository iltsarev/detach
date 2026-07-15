import Darwin
import Foundation

@_silgen_name("flock")
private func watchdogFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct WatchdogHandoffTransaction: Codable, Equatable, Sendable {
    static let currentSchema = 1

    enum Phase: String, Codable, Sendable {
        case unregisterSubmitted
        case removed
        case registering
    }

    let schema: Int
    var phase: Phase
    var targetDigest: String?

    init(phase: Phase, targetDigest: String?) {
        schema = Self.currentSchema
        self.phase = phase
        self.targetDigest = targetDigest
    }

    var isValid: Bool {
        guard schema == Self.currentSchema else { return false }
        if phase == .registering { return targetDigest?.isEmpty == false }
        return targetDigest?.isEmpty != true
    }
}

protocol WatchdogHandoffStoring: AnyObject {
    func acquireTransactionLock() throws -> any WatchdogHandoffLocking
    func load() throws -> WatchdogHandoffTransaction?
    func save(_ transaction: WatchdogHandoffTransaction) throws
    func clear() throws
}

protocol WatchdogHandoffLocking: AnyObject {}

private final class FileWatchdogHandoffLock: WatchdogHandoffLocking {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = watchdogFileLock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

enum WatchdogHandoffStoreError: LocalizedError {
    case insecurePath
    case stateTooLarge
    case invalidState
    case transactionBusy
    case fileSystem(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .insecurePath:
            "The watchdog handoff journal has an insecure path."
        case .stateTooLarge:
            "The watchdog handoff journal is unexpectedly large."
        case .invalidState:
            "The watchdog handoff journal is invalid."
        case .transactionBusy:
            "Another Detach process is already updating the watchdog."
        case let .fileSystem(operation, code):
            "Could not \(operation) the watchdog handoff journal (errno \(code))."
        }
    }
}

/// Per-user write-ahead journal for replacing the SMAppService launch agent.
/// A phase is fsynced before every ServiceManagement side effect so a new app
/// process never mistakes `.notRegistered` for completion of a lost callback.
final class FileWatchdogHandoffStore: WatchdogHandoffStoring {
    static let maximumBytes = 16 * 1_024

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Detach", isDirectory: true)
            .appendingPathComponent("watchdog-handoff.json")
    }

    private let fileURL: URL
    private let expectedOwner: uid_t

    init(
        fileURL: URL = FileWatchdogHandoffStore.defaultFileURL,
        expectedOwner: uid_t = geteuid()
    ) {
        self.fileURL = fileURL
        self.expectedOwner = expectedOwner
    }

    func acquireTransactionLock() throws -> any WatchdogHandoffLocking {
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        let lockURL = directory.appendingPathComponent("watchdog-handoff.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw fileSystemError("open transaction lock", errno)
        }
        do {
            _ = try validateRegularFile(descriptor)
            guard watchdogFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw WatchdogHandoffStoreError.transactionBusy
                }
                throw fileSystemError("lock transaction", code)
            }
            return FileWatchdogHandoffLock(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func load() throws -> WatchdogHandoffTransaction? {
        let descriptor = Darwin.open(
            fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw fileSystemError("open", errno)
        }
        defer { Darwin.close(descriptor) }

        let metadata = try validateRegularFile(descriptor)
        guard metadata.st_size <= Self.maximumBytes else {
            throw WatchdogHandoffStoreError.stateTooLarge
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw fileSystemError("read", errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumBytes else {
                throw WatchdogHandoffStoreError.stateTooLarge
            }
        }
        let transaction = try JSONDecoder().decode(
            WatchdogHandoffTransaction.self, from: data)
        guard transaction.isValid else {
            throw WatchdogHandoffStoreError.invalidState
        }
        return transaction
    }

    func save(_ transaction: WatchdogHandoffTransaction) throws {
        guard transaction.isValid else {
            throw WatchdogHandoffStoreError.invalidState
        }
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transaction)
        guard data.count <= Self.maximumBytes else {
            throw WatchdogHandoffStoreError.stateTooLarge
        }

        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw fileSystemError("create", errno)
        }
        var shouldUnlink = true
        defer {
            Darwin.close(descriptor)
            if shouldUnlink { Darwin.unlink(temporary.path) }
        }

        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw fileSystemError("fsync", errno)
        }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw fileSystemError("replace", errno)
        }
        shouldUnlink = false
        try fsyncDirectory(directory)
    }

    func clear() throws {
        if Darwin.unlink(fileURL.path) != 0, errno != ENOENT {
            throw fileSystemError("remove", errno)
        }
        let directory = fileURL.deletingLastPathComponent()
        var metadata = stat()
        guard Darwin.lstat(directory.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw fileSystemError("inspect directory", errno)
        }
        try validateDirectory(metadata)
        try fsyncDirectory(directory)
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        var metadata = stat()
        var created = false
        if Darwin.lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw fileSystemError("inspect directory", errno)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            created = true
            guard Darwin.lstat(directory.path, &metadata) == 0 else {
                throw fileSystemError("inspect directory", errno)
            }
        }
        try validateDirectory(metadata)
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw fileSystemError("secure directory", errno)
        }
        if created {
            try fsyncDirectory(directory.deletingLastPathComponent())
        }
    }

    private func validateDirectory(_ metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == expectedOwner else {
            throw WatchdogHandoffStoreError.insecurePath
        }
    }

    private func validateRegularFile(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw fileSystemError("inspect", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == expectedOwner,
              metadata.st_mode & 0o077 == 0 else {
            throw WatchdogHandoffStoreError.insecurePath
        }
        return metadata
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw fileSystemError("write", errno)
                }
                offset += count
            }
        }
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw fileSystemError("open directory", errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw fileSystemError("fsync directory", errno)
        }
    }

    private func fileSystemError(
        _ operation: String,
        _ code: Int32
    ) -> WatchdogHandoffStoreError {
        .fileSystem(operation: operation, code: code)
    }
}

enum WatchdogLifetimeBarrierStatus: Equatable {
    case missing
    case busy
    case released
}

/// The watchdog holds this user-owned flock for its complete process lifetime.
/// It supplements SMAppService's async callback when a previous app process
/// died before receiving that callback.
struct WatchdogLifetimeBarrier {
    static var defaultFileURL: URL {
        fileURL(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Keep this resolver aligned with DetachWatchdog's state-root setup. The
    /// explicit inputs make every supported environment override testable.
    static func fileURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        func path(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }
        let stateRoot: URL
        if let explicit = path("DETACH_POWER_STATE_ROOT") {
            stateRoot = URL(fileURLWithPath: explicit, isDirectory: true)
        } else {
            let base: URL
            if let explicit = path("DETACH_STATE_ROOT") {
                base = URL(fileURLWithPath: explicit, isDirectory: true)
            } else if let xdg = path("XDG_STATE_HOME") {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
                    .appendingPathComponent("detach", isDirectory: true)
            } else {
                let home = path("HOME").map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                } ?? homeDirectory
                base = home.appendingPathComponent(
                    ".local/state/detach", isDirectory: true)
            }
            stateRoot = base.appendingPathComponent("power", isDirectory: true)
        }
        return stateRoot.appendingPathComponent("watchdog-lifetime.lock")
    }

    private let fileURL: URL
    private let expectedOwner: uid_t

    init(
        fileURL: URL = WatchdogLifetimeBarrier.defaultFileURL,
        expectedOwner: uid_t = geteuid()
    ) {
        self.fileURL = fileURL
        self.expectedOwner = expectedOwner
    }

    func status() throws -> WatchdogLifetimeBarrierStatus {
        let descriptor = Darwin.open(
            fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return .missing }
            throw WatchdogHandoffStoreError.fileSystem(
                operation: "open watchdog lifetime barrier", code: errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw WatchdogHandoffStoreError.fileSystem(
                operation: "inspect watchdog lifetime barrier", code: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == expectedOwner,
              metadata.st_mode & 0o077 == 0 else {
            throw WatchdogHandoffStoreError.insecurePath
        }
        if watchdogFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = watchdogFileLock(descriptor, LOCK_UN)
            return .released
        }
        let code = errno
        if code == EWOULDBLOCK || code == EAGAIN { return .busy }
        throw WatchdogHandoffStoreError.fileSystem(
            operation: "probe watchdog lifetime barrier", code: code)
    }
}
