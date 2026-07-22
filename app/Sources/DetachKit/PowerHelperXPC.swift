import Foundation

public enum PowerHelperXPCContract {
    public static let machServiceName = "dev.tsarev.detach.power-helper"
}

/// Stable Objective-C surface shared with the future privileged helper.
/// Payloads are Foundation/XPC-safe types only; status remains versioned JSON
/// so a newer helper can add fields without breaking an older client.
@objc public protocol DetachPowerHelperXPCProtocol {
    @objc(statusWithReply:)
    func status(reply: @escaping (NSData?, NSError?) -> Void)

    @objc(acquireLeaseWithSessionName:runToken:assertionActive:requestDeadline:reply:)
    func acquireLease(
        sessionName: String,
        runToken: String,
        assertionActive: Bool,
        requestDeadline: TimeInterval,
        reply: @escaping (Bool, NSError?) -> Void)

    @objc(renewLeaseWithSessionName:runToken:assertionActive:reply:)
    func renewLease(
        sessionName: String,
        runToken: String,
        assertionActive: Bool,
        reply: @escaping (Bool, NSError?) -> Void)

    @objc(releaseLeaseWithSessionName:runToken:reply:)
    func releaseLease(
        sessionName: String,
        runToken: String,
        reply: @escaping (NSError?) -> Void)

    @objc(prepareForUnregistrationWithReply:)
    func prepareForUnregistration(reply: @escaping (NSError?) -> Void)

    @objc(cancelUnregistrationWithReply:)
    func cancelUnregistration(reply: @escaping (NSError?) -> Void)
}

public protocol PowerHelperXPCTransport: Sendable {
    func statusData() throws -> Data
    func acquireLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool
    func renewLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool
    func releaseLease(_ identity: PowerLeaseIdentity) throws
    func prepareForUnregistration() throws
    func cancelUnregistration() throws
}

public protocol PowerHelperLifecycleClient: Sendable {
    func prepareForUnregistration() throws
    func cancelUnregistration() throws
}

public enum PowerHelperLifecycleError: Error, Equatable, Sendable {
    case activeLeases
    case serviceQuiescing
}

extension PowerHelperLifecycleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .activeLeases:
            return "active power leases prevent helper unregistration"
        case .serviceQuiescing:
            return "power helper is preparing to unregister"
        }
    }
}

public enum PowerHelperXPCError: Error, Equatable, Sendable {
    case unavailable(String)
    case timedOut
    case invalidReply
}

extension PowerHelperXPCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return "power helper is unavailable: \(message)"
        case .timedOut:
            return "power helper request timed out"
        case .invalidReply:
            return "power helper returned an invalid reply"
        }
    }
}

final class PowerHelperXPCReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func resolve(_ newResult: Result<Value, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw PowerHelperXPCError.timedOut
        }
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            throw PowerHelperXPCError.invalidReply
        }
        return try result.get()
    }
}

/// Real privileged Mach-service transport. The service does not exist yet;
/// connection failures are intentionally surfaced to ``PowerHelperXPCClient``
/// so read-only status can report `unavailable` and mutation requests fail
/// closed.
public final class NSXPCPowerHelperTransport: PowerHelperXPCTransport, @unchecked Sendable {
    // One reconciliation can perform up to five serialized, individually
    // bounded pmset calls. Never let the client abandon a successful acquire
    // while the root service can still be completing that mutation.
    public static let defaultTimeout: TimeInterval = 30
    /// Read-only status is used by `detach doctor` before the helper has been
    /// registered. A missing Mach service may consume the full XPC deadline
    /// instead of failing immediately, so keep this comfortably below the
    /// doctor's own timeout and report the helper as unavailable.
    public static let defaultStatusTimeout: TimeInterval = 2
    /// Root receives a much earlier absolute deadline for an initial acquire.
    /// This leaves ample time to undo a just-completed power mutation before
    /// the synchronous client is allowed to time out.
    public static let defaultInitialAcquireBudget: TimeInterval = 8

    private let machServiceName: String
    private let timeout: TimeInterval
    private let initialAcquireBudget: TimeInterval

    public convenience init(
        machServiceName: String = PowerHelperXPCContract.machServiceName,
        timeout: TimeInterval = NSXPCPowerHelperTransport.defaultTimeout
    ) {
        self.init(
            machServiceName: machServiceName,
            timeout: timeout,
            initialAcquireBudget: Self.defaultInitialAcquireBudget)
    }

    public init(
        machServiceName: String,
        timeout: TimeInterval,
        initialAcquireBudget: TimeInterval
    ) {
        self.machServiceName = machServiceName
        self.timeout = max(0.1, timeout)
        self.initialAcquireBudget = min(
            max(0.01, initialAcquireBudget),
            max(0.01, self.timeout / 3))
    }

    public func statusData() throws -> Data {
        try perform(
            timeout: min(timeout, Self.defaultStatusTimeout)
        ) { proxy, completion in
            proxy.status { data, error in
                if let error {
                    completion(.failure(error))
                } else if let data {
                    completion(.success(data as Data))
                } else {
                    completion(.failure(PowerHelperXPCError.invalidReply))
                }
            }
        }
    }

    public func acquireLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool {
        try perform { proxy, completion in
            proxy.acquireLease(
                sessionName: identity.sessionName,
                runToken: identity.runToken,
                assertionActive: assertionActive,
                requestDeadline: Date().addingTimeInterval(
                    initialAcquireBudget).timeIntervalSince1970
            ) { confirmed, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(confirmed))
                }
            }
        }
    }

    public func renewLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool {
        try perform { proxy, completion in
            proxy.renewLease(
                sessionName: identity.sessionName,
                runToken: identity.runToken,
                assertionActive: assertionActive
            ) { confirmed, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(confirmed))
                }
            }
        }
    }

    public func releaseLease(_ identity: PowerLeaseIdentity) throws {
        let _: Bool = try perform { proxy, completion in
            proxy.releaseLease(
                sessionName: identity.sessionName,
                runToken: identity.runToken
            ) { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(true))
                }
            }
        }
    }

    public func prepareForUnregistration() throws {
        let _: Bool = try perform { proxy, completion in
            proxy.prepareForUnregistration { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(true))
                }
            }
        }
    }

    public func cancelUnregistration() throws {
        let _: Bool = try perform { proxy, completion in
            proxy.cancelUnregistration { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(true))
                }
            }
        }
    }

    private func perform<Value>(
        timeout requestTimeout: TimeInterval? = nil,
        _ request: (
            DetachPowerHelperXPCProtocol,
            @escaping (Result<Value, Error>) -> Void
        ) -> Void
    ) throws -> Value {
        let reply = PowerHelperXPCReply<Value>()
        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(
            with: DetachPowerHelperXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let object = connection.remoteObjectProxyWithErrorHandler { error in
            reply.resolve(.failure(PowerHelperXPCError.unavailable(
                error.localizedDescription)))
        }
        guard let proxy = object as? DetachPowerHelperXPCProtocol else {
            throw PowerHelperXPCError.unavailable("remote proxy has an unexpected type")
        }
        request(proxy) { reply.resolve($0) }
        return try reply.wait(timeout: requestTimeout ?? timeout)
    }
}

/// Typed helper client used by `detach-power`.
///
/// Status is intentionally reportable even when XPC is unavailable. Mutation
/// operations retain normal throwing/confirmation semantics so `run` cannot
/// launch a provider without verified helper protection.
public struct PowerHelperXPCClient: PowerHelperClient, PowerHelperLifecycleClient {
    private let transport: any PowerHelperXPCTransport

    public init(transport: any PowerHelperXPCTransport = NSXPCPowerHelperTransport()) {
        self.transport = transport
    }

    public func status() throws -> PowerProtectionStatus {
        do {
            return try JSONDecoder().decode(
                PowerProtectionStatus.self,
                from: transport.statusData())
        } catch {
            return PowerProtectionStatus(
                state: .unavailable,
                leaseCount: 0,
                assertionActive: false,
                closedLidProtectionActive: false,
                helperReachable: false,
                transitionInProgress: false,
                lowBattery: false)
        }
    }

    public func acquireLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool {
        try transport.acquireLease(identity, assertionActive: assertionActive)
    }

    public func renewLease(
        _ identity: PowerLeaseIdentity,
        assertionActive: Bool
    ) throws -> Bool {
        try transport.renewLease(identity, assertionActive: assertionActive)
    }

    public func releaseLease(_ identity: PowerLeaseIdentity) throws {
        try transport.releaseLease(identity)
    }

    public func prepareForUnregistration() throws {
        do {
            try transport.prepareForUnregistration()
        } catch {
            throw Self.lifecycleError(for: error)
        }
    }

    public func cancelUnregistration() throws {
        do {
            try transport.cancelUnregistration()
        } catch {
            throw Self.lifecycleError(for: error)
        }
    }

    private static func lifecycleError(for error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == PowerHelperXPCService.errorDomain else {
            return error
        }
        switch nsError.code {
        case PowerHelperXPCService.ErrorCode.activeLeases.rawValue:
            return PowerHelperLifecycleError.activeLeases
        case PowerHelperXPCService.ErrorCode.serviceQuiescing.rawValue:
            return PowerHelperLifecycleError.serviceQuiescing
        default:
            return error
        }
    }
}
