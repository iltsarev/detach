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
    static func publish(inStateRoot path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw DetachStateCommandError.unsafeEventSignal
        }
        // The runtime root may carry a trailing slash or `//`. Standardize it,
        // then derive the fixed token name here. Callers cannot choose a final
        // component that could replace unrelated user data.
        let parent = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        guard parent.path.hasPrefix("/"), parent.path != "/" else {
            throw DetachStateCommandError.unsafeEventSignal
        }
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
                  directory, "session-change") == 0 else {
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

/// Supplements the root FSEvents stream with exact live transcript vnode
/// sources. Some long-running provider processes do not produce recursive
/// FSEvents for an already-open rollout file, while vnode writes remain
/// observable. The root stream still discovers new and replaced files.
final class SessionTranscriptFileMonitor: @unchecked Sendable {
    static let maximumSources = 64

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let onChange: @Sendable () -> Void
    private var targetPaths: Set<String> = []
    private var sources: [String: any DispatchSourceFileSystemObject] = [:]

    init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: 1)
    }

    func update(paths: Set<String>) {
        synchronized {
            targetPaths = Set(paths.sorted().prefix(Self.maximumSources))
            for path in Array(sources.keys) where !targetPaths.contains(path) {
                removeSource(for: path)
            }
            for path in targetPaths where sources[path] == nil {
                armSource(for: path)
            }
        }
        drainRegistrationHandlers()
    }

    func stop() {
        synchronized {
            targetPaths = []
            for path in Array(sources.keys) { removeSource(for: path) }
        }
        drainRegistrationHandlers()
    }

    deinit {
        stop()
    }

    private func synchronized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func drainRegistrationHandlers() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    private func armSource(for path: String, refreshAfterRegistration: Bool = false) {
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            return
        }
        let descriptor = Darwin.open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == Darwin.geteuid() else {
            Darwin.close(descriptor)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.sources[path] === source else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename, .revoke])
            self.onChange()
            guard replaced else { return }
            self.removeSource(for: path)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                guard let self,
                      self.targetPaths.contains(path),
                      self.sources[path] == nil else { return }
                self.armSource(for: path, refreshAfterRegistration: true)
            }
        }
        if refreshAfterRegistration {
            source.setRegistrationHandler { [weak self, weak source] in
                guard let self, let source, self.sources[path] === source else { return }
                // Writes to the replacement inode before registration have no
                // vnode event. Refresh once the new source closes that gap.
                self.onChange()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        sources[path] = source
        source.resume()
    }

    private func removeSource(for path: String) {
        sources.removeValue(forKey: path)?.cancel()
    }
}

func sessionFSEventsCallback(
    _: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    pathsPointer: UnsafeMutableRawPointer,
    flagsPointer: UnsafePointer<FSEventStreamEventFlags>,
    _: UnsafePointer<FSEventStreamEventId>
) {
    guard let delivery = sessionFSEventsDelivery(
        info: info,
        count: count,
        pathsPointer: pathsPointer,
        flagsPointer: flagsPointer)
    else { return }
    delivery.watcher.receive(delivery.batch)
}

func sessionFSEventsDelivery(
    info: UnsafeMutableRawPointer?,
    count: Int,
    pathsPointer: UnsafeMutableRawPointer,
    flagsPointer: UnsafePointer<FSEventStreamEventFlags>
) -> (watcher: SessionFileEventWatcher, batch: SessionFileEventBatch)? {
    guard let info else { return nil }
    let watcher = Unmanaged<SessionFileEventWatcher>
        .fromOpaque(info).takeUnretainedValue()
    let pathsArray = Unmanaged<CFArray>
        .fromOpaque(pathsPointer).takeUnretainedValue() as NSArray
    let paths = pathsArray.compactMap { $0 as? String }
    let flags = (0..<count).map { UInt32(flagsPointer[$0]) }
    return (watcher, SessionFileEventBatch(paths: paths, flags: flags))
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
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let output: FileHandle
    private var stream: FSEventStreamRef?
    private var parentMonitor: SessionEventParentMonitor?
    private var coalescer = SessionEventCoalescer()
    private var trailingWorkItem: DispatchWorkItem?
    private var managedTranscriptPaths: Set<String> = []
    private var activeWatchedPaths: [String] = []
    private lazy var transcriptMonitor = SessionTranscriptFileMonitor(
        queue: queue,
        onChange: { [weak self] in self?.receiveTranscriptChange() })

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
        queue.setSpecific(key: queueKey, value: 1)
    }

    public static func run(arguments: [String]) throws -> Never {
        // A consumer that is already gone must not leave an orphan, and a
        // closed pipe must end this process quietly rather than as a crash.
        let parent = Darwin.getppid()
        guard parent > 1 else { Darwin._exit(EXIT_SUCCESS) }
        Darwin.signal(SIGPIPE, SIG_IGN)
        let watcher = SessionFileEventWatcher(
            configuration: try .parse(arguments: arguments))
        try watcher.start(parentProcessID: parent)
        return withExtendedLifetime(watcher) {
            dispatchMain()
        }
    }

    /// The FSEvents context holds an unretained pointer to this watcher. Stop
    /// the stream before the pointer can dangle for a late callback.
    deinit {
        stop()
    }

    /// Stops native sources and drains callbacks before their output can close.
    func stop() {
        let operation = {
            self.trailingWorkItem?.cancel()
            self.trailingWorkItem = nil
            self.transcriptMonitor.stop()
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            self.parentMonitor = nil
            self.activeWatchedPaths = []
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
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

    func receiveTranscriptChange() {
        apply(coalescer.consume(.transcript))
    }

    private func refreshManagedTranscriptPaths() {
        let registry = DetachStateCommand.managedTranscriptRegistry(
            sessionsRoots: configuration.sessionsRoots,
            allowedRoots: configuration.transcriptRoots)
        managedTranscriptPaths = registry.all
        transcriptMonitor.update(paths: registry.live)
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
        guard var data = try? JSONEncoder().encode(SessionEvent(event: kind)) else {
            return
        }
        data.append(0x0A)
        let descriptor = output.fileDescriptor
        let delivered = data.withUnsafeBytes { buffer -> Bool in
            guard var base = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, base, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                remaining -= written
                base = base.advanced(by: written)
            }
            return true
        }
        // EPIPE means the consumer closed its end. The stream has no other
        // purpose, so end without an uncaught-exception crash report.
        if !delivered, errno == EPIPE { Darwin._exit(EXIT_SUCCESS) }
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
