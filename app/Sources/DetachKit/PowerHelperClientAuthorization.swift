import Darwin

/// Pure admission policy for the privileged power helper. Code-signing and
/// UID checks are intentionally separate, and both must pass before the XPC
/// connection receives an exported object.
public enum PowerHelperClientAuthorizationDecision:
    String, Equatable, Sendable
{
    case allowed
    case noActiveConsoleUser
    case privilegedClient
    case differentUser
}

public struct PowerHelperClientAuthorizationPolicy: Sendable {
    public init() {}

    public func decision(
        clientEffectiveUserIdentifier: UInt32,
        consoleUserIdentifier: UInt32?
    ) -> PowerHelperClientAuthorizationDecision {
        // At loginwindow/logout, /dev/console is owned by root. Treat both that
        // state and a failed stat as having no active interactive user.
        guard let consoleUserIdentifier,
              consoleUserIdentifier != 0 else {
            return .noActiveConsoleUser
        }
        // A root process does not become an authorized client merely because
        // it can execute a correctly signed binary.
        guard clientEffectiveUserIdentifier != 0 else {
            return .privilegedClient
        }
        guard clientEffectiveUserIdentifier == consoleUserIdentifier else {
            return .differentUser
        }
        return .allowed
    }
}

/// App-side admission for machine-wide ServiceManagement mutations. Only the
/// active non-root console user's app may register or unregister the daemon;
/// background users can still inspect status, but cannot race the active user
/// during Fast User Switching. Root repeats the same UID policy for XPC.
public struct PowerHelperConsoleUserAdmission: Sendable {
    public init() {}

    public func currentProcessIsActiveConsoleUser() -> Bool {
        let processUserIdentifier = geteuid()
        guard processUserIdentifier != 0 else { return false }
        var metadata = stat()
        guard Darwin.lstat("/dev/console", &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFCHR else {
            return false
        }
        return metadata.st_uid == processUserIdentifier
    }
}
