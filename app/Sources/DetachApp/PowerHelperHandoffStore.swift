import Darwin
import DetachKit
import Foundation

@_silgen_name("flock")
private func handoffFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct PowerHelperHandoffTransaction: Codable, Equatable, Sendable {
    static let currentSchema = 1

    enum Phase: String, Codable, Sendable {
        case preparing
        case unregisterSubmitted
        case removed
        case registering
    }

    enum Goal: String, Codable, Sendable {
        case install
        case remove
    }

    let schema: Int
    var phase: Phase
    var goal: Goal
    var targetDigest: String?
    var bootSessionIdentifier: String
    var lifetimeBarrierExpected: Bool

    init(
        phase: Phase,
        goal: Goal,
        targetDigest: String?,
        bootSessionIdentifier: String,
        lifetimeBarrierExpected: Bool = false
    ) {
        schema = Self.currentSchema
        self.phase = phase
        self.goal = goal
        self.targetDigest = targetDigest
        self.bootSessionIdentifier = bootSessionIdentifier
        self.lifetimeBarrierExpected = lifetimeBarrierExpected
    }

    var isValid: Bool {
        guard schema == Self.currentSchema,
              let bootUUID = UUID(uuidString: bootSessionIdentifier),
              bootUUID.uuidString.lowercased() == bootSessionIdentifier else {
            return false
        }
        switch goal {
        case .install:
            return targetDigest?.isEmpty == false
        case .remove:
            return targetDigest == nil
        }
    }
}

protocol PowerHelperHandoffStoring: AnyObject {
    func acquireTransactionLock() throws -> any PowerHelperHandoffLocking
    func load() throws -> PowerHelperHandoffTransaction?
    func save(_ transaction: PowerHelperHandoffTransaction) throws
    func clear() throws
}

protocol PowerHelperHandoffLocking: AnyObject {}

extension PowerHelperSystemHandoffLease: PowerHelperHandoffLocking {}

private final class FilePowerHelperHandoffLock: PowerHelperHandoffLocking {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = handoffFileLock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

enum PowerHelperHandoffStoreError: LocalizedError {
    case insecurePath
    case stateTooLarge
    case invalidState
    case transactionBusy
    case fileSystem(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .insecurePath:
            "The power helper handoff journal has an insecure path."
        case .stateTooLarge:
            "The power helper handoff journal is unexpectedly large."
        case .invalidState:
            "The power helper handoff journal is invalid."
        case .transactionBusy:
            "Another Detach process is already updating the power helper."
        case let .fileSystem(operation, code):
            "Could not \(operation) the power helper handoff journal (errno \(code))."
        }
    }
}

/// A write-ahead journal for the privileged-helper replacement transaction.
/// Every phase transition is fsynced before the corresponding SMAppService or
/// root-gate side effect, so an app crash can resume without guessing whether
/// an asynchronous unregister request was already submitted.
final class FilePowerHelperHandoffStore: PowerHelperHandoffStoring {
    static let maximumBytes = 64 * 1_024

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Detach", isDirectory: true)
            .appendingPathComponent("power-helper-handoff.json")
    }

    private let fileURL: URL
    private let expectedOwner: uid_t

    init(
        fileURL: URL = FilePowerHelperHandoffStore.defaultFileURL,
        expectedOwner: uid_t = geteuid()
    ) {
        self.fileURL = fileURL
        self.expectedOwner = expectedOwner
    }

    func acquireTransactionLock() throws -> any PowerHelperHandoffLocking {
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)
        let lockURL = directory.appendingPathComponent(
            "power-helper-handoff.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw fileSystemError("open transaction lock", errno)
        }
        do {
            _ = try validateRegularFile(descriptor)
            guard handoffFileLock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw PowerHelperHandoffStoreError.transactionBusy
                }
                throw fileSystemError("lock transaction", code)
            }
            return FilePowerHelperHandoffLock(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func load() throws -> PowerHelperHandoffTransaction? {
        let descriptor = Darwin.open(
            fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw fileSystemError("open", errno)
        }
        defer { Darwin.close(descriptor) }

        let metadata = try validateRegularFile(descriptor)
        guard metadata.st_size <= Self.maximumBytes else {
            throw PowerHelperHandoffStoreError.stateTooLarge
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
                throw PowerHelperHandoffStoreError.stateTooLarge
            }
        }
        let transaction = try JSONDecoder().decode(
            PowerHelperHandoffTransaction.self, from: data)
        guard transaction.isValid else {
            throw PowerHelperHandoffStoreError.invalidState
        }
        return transaction
    }

    func save(_ transaction: PowerHelperHandoffTransaction) throws {
        guard transaction.isValid else {
            throw PowerHelperHandoffStoreError.invalidState
        }
        let directory = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transaction)
        guard data.count <= Self.maximumBytes else {
            throw PowerHelperHandoffStoreError.stateTooLarge
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
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                created = true
            } catch {
                throw error
            }
            guard Darwin.lstat(directory.path, &metadata) == 0 else {
                throw fileSystemError("inspect directory", errno)
            }
        }
        try validateDirectory(metadata)
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw fileSystemError("secure directory", errno)
        }
        if created {
            // Persist the journal directory entry itself before any phase file
            // inside it is used as a write-ahead crash barrier.
            try fsyncDirectory(directory.deletingLastPathComponent())
        }
    }

    private func validateDirectory(_ metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == expectedOwner else {
            throw PowerHelperHandoffStoreError.insecurePath
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
            throw PowerHelperHandoffStoreError.insecurePath
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
    ) -> PowerHelperHandoffStoreError {
        .fileSystem(operation: operation, code: code)
    }
}
