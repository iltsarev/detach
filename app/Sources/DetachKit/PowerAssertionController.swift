import Foundation
import IOKit.pwr_mgt

/// The replaceable boundary around the public IOKit power assertion API.
///
/// Production code uses ``IOKitPowerAssertionBackend``. Tests and higher-level
/// policy code can inject another implementation without changing machine
/// power state.
public protocol PowerAssertionBackend: Sendable {
    func createNoIdleSleepAssertion(reason: String) throws -> UInt32
    func releaseAssertion(_ assertionID: UInt32) throws
}

/// The minimal lifecycle surface needed by lease and power policy code.
public protocol IdleSleepAssertionControlling: AnyObject, Sendable {
    var isActive: Bool { get }

    /// Activates idle-sleep prevention.
    ///
    /// - Returns: `true` when a new assertion was created, or `false` when one
    ///   was already active.
    @discardableResult
    func acquire() throws -> Bool

    /// Deactivates idle-sleep prevention.
    ///
    /// - Returns: `true` when an assertion was released, or `false` when none
    ///   was active.
    @discardableResult
    func release() throws -> Bool
}

public struct IOKitPowerAssertionError: Error, Equatable, Sendable {
    public enum Operation: String, Equatable, Sendable {
        case create
        case release
    }

    public let operation: Operation
    public let code: Int32

    public init(operation: Operation, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

extension IOKitPowerAssertionError: LocalizedError {
    public var errorDescription: String? {
        "IOKit power assertion \(operation.rawValue) failed with code \(code)"
    }
}

/// The production adapter for a user-idle system-sleep assertion.
///
/// `kIOPMAssertPreventUserIdleSystemSleep` is the supported successor to the
/// deprecated `kIOPMAssertionTypeNoIdleSleep` spelling. Creating the backend
/// itself has no side effects; the assertion is created only by
/// ``createNoIdleSleepAssertion(reason:)``.
public struct IOKitPowerAssertionBackend: PowerAssertionBackend {
    public init() {}

    public func createNoIdleSleepAssertion(reason: String) throws -> UInt32 {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
        guard result == kIOReturnSuccess else {
            throw IOKitPowerAssertionError(operation: .create, code: result)
        }
        return assertionID
    }

    public func releaseAssertion(_ assertionID: UInt32) throws {
        let result = IOPMAssertionRelease(IOPMAssertionID(assertionID))
        guard result == kIOReturnSuccess else {
            throw IOKitPowerAssertionError(operation: .release, code: result)
        }
    }
}

/// Owns at most one idle-sleep assertion and pairs every successful acquire
/// with a release.
///
/// Calls are serialized so repeated or concurrent lifecycle requests remain
/// idempotent. A failed release intentionally keeps the assertion ID, allowing
/// a later call to retry instead of falsely reporting that protection ended.
public final class PowerAssertionController: IdleSleepAssertionControlling, @unchecked Sendable {
    public static let defaultReason = "Detach managed session"

    private let backend: any PowerAssertionBackend
    private let reason: String
    private let lock = NSLock()
    private var assertionID: UInt32?

    public init(
        reason: String = PowerAssertionController.defaultReason,
        backend: any PowerAssertionBackend = IOKitPowerAssertionBackend()
    ) {
        self.reason = reason
        self.backend = backend
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    @discardableResult
    public func acquire() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard assertionID == nil else { return false }
        assertionID = try backend.createNoIdleSleepAssertion(reason: reason)
        return true
    }

    @discardableResult
    public func release() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let assertionID else { return false }
        try backend.releaseAssertion(assertionID)
        self.assertionID = nil
        return true
    }

    deinit {
        guard let assertionID else { return }
        try? backend.releaseAssertion(assertionID)
    }
}
