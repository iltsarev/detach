import Foundation
import IOKit
import IOKit.pwr_mgt

/// Observes the physical clamshell state while a protected child is running.
///
/// The initial state establishes a baseline. Consumers act only on a later
/// open-to-closed transition, so starting a Detach session while intentionally
/// using an already-closed MacBook with an external display is not disruptive.
public protocol ClamshellStateWatching: Sendable {
    func run(
        onStateChange: @escaping @Sendable (Bool) -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult
}

/// Requests the normal macOS display-sleep/Lock Screen path.
public protocol ScreenLockRequesting: Sendable {
    func requestLock() throws
}

/// Runs a protected child while locking the screen once for each physical
/// open-to-closed lid transition.
public final class ClamshellLockRunner: @unchecked Sendable {
    private let watcher: any ClamshellStateWatching
    private let requester: any ScreenLockRequesting
    private let reportFailure: @Sendable (String) -> Void

    public init(
        watcher: any ClamshellStateWatching = IOKitClamshellStateWatcher(),
        requester: any ScreenLockRequesting = PMSetScreenLockRequester(),
        reportFailure: @escaping @Sendable (String) -> Void = {
            FileHandle.standardError.write(
                Data("detach-power: \($0)\n".utf8))
        }
    ) {
        self.watcher = watcher
        self.requester = requester
        self.reportFailure = reportFailure
    }

    public func run(
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult {
        let policy = ClamshellLockTransitionPolicy()
        return try watcher.run(
            onStateChange: { [requester, reportFailure] isClosed in
                guard policy.observe(isClosed: isClosed) else { return }
                do {
                    try requester.requestLock()
                } catch {
                    reportFailure(
                        "could not lock the screen after the lid closed: "
                            + error.localizedDescription)
                }
            },
            operation: operation)
    }
}

private final class ClamshellLockTransitionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var previousState: Bool?

    func observe(isClosed: Bool) -> Bool {
        lock.lock()
        defer {
            previousState = isClosed
            lock.unlock()
        }
        guard let previousState else { return false }
        return !previousState && isClosed
    }
}

/// Uses the documented IOPMrootDomain clamshell notification and property.
public struct IOKitClamshellStateWatcher: ClamshellStateWatching {
    private let queue: DispatchQueue

    public init(
        queue: DispatchQueue = DispatchQueue(
            label: "dev.tsarev.detach.clamshell-lock")
    ) {
        self.queue = queue
    }

    public func run(
        onStateChange: @escaping @Sendable (Bool) -> Void,
        operation: @escaping @Sendable () throws -> ChildCommandResult
    ) throws -> ChildCommandResult {
        guard let matching = IOServiceMatching("IOPMrootDomain") else {
            throw IOKitClamshellWatcherError.rootDomainUnavailable
        }
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault, matching)
        guard rootDomain != IO_OBJECT_NULL else {
            throw IOKitClamshellWatcherError.rootDomainUnavailable
        }
        defer { IOObjectRelease(rootDomain) }

        // A missing property means this Mac has no clamshell, so there is
        // nothing to monitor and desktop Macs keep their existing behavior.
        guard let initialState = Self.clamshellState(of: rootDomain) else {
            return try operation()
        }
        guard let notificationPort = IONotificationPortCreate(
            kIOMainPortDefault)
        else {
            throw IOKitClamshellWatcherError.notificationPortUnavailable
        }

        let context = IOKitClamshellCallbackContext(
            onStateChange: onStateChange)
        var notification = io_object_t(IO_OBJECT_NULL)
        let registration = IOServiceAddInterestNotification(
            notificationPort,
            rootDomain,
            kIOGeneralInterest,
            clamshellInterestCallback,
            Unmanaged.passUnretained(context).toOpaque(),
            &notification)
        guard registration == KERN_SUCCESS else {
            IONotificationPortDestroy(notificationPort)
            throw IOKitClamshellWatcherError.registrationFailed(
                code: registration)
        }

        // Establish the baseline before attaching the dispatch queue. Any
        // message already waiting on the notification port is then delivered
        // after the baseline rather than racing ahead of it.
        onStateChange(initialState)
        IONotificationPortSetDispatchQueue(notificationPort, queue)
        defer {
            IOObjectRelease(notification)
            IONotificationPortDestroy(notificationPort)
            queue.sync {}
            withExtendedLifetime(context) {}
        }

        return try operation()
    }

    fileprivate static func clamshellState(
        of service: io_service_t
    ) -> Bool? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            kAppleClamshellStateKey as CFString,
            kCFAllocatorDefault,
            0)
        else {
            return nil
        }
        return (property.takeRetainedValue() as? NSNumber)?.boolValue
    }
}

public enum IOKitClamshellWatcherError: LocalizedError, Equatable {
    case rootDomainUnavailable
    case notificationPortUnavailable
    case registrationFailed(code: kern_return_t)

    public var errorDescription: String? {
        switch self {
        case .rootDomainUnavailable:
            "the macOS power root domain is unavailable"
        case .notificationPortUnavailable:
            "the macOS clamshell notification port is unavailable"
        case let .registrationFailed(code):
            "macOS rejected clamshell notifications with code \(code)"
        }
    }
}

private final class IOKitClamshellCallbackContext {
    let onStateChange: @Sendable (Bool) -> Void

    init(onStateChange: @escaping @Sendable (Bool) -> Void) {
        self.onStateChange = onStateChange
    }
}

// `kIOPMMessageClamshellStateChange` is defined by IOPM.h through the
// function-like `iokit_family_msg` macro, which Swift cannot import:
// err_system(0x38) | err_sub(13) | 0x100.
private let clamshellStateChangeMessage = UInt32(0xe0034100)

private let clamshellInterestCallback: IOServiceInterestCallback = {
    reference,
    service,
    messageType,
    _
    in
    guard messageType == clamshellStateChangeMessage,
          let reference,
          let state = IOKitClamshellStateWatcher.clamshellState(
              of: service) else {
        return
    }
    Unmanaged<IOKitClamshellCallbackContext>
        .fromOpaque(reference)
        .takeUnretainedValue()
        .onStateChange(state)
}

public enum PMSetScreenLockError: LocalizedError, Equatable {
    case failed(exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case let .failed(exitCode):
            "pmset displaysleepnow exited with status \(exitCode)"
        }
    }
}

/// `pmset displaysleepnow` is a documented, unprivileged macOS operation. It
/// turns the displays off immediately; macOS then applies the user's normal
/// Lock Screen policy, including Touch ID and Apple Watch unlock.
public struct PMSetScreenLockRequester: ScreenLockRequesting {
    public init() {}

    public func requestLock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PMSetScreenLockError.failed(
                exitCode: process.terminationStatus)
        }
    }
}
