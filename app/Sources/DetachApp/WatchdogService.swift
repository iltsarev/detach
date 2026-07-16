import CryptoKit
import Darwin
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
    case unregistrationBarrierDidNotComplete

    var errorDescription: String? {
        switch self {
        case .bundledDefinitionMissing:
            L10n.string("The bundled watchdog definition is missing or incomplete.")
        case .registrationDidNotComplete:
            L10n.string("macOS did not finish registering the watchdog.")
        case .unregistrationBarrierDidNotComplete:
            L10n.string("macOS did not finish stopping the previous watchdog.")
        }
    }
}

@MainActor
final class WatchdogService {
    static let plistName = "dev.tsarev.detach.power-watchdog.plist"

    private let backend: any WatchdogRegistrationBackend
    private let defaults: UserDefaults
    private let handoffStore: any WatchdogHandoffStoring
    private let digestProvider: () -> String?
    private let lifetimeBarrierStatus: () throws -> WatchdogLifetimeBarrierStatus
    private let legacyWatchdogIsRunning: () throws -> Bool
    private let sleep: (UInt64) async throws -> Void
    private var operationInFlight = false

    // This service identity first ships with the self-contained runtime.
    // Keep its durable state separate from pre-release watchdog registrations:
    // replaying an old label's unregister phase against this label fails with
    // "Operation not permitted" before the new agent can be registered.
    private let digestKey = "powerWatchdogDefinitionDigest"
    private let pendingDigestKey = "powerWatchdogDefinitionReconcilePending"

    init() {
        backend = SystemWatchdogRegistrationBackend(plistName: Self.plistName)
        defaults = .standard
        handoffStore = FileWatchdogHandoffStore()
        digestProvider = Self.bundleDefinitionDigest
        lifetimeBarrierStatus = { try WatchdogLifetimeBarrier().status() }
        legacyWatchdogIsRunning = Self.bundledWatchdogProcessIsRunning
        sleep = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        backend: any WatchdogRegistrationBackend,
        defaults: UserDefaults,
        handoffStore: any WatchdogHandoffStoring,
        digestProvider: @escaping () -> String?,
        lifetimeBarrierStatus: @escaping () throws
            -> WatchdogLifetimeBarrierStatus = { .released },
        legacyWatchdogIsRunning: @escaping () throws -> Bool = { false },
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.backend = backend
        self.defaults = defaults
        self.handoffStore = handoffStore
        self.digestProvider = digestProvider
        self.lifetimeBarrierStatus = lifetimeBarrierStatus
        self.legacyWatchdogIsRunning = legacyWatchdogIsRunning
        self.sleep = sleep
    }

    var status: WatchdogStatus { backend.status }

    func reconcileAfterAppUpdate(forceReplacement: Bool = false) async throws {
        guard let digest = digestProvider() else {
            throw WatchdogServiceError.bundledDefinitionMissing
        }
        try await performExclusiveOperation {
            try await drive(to: digest, forceReplacement: forceReplacement)
        }
    }

    func enable() async throws {
        try await reconcileAfterAppUpdate()
    }

    func disable() async throws {
        try await performExclusiveOperation {
            try await drive(to: nil, forceReplacement: false)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func performExclusiveOperation(
        _ operation: () async throws -> Void
    ) async throws {
        guard !operationInFlight else {
            throw WatchdogServiceError.registrationDidNotComplete
        }
        let transactionLock = try handoffStore.acquireTransactionLock()
        operationInFlight = true
        defer {
            operationInFlight = false
            withExtendedLifetime(transactionLock) {}
        }
        try await operation()
    }

    /// Drives both update replacement and removal from an fsynced phase. A
    /// nil target means removal; a digest means the bundled agent must be
    /// registered only after any submitted unregister has crossed a process-
    /// lifetime barrier.
    private func drive(
        to targetDigest: String?,
        forceReplacement: Bool
    ) async throws {
        var transaction: WatchdogHandoffTransaction?
        if let targetDigest {
            transaction = try transactionForInstall(
                targetDigest,
                forceReplacement: forceReplacement)
        } else {
            transaction = try transactionForRemoval()
        }
        guard var transaction else { return }

        for _ in 0..<8 {
            switch transaction.phase {
            case .unregisterSubmitted:
                do {
                    // Only a fresh success callback is documented to arrive
                    // after the old process has been killed. Status changes
                    // before this callback are deliberately ignored.
                    try await backend.unregister()
                } catch {
                    guard Self.isAlreadyUnregisteredError(error) else {
                        throw error
                    }
                    // An error callback may be immediate. For replay after a
                    // lost callback, require the new watchdog's lifetime lock
                    // to be released, or conservatively observe that a legacy
                    // pre-lock watchdog process is absent for several polls.
                    try await waitForReplayedUnregistrationBarrier()
                }
                transaction.phase = .removed
                try handoffStore.save(transaction)

            case .removed:
                guard transaction.targetDigest != nil else {
                    defaults.removeObject(forKey: digestKey)
                    defaults.removeObject(forKey: pendingDigestKey)
                    try handoffStore.clear()
                    return
                }
                transaction.phase = .registering
                try handoffStore.save(transaction)

            case .registering:
                guard let digest = transaction.targetDigest else {
                    throw WatchdogHandoffStoreError.invalidState
                }
                if status != .enabled && status != .requiresApproval {
                    try await registerWithRetry()
                }
                guard status == .enabled || status == .requiresApproval else {
                    defaults.set(true, forKey: pendingDigestKey)
                    throw WatchdogServiceError.registrationDidNotComplete
                }
                // requiresApproval is a completed registration. The remaining
                // action belongs to the user in Login Items settings.
                rememberDefinition(digest)
                try handoffStore.clear()
                return
            }
        }
        throw WatchdogServiceError.registrationDidNotComplete
    }

    private func transactionForInstall(
        _ digest: String,
        forceReplacement: Bool
    ) throws -> WatchdogHandoffTransaction? {
        if var transaction = try handoffStore.load() {
            if transaction.targetDigest != digest {
                switch transaction.phase {
                case .unregisterSubmitted, .removed:
                    transaction.targetDigest = digest
                case .registering:
                    transaction.targetDigest = digest
                    // The previous synchronous register may have succeeded
                    // immediately before a crash even while a fresh status
                    // probe still reports notRegistered. A different target
                    // must therefore remove that possibly installed definition
                    // before registering its replacement.
                    transaction.phase = .unregisterSubmitted
                }
                try handoffStore.save(transaction)
            }
            defaults.set(true, forKey: pendingDigestKey)
            return transaction
        }

        let previous = defaults.string(forKey: digestKey)
        let pending = defaults.bool(forKey: pendingDigestKey)
        let definitionChanged = previous != digest
        if !forceReplacement, !definitionChanged, !pending,
           status == .enabled || status == .requiresApproval {
            return nil
        }

        // A legacy pending marker can represent the interval after async
        // unregister submission. Replaying from `unregisterSubmitted` is the
        // only safe migration even when status already says notRegistered.
        let priorRegistrationMayNeedRemoval = forceReplacement
            || pending
            || (previous != nil && definitionChanged)
            || (definitionChanged
                && (status == .enabled || status == .requiresApproval))
        let transaction = WatchdogHandoffTransaction(
            phase: priorRegistrationMayNeedRemoval
                ? .unregisterSubmitted : .registering,
            targetDigest: digest)
        try handoffStore.save(transaction)
        defaults.set(true, forKey: pendingDigestKey)
        return transaction
    }

    private func transactionForRemoval()
        throws -> WatchdogHandoffTransaction? {
        if var transaction = try handoffStore.load() {
            transaction.targetDigest = nil
            if transaction.phase == .registering {
                // register() is synchronous, but a crash can happen after it
                // succeeds and before status/defaults are observed. Removal
                // must therefore issue a fresh unregister even if a relaunched
                // status probe still reports notRegistered.
                transaction.phase = .unregisterSubmitted
            }
            try handoffStore.save(transaction)
            return transaction
        }

        guard status != .notRegistered && status != .unavailable else {
            defaults.removeObject(forKey: digestKey)
            defaults.removeObject(forKey: pendingDigestKey)
            return nil
        }
        let transaction = WatchdogHandoffTransaction(
            phase: .unregisterSubmitted,
            targetDigest: nil)
        try handoffStore.save(transaction)
        return transaction
    }

    private func waitForReplayedUnregistrationBarrier() async throws {
        var consecutiveLegacyAbsences = 0
        for attempt in 0..<31 {
            switch try lifetimeBarrierStatus() {
            case .released:
                // A stale marker can survive a downgrade to a pre-lock
                // watchdog. Also verify that no bundled watchdog executable
                // is still present before treating the released flock as the
                // reap barrier.
                if try legacyWatchdogIsRunning() {
                    consecutiveLegacyAbsences = 0
                } else {
                    return
                }
            case .busy:
                consecutiveLegacyAbsences = 0
            case .missing:
                if try legacyWatchdogIsRunning() {
                    consecutiveLegacyAbsences = 0
                } else {
                    consecutiveLegacyAbsences += 1
                    if consecutiveLegacyAbsences >= 3 { return }
                }
            }
            if attempt < 30 { try await sleep(1_000_000_000) }
        }
        throw WatchdogServiceError.unregistrationBarrierDidNotComplete
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

    private static func isAlreadyUnregisteredError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "SMAppServiceErrorDomain"
            && nsError.code == Int(kSMErrorJobNotFound)
    }

    private func rememberDefinition(_ digest: String) {
        defaults.set(digest, forKey: digestKey)
        defaults.set(false, forKey: pendingDigestKey)
    }

    private static func bundledWatchdogProcessIsRunning() throws -> Bool {
        let expectedPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/DetachWatchdog")
            .resolvingSymlinksInPath().standardizedFileURL.path
        var processIdentifiers = [pid_t](repeating: 0, count: 8_192)
        let byteCount = processIdentifiers.count * MemoryLayout<pid_t>.size
        let count = proc_listallpids(&processIdentifiers, Int32(byteCount))
        guard count >= 0, count < processIdentifiers.count else {
            throw WatchdogHandoffStoreError.fileSystem(
                operation: "enumerate legacy watchdog processes",
                code: count < 0 ? errno : EOVERFLOW)
        }

        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        for pid in processIdentifiers.prefix(Int(count)) where pid > 0 {
            pathBuffer.withUnsafeMutableBufferPointer {
                $0.initialize(repeating: 0)
            }
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
                continue
            }
            let path = URL(fileURLWithPath: String(cString: pathBuffer))
                .resolvingSymlinksInPath().standardizedFileURL.path
            if path == expectedPath { return true }
        }
        return false
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
}
