import CryptoKit
import DetachKit
import Foundation
import ServiceManagement

enum WatchdogStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol WatchdogRegistrationBackend: AnyObject {
    var status: WatchdogStatus { get }
    func register() throws
    func unregister() async throws
}

@MainActor
private final class SystemWatchdogRegistrationBackend: WatchdogRegistrationBackend {
    private let plistName: String

    init(plistName: String) {
        self.plistName = plistName
    }

    private var service: SMAppService {
        // A fresh instance matters when retrying after unregister: macOS may
        // leave the previous SMAppService object on stale BTM state briefly.
        SMAppService.agent(plistName: plistName)
    }

    var status: WatchdogStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        let service = service
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

enum WatchdogServiceError: LocalizedError {
    case bundledDefinitionMissing
    case registrationDidNotComplete

    var errorDescription: String? {
        switch self {
        case .bundledDefinitionMissing:
            L10n.string("The bundled watchdog definition is missing or incomplete.")
        case .registrationDidNotComplete:
            L10n.string("macOS did not finish registering the watchdog.")
        }
    }
}

@MainActor
final class WatchdogService {
    static let plistName = "dev.tsarev.detach.watchdog.plist"
    static let portablePlistName = "dev.tsarev.detach.cli-watchdog.plist"
    static let portableLabel = "dev.tsarev.detach.cli-watchdog"
    static let legacyPlistName = "dev.tsarev.codex-detached-watchdog.plist"
    static let legacyLabel = "dev.tsarev.codex-detached-watchdog"

    private let backend: any WatchdogRegistrationBackend
    private let legacyBackend: (any WatchdogRegistrationBackend)?
    private let defaults: UserDefaults
    private let homeDirectory: URL
    private let digestProvider: () -> String?
    private let sleep: (UInt64) async throws -> Void
    private let launchctl: ([String]) -> Int32

    private let digestKey = "watchdogDefinitionDigest"
    private let pendingDigestKey = "watchdogDefinitionReconcilePending"

    init() {
        backend = SystemWatchdogRegistrationBackend(plistName: Self.plistName)
        legacyBackend = SystemWatchdogRegistrationBackend(plistName: Self.legacyPlistName)
        defaults = .standard
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        digestProvider = Self.bundleDefinitionDigest
        sleep = { try await Task.sleep(nanoseconds: $0) }
        launchctl = Self.runLaunchctl
    }

    init(
        backend: any WatchdogRegistrationBackend,
        legacyBackend: (any WatchdogRegistrationBackend)? = nil,
        defaults: UserDefaults,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        digestProvider: @escaping () -> String?,
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        launchctl: @escaping ([String]) -> Int32 = { _ in 0 }
    ) {
        self.backend = backend
        self.legacyBackend = legacyBackend
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        self.digestProvider = digestProvider
        self.sleep = sleep
        self.launchctl = launchctl
    }

    var status: WatchdogStatus { backend.status }

    func reconcileAfterAppUpdate() async throws {
        guard let digest = digestProvider() else {
            throw WatchdogServiceError.bundledDefinitionMissing
        }

        let previous = defaults.string(forKey: digestKey)
        let pending = defaults.bool(forKey: pendingDigestKey)
        let definitionChanged = previous != digest

        if definitionChanged && (status == .enabled || status == .requiresApproval) {
            defaults.set(true, forKey: pendingDigestKey)
            do {
                try await backend.unregister()
            } catch {
                // Some macOS releases report a launchd removal error after the
                // item has already disappeared. The observable status is the
                // reliable postcondition in that case.
                guard status == .notRegistered || status == .unavailable else {
                    throw error
                }
            }
            await Task.yield()
        }

        if definitionChanged || pending || status == .notRegistered || status == .unavailable {
            defaults.set(true, forKey: pendingDigestKey)
            try await registerWithRetry()
        }

        switch status {
        case .enabled:
            rememberDefinition(digest)
            await retireLegacyWatchdogs()
        case .requiresApproval:
            // Registration is complete. The remaining action belongs to the
            // user in macOS Login Items and must not trigger re-registration.
            // Keep the portable agent alive until the signed replacement is
            // actually enabled, so migration never loses reconciliation.
            rememberDefinition(digest)
        case .notRegistered, .unavailable:
            defaults.set(true, forKey: pendingDigestKey)
            throw WatchdogServiceError.registrationDidNotComplete
        }
    }

    func enable() async throws {
        try await reconcileAfterAppUpdate()
    }

    func disable() async throws {
        var unregisterError: Error?
        if status != .notRegistered && status != .unavailable {
            do {
                try await backend.unregister()
            } catch {
                unregisterError = error
            }
        }
        await retireLegacyWatchdogs()
        defaults.removeObject(forKey: digestKey)
        defaults.removeObject(forKey: pendingDigestKey)
        if let unregisterError { throw unregisterError }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerWithRetry() async throws {
        // Apple DTS documents a race where register immediately after a
        // completed unregister returns SMAppServiceErrorDomain Code=1. A
        // bounded backoff also recovers pending/.notFound states left by an
        // interrupted app update without spinning forever.
        let delays: [UInt64] = [0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]
        var lastError: Error?

        for delay in delays {
            if delay > 0 { try await sleep(delay) }
            do {
                try backend.register()
            } catch {
                if status == .enabled || status == .requiresApproval { return }
                guard Self.isTransientRegistrationError(error) else { throw error }
                lastError = error
                continue
            }
            if status == .enabled || status == .requiresApproval { return }
            lastError = WatchdogServiceError.registrationDidNotComplete
        }

        throw lastError ?? WatchdogServiceError.registrationDidNotComplete
    }

    private static func isTransientRegistrationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // The public constant is annotated macOS 15 even though the domain is
        // used by SMAppService on macOS 13–14 as well.
        return nsError.domain == "SMAppServiceErrorDomain" && nsError.code == 1
    }

    private func rememberDefinition(_ digest: String) {
        defaults.set(digest, forKey: digestKey)
        defaults.set(false, forKey: pendingDigestKey)
    }

    private static func bundleDefinitionDigest() -> String? {
        let contents = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
        guard let plist = try? Data(contentsOf: contents
                .appendingPathComponent("Library/LaunchAgents/\(plistName)")),
              let helper = try? Data(contentsOf: contents
                .appendingPathComponent("MacOS/DetachWatchdog")) else { return nil }
        var data = Data()
        data.append(plist)
        data.append(helper)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func retireLegacyWatchdogs() async {
        let legacyWasRegistered: Bool
        if let legacyBackend {
            legacyWasRegistered = legacyBackend.status != .notRegistered &&
                legacyBackend.status != .unavailable
        } else {
            legacyWasRegistered = false
        }
        if let legacyBackend, legacyWasRegistered {
            // The migration-only bundled definition lets an update address an
            // already registered 0.1.0 SMAppService. The signed replacement
            // is enabled before this best-effort unregister can run.
            try? await legacyBackend.unregister()
        }
        retireUserWatchdog(
            plistName: Self.legacyPlistName,
            label: Self.legacyLabel,
            addressEvenIfMissing: legacyWasRegistered)
        retireUserWatchdog(
            plistName: Self.portablePlistName,
            label: Self.portableLabel)
    }

    private func retireUserWatchdog(
        plistName: String,
        label: String,
        addressEvenIfMissing: Bool = false
    ) {
        let definition = homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName)
        let backup = definition.appendingPathExtension("detach-backup")
        let ownsDefinition = Self.isOwnedUserDefinition(definition, label: label)
        let ownsBackup = Self.isOwnedUserDefinition(backup, label: label)
        guard addressEvenIfMissing || ownsDefinition || ownsBackup else { return }

        if launchctl(["bootout", "gui/\(getuid())/\(label)"]) != 0,
           ownsDefinition {
            _ = launchctl(["bootout", "gui/\(getuid())", definition.path])
        }
        if ownsDefinition { try? FileManager.default.removeItem(at: definition) }
        if ownsBackup { try? FileManager.default.removeItem(at: backup) }
    }

    private static func isOwnedUserDefinition(_ url: URL, label: String) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil),
        let dictionary = plist as? [String: Any],
        dictionary["Label"] as? String == label,
        let arguments = dictionary["ProgramArguments"] as? [String],
        (arguments.count >= 3 &&
            arguments[0] == "/bin/sh" &&
            arguments[1] == "-c" &&
            arguments[2].contains("__reconcile_amphetamine")) ||
        (arguments.count == 2 &&
            arguments[0].hasSuffix("/.local/bin/detach") &&
            arguments[1] == "__reconcile_amphetamine") else { return false }
        return true
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }
}
