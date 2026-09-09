import Darwin
import Foundation

/// Structured provider activity reduced by the runtime for power policy.
/// Unknown input always maps to `working` so a damaged handoff fails awake.
public enum PowerRunActivityState: String, Equatable, Sendable {
    case working
    case waiting

    public var requiresProtection: Bool { self == .working }
}

public protocol PowerRunActivityReading: Sendable {
    func state(atPath path: String) -> PowerRunActivityState
}

/// Reads one private, run-token-scoped activity handoff without following a
/// symlink. Only the exact `waiting` record permits sleep.
public struct FilePowerRunActivityReader: PowerRunActivityReading {
    private static let recordByteCount = 8

    public init() {}

    public func state(atPath path: String) -> PowerRunActivityState {
        guard let descriptor = Self.openValidated(
            path: path,
            flags: O_RDONLY | O_CLOEXEC)
        else {
            return .working
        }
        defer { Darwin.close(descriptor) }

        var bytes = [UInt8](repeating: 0, count: Self.recordByteCount + 1)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            while true {
                let result = Darwin.pread(
                    descriptor,
                    buffer.baseAddress,
                    buffer.count,
                    0)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard count == Self.recordByteCount else { return .working }
        let record = String(decoding: bytes.prefix(count), as: UTF8.self)
        return record == "waiting\n" ? .waiting : .working
    }

    static func openValidated(path: String, flags: Int32) -> Int32? {
        let descriptor = Darwin.open(path, flags | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == Darwin.geteuid() else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }
}

/// Observes activity-file writes without polling. The provider operation keeps
/// running if the watcher is unavailable, but the callback receives `working`
/// so protection stays active.
public protocol PowerRunActivityWatching: Sendable {
    func run(
        activityFile: String?,
        activitySourceFile: String?,
        onStateChange: @escaping @Sendable (PowerRunActivityState) -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult
}

private struct PowerRunActivitySource {
    let descriptor: Int32
}

/// Opens the transcript recorded by the runtime only when its inode, mtime,
/// and size still match the snapshot that produced `waiting`.
private struct FilePowerRunActivitySourceReader {
    private static let maximumRecordByteCount = 16 * 1024

    func openSource(atPath handoffPath: String) -> PowerRunActivitySource? {
        guard let handoff = FilePowerRunActivityReader.openValidated(
            path: handoffPath,
            flags: O_RDONLY | O_CLOEXEC)
        else {
            return nil
        }
        defer { Darwin.close(handoff) }

        var handoffInformation = stat()
        guard Darwin.fstat(handoff, &handoffInformation) == 0,
              handoffInformation.st_size > 0,
              handoffInformation.st_size <= Self.maximumRecordByteCount else {
            return nil
        }
        let expectedCount = Int(handoffInformation.st_size)
        var bytes = [UInt8](repeating: 0, count: expectedCount)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            while true {
                let result = Darwin.pread(
                    handoff,
                    buffer.baseAddress,
                    buffer.count,
                    0)
                if result < 0, errno == EINTR { continue }
                return result
            }
        }
        guard count == expectedCount,
              let separator = bytes.firstIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }
        let signature = String(decoding: bytes[..<separator], as: UTF8.self)
        let path = String(decoding: bytes[bytes.index(after: separator)...], as: UTF8.self)
        guard path.hasPrefix("/"), !path.isEmpty, !path.utf8.contains(0),
              let descriptor = FilePowerRunActivityReader.openValidated(
                path: path,
                flags: O_EVTONLY | O_CLOEXEC) else {
            return nil
        }

        var sourceInformation = stat()
        guard Darwin.fstat(descriptor, &sourceInformation) == 0,
              signature == Self.signature(for: sourceInformation) else {
            Darwin.close(descriptor)
            return nil
        }
        return PowerRunActivitySource(descriptor: descriptor)
    }

    private static func signature(for information: stat) -> String {
        "\(information.st_ino):\(information.st_mtimespec.tv_sec):\(information.st_size)"
    }
}

final class PowerRunActivitySourceWatchBox: @unchecked Sendable {
    var source: (any DispatchSourceFileSystemObject)?
    var waiting = false

    /// A transcript event applies only to the watch generation that delivered
    /// it. An event from a cancelled generation can still run after its
    /// replacement is installed; it must not consume the current watch.
    func consumeEvent(
        from eventSource: any DispatchSourceFileSystemObject
    ) -> Bool {
        guard waiting, source === eventSource else { return false }
        waiting = false
        source = nil
        return true
    }
}

public final class FilePowerRunActivityWatcher:
    PowerRunActivityWatching, @unchecked Sendable
{
    private let reader: any PowerRunActivityReading
    private let sourceReader = FilePowerRunActivitySourceReader()
    private let queue: DispatchQueue

    public init(
        reader: any PowerRunActivityReading = FilePowerRunActivityReader(),
        queue: DispatchQueue = DispatchQueue(
            label: "dev.tsarev.detach.power-activity")
    ) {
        self.reader = reader
        self.queue = queue
    }

    public func run(
        activityFile: String?,
        activitySourceFile: String?,
        onStateChange: @escaping @Sendable (PowerRunActivityState) -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult {
        guard let activityFile, let activitySourceFile else {
            return try operation()
        }
        guard let descriptor = FilePowerRunActivityReader.openValidated(
                path: activityFile,
                flags: O_EVTONLY | O_CLOEXEC) else {
            onStateChange(.working)
            return try operation()
        }

        let activityEvents = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue)
        let sourceWatch = PowerRunActivitySourceWatchBox()
        let eventQueue = queue
        let applyActivity = { [reader, sourceReader] in
            sourceWatch.source?.cancel()
            sourceWatch.source = nil
            sourceWatch.waiting = false

            guard reader.state(atPath: activityFile) == .waiting,
                  let source = sourceReader.openSource(
                    atPath: activitySourceFile) else {
                onStateChange(.working)
                return
            }
            let sourceEvents = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: source.descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: eventQueue)
            sourceEvents.setEventHandler {
                guard sourceWatch.consumeEvent(from: sourceEvents) else { return }
                onStateChange(.working)
                sourceEvents.cancel()
            }
            sourceEvents.setCancelHandler {
                Darwin.close(source.descriptor)
            }
            sourceWatch.source = sourceEvents
            sourceWatch.waiting = true
            sourceEvents.resume()
            onStateChange(.waiting)
        }
        activityEvents.setEventHandler {
            applyActivity()
        }
        activityEvents.setCancelHandler {
            Darwin.close(descriptor)
        }
        applyActivity()
        activityEvents.resume()

        let result = Result { try operation() }
        activityEvents.cancel()
        eventQueue.sync {
            sourceWatch.waiting = false
            sourceWatch.source?.cancel()
            sourceWatch.source = nil
        }
        queue.sync {}
        return try result.get()
    }
}
