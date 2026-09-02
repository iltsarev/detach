import CoreServices
import Darwin
import Foundation

public enum SessionEventKind: String, Codable, Equatable, Sendable {
    case ready
    case changed
    case resync
}

public struct SessionEvent: Codable, Equatable, Sendable {
    public let schema: Int
    public let event: SessionEventKind

    public init(schema: Int = 1, event: SessionEventKind) {
        self.schema = schema
        self.event = event
    }
}

public enum SessionEventParser {
    public static func parse(_ line: String) -> SessionEvent? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(SessionEvent.self, from: data),
              event.schema == 1 else {
            return nil
        }
        return event
    }
}

/// Writes a disposable change token through an owned directory descriptor.
/// The token is only an event hint. Session metadata remains the source of
/// truth, so persistence and directory fsync are intentionally unnecessary.
enum SessionEventSignal {
    static func publish(atPath path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw DetachStateCommandError.unsafeEventSignal
        }
        // The runtime builds this path from environment roots that may carry
        // a trailing slash or `//`. Standardize instead of rejecting, so a
        // cosmetic path difference cannot silently disable every hint.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/"),
              url.path != "/",
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw DetachStateCommandError.unsafeEventSignal
        }
        let parent = url.deletingLastPathComponent()
        let directory = Darwin.open(
            parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw DetachStateCommandError.unsafeEventSignal
        }
        defer { Darwin.close(directory) }

        var information = stat()
        guard Darwin.fstat(directory, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == Darwin.geteuid() else {
            throw DetachStateCommandError.unsafeEventSignal
        }

        let temporary = ".session-change.\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            directory,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DetachStateCommandError.unsafeEventSignal
        }
        defer {
            Darwin.close(descriptor)
            _ = Darwin.unlinkat(directory, temporary, 0)
        }

        let record = Data("\(Darwin.getpid()):\(DispatchTime.now().uptimeNanoseconds)\n".utf8)
        let written = record.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else { return false }
            var remaining = buffer.count
            while remaining > 0 {
                let result = Darwin.write(descriptor, base, remaining)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return false }
                remaining -= result
                base = base.advanced(by: result)
            }
            return true
        }
        guard written,
              Darwin.renameat(
                  directory, temporary,
                  directory, url.lastPathComponent) == 0 else {
            throw DetachStateCommandError.unsafeEventSignal
        }
    }
}

public struct SessionEventWatchConfiguration: Equatable, Sendable {
    public let stateRoot: String
    public let signalPath: String
    public let transcriptRoots: [String]
    /// Provider session directories whose metadata names managed transcripts.
    /// The runtime may relocate one provider root, so these are explicit.
    public let sessionsRoots: [String]

    public init(
        stateRoot: String,
        signalPath: String,
        transcriptRoots: [String],
        sessionsRoots: [String]? = nil
    ) {
        self.stateRoot = stateRoot
        self.signalPath = signalPath
        self.transcriptRoots = transcriptRoots
        self.sessionsRoots = sessionsRoots
            ?? Self.defaultSessionsRoots(stateRoot: stateRoot)
    }

    public static func defaultSessionsRoots(stateRoot: String) -> [String] {
        Provider.allCases.map { provider in
            URL(fileURLWithPath: stateRoot, isDirectory: true)
                .appendingPathComponent(provider.rawValue, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL.path
        }
    }

    public static func parse(arguments: [String]) throws -> Self {
        var stateRoot: String?
        var signalPath: String?
        var transcriptRoots: [String] = []
        var sessionsRoots: [String] = []
        var sawJSON = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json" where !sawJSON:
                sawJSON = true
                index += 1
            case "--state-root" where stateRoot == nil && index + 1 < arguments.count:
                stateRoot = arguments[index + 1]
                index += 2
            case "--signal" where signalPath == nil && index + 1 < arguments.count:
                signalPath = arguments[index + 1]
                index += 2
            case "--transcript-root" where index + 1 < arguments.count:
                transcriptRoots.append(arguments[index + 1])
                index += 2
            case "--sessions-root" where index + 1 < arguments.count:
                sessionsRoots.append(arguments[index + 1])
                index += 2
            default:
                throw DetachStateCommandError.invalidArguments
            }
        }
        guard sawJSON,
              let rawStateRoot = stateRoot,
              let rawSignalPath = signalPath,
              !transcriptRoots.isEmpty,
              rawStateRoot.hasPrefix("/"),
              rawSignalPath.hasPrefix("/"),
              transcriptRoots.allSatisfy({ $0.hasPrefix("/") }),
              sessionsRoots.allSatisfy({ $0.hasPrefix("/") }) else {
            throw DetachStateCommandError.invalidArguments
        }
        let canonicalStateRoot = canonicalPath(rawStateRoot)
        let canonicalSignalPath = canonicalPath(rawSignalPath)
        let canonicalTranscriptRoots = transcriptRoots.map(canonicalPath)
        guard canonicalSignalPath.hasPrefix(canonicalStateRoot + "/") else {
            throw DetachStateCommandError.invalidArguments
        }
        return Self(
            stateRoot: canonicalStateRoot,
            signalPath: canonicalSignalPath,
            transcriptRoots: canonicalTranscriptRoots,
            sessionsRoots: sessionsRoots.isEmpty
                ? nil : sessionsRoots.map(canonicalPath))
    }

    static func canonicalPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
            missingComponents.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(url.path, &buffer) != nil else { return path }
        var resolved = URL(fileURLWithPath: String(cString: buffer))
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}

public struct SessionFileEventBatch: Equatable, Sendable {
    public let paths: [String]
    public let flags: [UInt32]

    public init(paths: [String], flags: [UInt32]) {
        self.paths = paths
        self.flags = flags
    }
}

public enum SessionFileEventClassification: Equatable, Sendable {
    case ignored
    case lifecycle
    case transcript
    case resync
}

public enum SessionFileEventClassifier {
    private static let resyncFlags = UInt32(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged)

    public static func classify(
        _ batch: SessionFileEventBatch,
        configuration: SessionEventWatchConfiguration,
        managedTranscriptPaths: Set<String>
    ) -> SessionFileEventClassification {
        if batch.flags.contains(where: { $0 & resyncFlags != 0 }) {
            return .resync
        }
        if batch.paths.contains(configuration.signalPath) {
            return .lifecycle
        }
        for path in batch.paths where managedTranscriptPaths.contains(path) {
            return .transcript
        }
        return .ignored
    }
}

/// Reduces FSEvents callbacks to one leading and one trailing transcript hint.
/// Callers restart the quiet timer after every `.scheduleTrailing` result.
public struct SessionEventCoalescer: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case emit(SessionEventKind)
        case emitAndScheduleTrailing(SessionEventKind)
        case scheduleTrailing
    }

    private var transcriptBurstActive = false

    public init() {}

    public mutating func consume(
        _ classification: SessionFileEventClassification
    ) -> Action {
        switch classification {
        case .ignored:
            return .none
        case .lifecycle:
            return .emit(.changed)
        case .resync:
            transcriptBurstActive = false
            return .emit(.resync)
        case .transcript:
            if transcriptBurstActive { return .scheduleTrailing }
            transcriptBurstActive = true
            return .emitAndScheduleTrailing(.changed)
        }
    }

    public mutating func quietWindowElapsed() -> Action {
        guard transcriptBurstActive else { return .none }
        transcriptBurstActive = false
        return .emit(.changed)
    }
}

private func sessionFSEventsCallback(
    _: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    pathsPointer: UnsafeMutableRawPointer,
    flagsPointer: UnsafePointer<FSEventStreamEventFlags>,
    _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<SessionFileEventWatcher>
        .fromOpaque(info).takeUnretainedValue()
    let pathsArray = Unmanaged<CFArray>
        .fromOpaque(pathsPointer).takeUnretainedValue() as NSArray
    let paths = pathsArray.compactMap { $0 as? String }
    let flags = (0..<count).map { UInt32(flagsPointer[$0]) }
    watcher.receive(SessionFileEventBatch(paths: paths, flags: flags))
}

/// Ends a long-lived watcher when the process that launched it exits. Task
/// cancellation remains the normal path. This process source closes the gap
/// during application termination, when Swift concurrency teardown is not
/// guaranteed to run before AppKit exits.
final class SessionEventParentMonitor: @unchecked Sendable {
    private let source: DispatchSourceProcess

    init(
        processID: pid_t,
        queue: DispatchQueue,
        onExit: @escaping @Sendable () -> Void
    ) {
        source = DispatchSource.makeProcessSource(
            identifier: processID,
            eventMask: .exit,
            queue: queue)
        source.setEventHandler(handler: onExit)
    }

    func start() {
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Long-lived native event source used by `detach watch --json`.
public final class SessionFileEventWatcher: @unchecked Sendable {
    private let configuration: SessionEventWatchConfiguration
    private let quietWindow: TimeInterval
    private let queue: DispatchQueue
    private let output: FileHandle
    private var stream: FSEventStreamRef?
    private var parentMonitor: SessionEventParentMonitor?
    private var coalescer = SessionEventCoalescer()
    private var trailingWorkItem: DispatchWorkItem?
    private var managedTranscriptPaths: Set<String> = []
    private var activeWatchedPaths: [String] = []

    public init(
        configuration: SessionEventWatchConfiguration,
        quietWindow: TimeInterval = 0.15,
        queue: DispatchQueue = DispatchQueue(
            label: "dev.tsarev.detach.session-events"),
        output: FileHandle = .standardOutput
    ) {
        self.configuration = configuration
        self.quietWindow = quietWindow
        self.queue = queue
        self.output = output
    }

    public static func run(arguments: [String]) throws -> Never {
        let watcher = SessionFileEventWatcher(
            configuration: try .parse(arguments: arguments))
        try watcher.start(parentProcessID: Darwin.getppid())
        return withExtendedLifetime(watcher) {
            dispatchMain()
        }
    }

    /// The FSEvents context holds an unretained pointer to this watcher. Stop
    /// the stream before the pointer can dangle for a late callback.
    deinit {
        trailingWorkItem?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func start(parentProcessID: pid_t? = nil) throws {
        refreshManagedTranscriptPaths()
        let paths = availableWatchedPaths()
        guard paths.contains(configuration.stateRoot) else {
            throw DetachStateCommandError.invalidArguments
        }
        stream = try makeStream(paths: paths)
        activeWatchedPaths = paths
        if let parentProcessID, parentProcessID > 1 {
            let monitor = SessionEventParentMonitor(
                processID: parentProcessID,
                queue: queue,
                onExit: { Darwin._exit(EXIT_SUCCESS) })
            parentMonitor = monitor
            monitor.start()
        }
        // The callback also runs on this serial queue. Keep complete JSON
        // records ordered even when an event arrives during startup.
        queue.sync { emit(.ready) }
    }

    private func makeStream(paths: [String]) throws -> FSEventStreamRef {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil,
            sessionFSEventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            createFlags) else {
            throw DetachStateCommandError.invalidArguments
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw DetachStateCommandError.invalidArguments
        }
        return stream
    }

    func receive(_ batch: SessionFileEventBatch) {
        let classification = SessionFileEventClassifier.classify(
            batch,
            configuration: configuration,
            managedTranscriptPaths: managedTranscriptPaths)
        if classification == .lifecycle || classification == .resync {
            refreshManagedTranscriptPaths()
            scheduleStreamRootRefreshIfNeeded()
        }
        apply(coalescer.consume(classification))
    }

    private func refreshManagedTranscriptPaths() {
        managedTranscriptPaths = DetachStateCommand.managedTranscriptPaths(
            sessionsRoots: configuration.sessionsRoots,
            allowedRoots: configuration.transcriptRoots)
    }

    private func scheduleStreamRootRefreshIfNeeded() {
        let paths = availableWatchedPaths()
        guard paths.contains(configuration.stateRoot),
              paths != activeWatchedPaths else { return }
        queue.async { [weak self] in
            self?.replaceStreamIfPossible(paths: paths)
        }
    }

    private func replaceStreamIfPossible(paths: [String]) {
        guard paths != activeWatchedPaths,
              let replacement = try? makeStream(paths: paths) else { return }
        let previous = stream
        stream = replacement
        activeWatchedPaths = paths
        if let previous {
            FSEventStreamStop(previous)
            FSEventStreamInvalidate(previous)
            FSEventStreamRelease(previous)
        }
    }

    private func apply(_ action: SessionEventCoalescer.Action) {
        switch action {
        case .none:
            return
        case .emit(let kind):
            emit(kind)
        case .emitAndScheduleTrailing(let kind):
            emit(kind)
            scheduleTrailing()
        case .scheduleTrailing:
            scheduleTrailing()
        }
    }

    private func scheduleTrailing() {
        trailingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(self.coalescer.quietWindowElapsed())
        }
        trailingWorkItem = work
        queue.asyncAfter(deadline: .now() + quietWindow, execute: work)
    }

    private func emit(_ kind: SessionEventKind) {
        guard let data = try? JSONEncoder().encode(SessionEvent(event: kind)) else {
            return
        }
        output.write(data)
        output.write(Data([0x0A]))
    }

    private func availableWatchedPaths() -> [String] {
        let manager = FileManager.default
        let candidates = [configuration.stateRoot] + configuration.transcriptRoots
        let paths = candidates.filter { path in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        return Array(Set(paths)).sorted()
    }
}
