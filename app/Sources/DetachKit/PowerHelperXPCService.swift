import Foundation

/// Root-side XPC bridge. It exposes no general command execution surface: the
/// client can only manage renewable leases and request a typed status.
public final class PowerHelperXPCService:
    NSObject, DetachPowerHelperXPCProtocol, @unchecked Sendable
{
    public static let errorDomain = "dev.tsarev.detach.power-helper"

    public enum ErrorCode: Int, Sendable {
        case generic = 1
        case activeLeases = 2
        case serviceQuiescing = 3
        case requestExpired = 4
    }

    private let service: PowerHelperLeaseService

    public init(service: PowerHelperLeaseService) {
        self.service = service
        super.init()
    }

    public func status(reply: @escaping (NSData?, NSError?) -> Void) {
        do {
            let status = try service.status()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            reply(try encoder.encode(status) as NSData, nil)
        } catch {
            reply(nil, Self.nsError(error))
        }
    }

    public func acquireLease(
        sessionName: String,
        runToken: String,
        assertionActive: Bool,
        requestDeadline: TimeInterval,
        reply: @escaping (Bool, NSError?) -> Void
    ) {
        do {
            guard requestDeadline.isFinite else {
                throw PowerHelperLeaseServiceError.requestExpired
            }
            let status = try service.acquireLease(
                PowerLeaseIdentity(
                    sessionName: sessionName, runToken: runToken),
                assertionActive: assertionActive,
                requestDeadline: Date(
                    timeIntervalSince1970: requestDeadline))
            reply(status.state == .protected, nil)
        } catch {
            reply(false, Self.nsError(error))
        }
    }

    public func renewLease(
        sessionName: String,
        runToken: String,
        assertionActive: Bool,
        reply: @escaping (Bool, NSError?) -> Void
    ) {
        do {
            let status = try service.renewLease(
                PowerLeaseIdentity(
                    sessionName: sessionName, runToken: runToken),
                assertionActive: assertionActive)
            reply(status.state == .protected, nil)
        } catch {
            reply(false, Self.nsError(error))
        }
    }

    public func releaseLease(
        sessionName: String,
        runToken: String,
        reply: @escaping (NSError?) -> Void
    ) {
        do {
            _ = try service.releaseLease(PowerLeaseIdentity(
                sessionName: sessionName, runToken: runToken))
            reply(nil)
        } catch {
            reply(Self.nsError(error))
        }
    }

    public func prepareForUnregistration(
        reply: @escaping (NSError?) -> Void
    ) {
        do {
            try service.prepareForUnregistration()
            reply(nil)
        } catch {
            reply(Self.nsError(error))
        }
    }

    public func cancelUnregistration(
        reply: @escaping (NSError?) -> Void
    ) {
        do {
            _ = try service.cancelUnregistration()
            reply(nil)
        } catch {
            reply(Self.nsError(error))
        }
    }

    private static func nsError(_ error: Error) -> NSError {
        let code: ErrorCode
        switch error as? PowerHelperLeaseServiceError {
        case .activeLeasesPreventUnregistration:
            code = .activeLeases
        case .serviceQuiescing:
            code = .serviceQuiescing
        case .requestExpired:
            code = .requestExpired
        default:
            code = .generic
        }
        return NSError(
            domain: errorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
    }
}
