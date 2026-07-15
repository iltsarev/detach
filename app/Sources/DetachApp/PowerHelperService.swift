import CryptoKit
import DetachKit
import Foundation
import ServiceManagement

private final class UncontendedPowerHelperSystemHandoffLock:
    PowerHelperHandoffLocking
{}

enum PowerHelperRegistrationStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

enum PowerHelperUnregistrationPreparation: Equatable {
    case prepared
    case activeLeases
}

@MainActor
protocol PowerHelperLifecycleRunning: AnyObject {
    func prepareForUnregistration() async throws
        -> PowerHelperUnregistrationPreparation
    func cancelUnregistration() async throws
}

@MainActor
private final class SystemPowerHelperLifecycleRunner:
    PowerHelperLifecycleRunning
{
    private let cli: any DetachCLIRunning

    init(executable: URL) {
        cli = ProcessDetachCLI(executable: executable)
    }

    func prepareForUnregistration() async throws
        -> PowerHelperUnregistrationPreparation
    {
        let result = try await cli.run(
            arguments: ["helper", "prepare-unregistration"], timeout: 35)
        if !result.timedOut && result.exitCode == 0 { return .prepared }
        if !result.timedOut
            && result.exitCode == DetachPowerExecutable.temporaryFailureExitCode
        {
            return .activeLeases
        }
        throw PowerHelperServiceError.lifecycleCommandFailed(
            Self.failureMessage(result))
    }

    func cancelUnregistration() async throws {
        let result = try await cli.run(
            arguments: ["helper", "cancel-unregistration"], timeout: 35)
        guard !result.timedOut, result.exitCode == 0 else {
            throw PowerHelperServiceError.lifecycleCommandFailed(
                Self.failureMessage(result))
        }
    }

    private static func failureMessage(_ result: CLIResult) -> String {
        if result.timedOut { return "power helper lifecycle request timed out" }
        let detail = result.stderr.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "power helper lifecycle request exited with status \(result.exitCode)"
            : detail
    }
}

@MainActor
protocol PowerHelperRegistrationBackend: AnyObject {
    var status: PowerHelperRegistrationStatus { get }
    func register() throws
    func unregister() async throws
}

@MainActor
private final class SystemPowerHelperRegistrationBackend:
    PowerHelperRegistrationBackend
{
    private let plistName: String

    init(plistName: String) {
        self.plistName = plistName
    }

    private var service: SMAppService {
        // Recreate the service while retrying: BackgroundTaskManagement can
        // retain stale state on the previous object briefly after unregister.
        SMAppService.daemon(plistName: plistName)
    }

    var status: PowerHelperRegistrationStatus {
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

enum PowerHelperServiceError: LocalizedError {
    case bundledDefinitionMissing
    case registrationDidNotComplete
    case unregistrationBarrierDidNotComplete
    case activeLeasesPreventUnregistration
    case notActiveConsoleUser
    case lifecycleCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledDefinitionMissing:
            L10n.string("The bundled power helper definition is missing or incomplete.")
        case .registrationDidNotComplete:
            L10n.string("macOS did not finish registering the power helper.")
        case .unregistrationBarrierDidNotComplete:
            L10n.string(
                "macOS has not finished removing the previous power helper.")
        case .activeLeasesPreventUnregistration:
            L10n.string(
                "Stop active Detach sessions before removing the power helper.")
        case .notActiveConsoleUser:
            L10n.string(
                "Switch to this macOS user before updating the power helper.")
        case let .lifecycleCommandFailed(message):
            message
        }
    }
}

/// Registers Detach's narrowly scoped privileged daemon. Registration can
/// truthfully settle in `requiresApproval`; the app never treats that state as
/// enabled until macOS reports it so after the user's one-time approval.
@MainActor
final class PowerHelperService {
    static let plistName = "dev.tsarev.detach.power-helper.plist"

    private enum DesiredGoal: Equatable {
        case install(String)
        case remove

        var journalGoal: PowerHelperHandoffTransaction.Goal {
            switch self {
            case .install: .install
            case .remove: .remove
            }
        }

        var targetDigest: String? {
            switch self {
            case let .install(digest): digest
            case .remove: nil
            }
        }
    }

    private let backend: any PowerHelperRegistrationBackend
    private let lifecycle: any PowerHelperLifecycleRunning
    private let defaults: UserDefaults
    private let handoffStore: any PowerHelperHandoffStoring
    private let digestProvider: () -> String?
    private let bootSessionProvider: () throws -> String
    private let lifetimeBarrierStatus: () throws
        -> PowerHelperLifetimeBarrierStatus
    private let systemHandoffLockProvider: () throws
        -> (any PowerHelperHandoffLocking)?
    private let currentProcessIsActiveConsoleUser: () -> Bool
    private let sleep: (UInt64) async throws -> Void

    private let digestKey = "powerHelperDefinitionDigest"
    private let pendingDigestKey = "powerHelperDefinitionReconcilePending"
    private let legacyUnregistrationPendingKey =
        "powerHelperUnregistrationPending"
    private let legacyUnregistrationPhaseKey =
        "powerHelperUnregistrationPhase"
    private let legacyGateReopenPendingKey =
        "powerHelperGateReopenPending"
    private let legacyGateReopenDigestKey =
        "powerHelperGateReopenDigest"
    private var operationInFlight = false

    init() {
        backend = SystemPowerHelperRegistrationBackend(plistName: Self.plistName)
        lifecycle = SystemPowerHelperLifecycleRunner(
            executable: Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/detach-power"))
        defaults = .standard
        handoffStore = FilePowerHelperHandoffStore()
        digestProvider = Self.bundleDefinitionDigest
        bootSessionProvider = {
            try SysctlBootSessionReader().currentBootSessionIdentifier()
        }
        lifetimeBarrierStatus = {
            try PowerHelperLifetimeBarrier().status()
        }
        systemHandoffLockProvider = {
            try PowerHelperSystemHandoffLock().acquire().map {
                $0 as any PowerHelperHandoffLocking
            }
        }
        currentProcessIsActiveConsoleUser = {
            PowerHelperConsoleUserAdmission()
                .currentProcessIsActiveConsoleUser()
        }
        sleep = { try await Task.sleep(nanoseconds: $0) }
    }

    init(
        backend: any PowerHelperRegistrationBackend,
        lifecycle: any PowerHelperLifecycleRunning,
        defaults: UserDefaults,
        handoffStore: any PowerHelperHandoffStoring,
        digestProvider: @escaping () -> String?,
        bootSessionProvider: @escaping () throws -> String = {
            "00000000-0000-0000-0000-000000000001"
        },
        lifetimeBarrierStatus: @escaping () throws
            -> PowerHelperLifetimeBarrierStatus = { .busy },
        systemHandoffLockProvider: @escaping () throws
            -> (any PowerHelperHandoffLocking)? = {
                UncontendedPowerHelperSystemHandoffLock()
            },
        currentProcessIsActiveConsoleUser: @escaping () -> Bool = { true },
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.backend = backend
        self.lifecycle = lifecycle
        self.defaults = defaults
        self.handoffStore = handoffStore
        self.digestProvider = digestProvider
        self.bootSessionProvider = bootSessionProvider
        self.lifetimeBarrierStatus = lifetimeBarrierStatus
        self.systemHandoffLockProvider = systemHandoffLockProvider
        self.currentProcessIsActiveConsoleUser =
            currentProcessIsActiveConsoleUser
        self.sleep = sleep
    }

    var status: PowerHelperRegistrationStatus { backend.status }

    func reconcileAfterAppUpdate() async throws {
        guard let digest = digestProvider() else {
            throw PowerHelperServiceError.bundledDefinitionMissing
        }
        try await performExclusiveOperation {
            try await drive(to: .install(digest))
        }
    }

    func enable() async throws {
        try await reconcileAfterAppUpdate()
    }

    func disable() async throws {
        try await performExclusiveOperation {
            try await drive(to: .remove)
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func performExclusiveOperation(
        _ operation: () async throws -> Void
    ) async throws {
        guard !operationInFlight else {
            throw PowerHelperServiceError.registrationDidNotComplete
        }
        try requireActiveConsoleUser()
        let systemHandoffLock = try systemHandoffLockProvider()
        if systemHandoffLock == nil {
            // Before the first helper launch no root-owned rendezvous inode
            // exists yet. That pristine shape is safe only when no helper from
            // this boot has ever held the lifetime barrier. Once either file
            // exists, refusing the operation is safer than falling back to a
            // per-user lock that cannot serialize Fast User Switching.
            guard status != .enabled,
                  try lifetimeBarrierStatus() == .missing else {
                throw PowerHelperServiceError
                    .unregistrationBarrierDidNotComplete
            }
        }
        let transactionLock = try handoffStore.acquireTransactionLock()
        operationInFlight = true
        defer {
            operationInFlight = false
            withExtendedLifetime(transactionLock) {}
            withExtendedLifetime(systemHandoffLock) {}
        }
        try await operation()
    }

    private func drive(to desired: DesiredGoal) async throws {
        var transaction = try loadOrMigrateTransaction(desired: desired)
        if transaction == nil {
            transaction = try bootstrapTransaction(for: desired)
            if transaction == nil { return }
        }

        guard var transaction else { return }
        transaction = try align(transaction, with: desired)

        // Every iteration either returns, crosses one externally observable
        // phase, or throws while leaving the last fsynced phase intact.
        for _ in 0..<12 {
            switch transaction.phase {
            case .preparing:
                switch status {
                case .enabled:
                    let preparation = try await lifecycle
                        .prepareForUnregistration()
                    guard preparation == .prepared else {
                        try handoffStore.clear()
                        clearLegacyHandoffMarkers()
                        defaults.set(true, forKey: pendingDigestKey)
                        if transaction.goal == .remove {
                            throw PowerHelperServiceError
                                .activeLeasesPreventUnregistration
                        }
                        return
                    }
                    guard try lifetimeBarrierStatus() == .busy else {
                        // A helper from this build holds the lifetime lock
                        // before its listener can answer prepare. Persisting a
                        // submitted phase without that proof would leave crash
                        // recovery unable to identify the old process.
                        throw PowerHelperServiceError
                            .unregistrationBarrierDidNotComplete
                    }
                    transaction.phase = .unregisterSubmitted
                    transaction.bootSessionIdentifier = try currentBootSession()
                    transaction.lifetimeBarrierExpected = true
                    try handoffStore.save(transaction)
                case .requiresApproval, .unavailable:
                    transaction.phase = .unregisterSubmitted
                    transaction.bootSessionIdentifier = try currentBootSession()
                    try handoffStore.save(transaction)
                case .notRegistered:
                    // A normal `preparing` phase precedes submission, but the
                    // legacy boolean was written before prepare and survived
                    // through submission. Preserve its ambiguous shape as an
                    // unregister replay until the lifetime barrier proves the
                    // old process is gone.
                    transaction.phase = transaction.lifetimeBarrierExpected
                        ? .unregisterSubmitted : .removed
                    try handoffStore.save(transaction)
                }

            case .unregisterSubmitted:
                let currentBoot = try currentBootSession()
                if currentBoot != transaction.bootSessionIdentifier {
                    switch status {
                    case .enabled:
                        transaction.phase = .preparing
                        transaction.bootSessionIdentifier = currentBoot
                        transaction.lifetimeBarrierExpected = false
                        try handoffStore.save(transaction)
                        continue
                    case .notRegistered:
                        // A process from the recorded boot cannot still be
                        // alive. Exact job absence completes the lost callback.
                        transaction.phase = .removed
                        transaction.bootSessionIdentifier = currentBoot
                        transaction.lifetimeBarrierExpected = false
                        try handoffStore.save(transaction)
                        continue
                    case .requiresApproval, .unavailable:
                        transaction.bootSessionIdentifier = currentBoot
                        transaction.lifetimeBarrierExpected = false
                        try handoffStore.save(transaction)
                    }
                }

                do {
                    // Replay even when status already says notRegistered. Only
                    // a fresh successful callback has the SDK's process-reaped
                    // guarantee; status itself is not a completion barrier.
                    try requireActiveConsoleUser()
                    try await backend.unregister()
                } catch let unregisterError {
                    guard Self.isAlreadyUnregisteredError(
                        unregisterError) else {
                        throw unregisterError
                    }
                    guard status == .notRegistered else {
                        throw unregisterError
                    }
                    do {
                        try await waitForOldHelperExit(
                            lifetimeBarrierExpected:
                                transaction.lifetimeBarrierExpected)
                    } catch {
                        throw PowerHelperServiceError
                            .unregistrationBarrierDidNotComplete
                    }
                }
                transaction.phase = .removed
                try handoffStore.save(transaction)

            case .removed:
                guard transaction.goal == .install,
                      let digest = transaction.targetDigest else {
                    defaults.removeObject(forKey: digestKey)
                    defaults.removeObject(forKey: pendingDigestKey)
                    clearLegacyHandoffMarkers()
                    // Keep `.removed`: a later reinstall must register a helper
                    // and receive a fresh XPC reply before reopening the root
                    // gate persisted by the removed generation.
                    return
                }
                defaults.set(true, forKey: pendingDigestKey)
                transaction.phase = .registering
                transaction.targetDigest = digest
                try handoffStore.save(transaction)

            case .registering:
                guard transaction.goal == .install,
                      let digest = transaction.targetDigest else {
                    transaction.phase = transitionToRemovalPhase()
                    try handoffStore.save(transaction)
                    continue
                }
                switch status {
                case .enabled:
                    // The successful XPC reply is also a readiness/identity
                    // proof for the newly registered helper. Only then may its
                    // persisted root mutation gate reopen.
                    try await cancelUnregistrationWithRetry()
                    rememberDefinition(digest)
                    try handoffStore.clear()
                    clearLegacyHandoffMarkers()
                    return
                case .requiresApproval:
                    defaults.set(true, forKey: pendingDigestKey)
                    return
                case .notRegistered, .unavailable:
                    defaults.set(true, forKey: pendingDigestKey)
                    try await registerWithRetry()
                    switch status {
                    case .enabled:
                        continue
                    case .requiresApproval:
                        return
                    case .notRegistered, .unavailable:
                        throw PowerHelperServiceError
                            .registrationDidNotComplete
                    }
                }
            }
        }
        throw PowerHelperServiceError.registrationDidNotComplete
    }

    private func bootstrapTransaction(
        for desired: DesiredGoal
    ) throws -> PowerHelperHandoffTransaction? {
        let bootSession = try currentBootSession()
        switch desired {
        case let .install(digest):
            let definitionNeedsReconcile =
                defaults.string(forKey: digestKey) != digest
                || defaults.bool(forKey: pendingDigestKey)
            switch status {
            case .enabled where !definitionNeedsReconcile:
                return nil
            case .enabled:
                defaults.set(true, forKey: pendingDigestKey)
                let transaction = makeTransaction(
                    phase: .preparing, desired: desired,
                    bootSession: bootSession)
                try handoffStore.save(transaction)
                return transaction
            case .requiresApproval:
                // No daemon is running to replace safely. Keep the update
                // pending until approval makes the old registration reachable.
                defaults.set(true, forKey: pendingDigestKey)
                return nil
            case .notRegistered, .unavailable:
                defaults.set(true, forKey: pendingDigestKey)
                let lifetimeStatus = try lifetimeBarrierStatus()
                let transaction = makeTransaction(
                    phase: lifetimeStatus == .missing
                        ? .registering : .unregisterSubmitted,
                    desired: .install(digest),
                    bootSession: bootSession,
                    lifetimeBarrierExpected: lifetimeStatus != .missing)
                try handoffStore.save(transaction)
                return transaction
            }

        case .remove:
            switch status {
            case .enabled:
                let transaction = makeTransaction(
                    phase: .preparing, desired: desired,
                    bootSession: bootSession)
                try handoffStore.save(transaction)
                return transaction
            case .requiresApproval, .unavailable:
                let transaction = makeTransaction(
                    phase: .unregisterSubmitted, desired: desired,
                    bootSession: bootSession)
                try handoffStore.save(transaction)
                return transaction
            case .notRegistered:
                defaults.removeObject(forKey: digestKey)
                defaults.removeObject(forKey: pendingDigestKey)
                return nil
            }
        }
    }

    private func align(
        _ existing: PowerHelperHandoffTransaction,
        with desired: DesiredGoal
    ) throws -> PowerHelperHandoffTransaction {
        guard existing.goal != desired.journalGoal
                || existing.targetDigest != desired.targetDigest else {
            return existing
        }
        var transaction = existing
        transaction.goal = desired.journalGoal
        transaction.targetDigest = desired.targetDigest

        if transaction.phase == .registering {
            transaction.phase = transitionToRemovalPhase()
            transaction.bootSessionIdentifier = try currentBootSession()
            transaction.lifetimeBarrierExpected = false
        }
        try handoffStore.save(transaction)
        return transaction
    }

    private func transitionToRemovalPhase()
        -> PowerHelperHandoffTransaction.Phase
    {
        switch status {
        case .enabled: .preparing
        case .requiresApproval, .unavailable: .unregisterSubmitted
        case .notRegistered: .removed
        }
    }

    private func makeTransaction(
        phase: PowerHelperHandoffTransaction.Phase,
        desired: DesiredGoal,
        bootSession: String,
        lifetimeBarrierExpected: Bool = false
    ) -> PowerHelperHandoffTransaction {
        PowerHelperHandoffTransaction(
            phase: phase,
            goal: desired.journalGoal,
            targetDigest: desired.targetDigest,
            bootSessionIdentifier: bootSession,
            lifetimeBarrierExpected: lifetimeBarrierExpected)
    }

    private func loadOrMigrateTransaction(
        desired: DesiredGoal
    ) throws -> PowerHelperHandoffTransaction? {
        if let transaction = try handoffStore.load() { return transaction }

        let gateReopenPending = defaults.bool(
            forKey: legacyGateReopenPendingKey)
        let unregistrationPending = defaults.bool(
            forKey: legacyUnregistrationPendingKey)
        let oldPhase = defaults.string(forKey: legacyUnregistrationPhaseKey)
        guard gateReopenPending || unregistrationPending || oldPhase != nil else {
            return nil
        }

        // The old boolean could mean either side of root prepare and the async
        // unregister call. Re-run prepare while enabled, but retain the
        // lifetime-barrier requirement if status has already become absent.
        // This neither interrupts active leases nor opens a gate while an old
        // callback may still kill a replacement.
        var migratedDesired = desired
        if gateReopenPending,
           let digest = defaults.string(forKey: legacyGateReopenDigestKey) {
            migratedDesired = .install(digest)
        }
        let phase: PowerHelperHandoffTransaction.Phase = gateReopenPending
            ? .registering : .preparing
        let transaction = PowerHelperHandoffTransaction(
            phase: phase,
            goal: migratedDesired.journalGoal,
            targetDigest: migratedDesired.targetDigest,
            bootSessionIdentifier: try currentBootSession(),
            lifetimeBarrierExpected: !gateReopenPending)
        try handoffStore.save(transaction)
        clearLegacyHandoffMarkers()
        return transaction
    }

    private func currentBootSession() throws -> String {
        let value = try bootSessionProvider()
        guard UUID(uuidString: value) != nil else {
            throw PowerHelperServiceError.registrationDidNotComplete
        }
        return value.lowercased()
    }

    private func waitForOldHelperExit(
        lifetimeBarrierExpected: Bool
    ) async throws {
        // Bounded at roughly thirty seconds in production. On failure the
        // fsynced `unregisterSubmitted` record and root gate remain fail-closed.
        for attempt in 0..<31 {
            switch try lifetimeBarrierStatus() {
            case .released:
                return
            case .missing where !lifetimeBarrierExpected:
                // requiresApproval means no old helper process ever answered
                // prepare or held a lifetime lease. Exact job absence plus a
                // missing lock is therefore sufficient in that recorded shape.
                return
            case .busy, .missing:
                break
            }
            if attempt < 30 { try await sleep(1_000_000_000) }
        }
        throw PowerHelperServiceError.unregistrationBarrierDidNotComplete
    }

    private func clearLegacyHandoffMarkers() {
        defaults.removeObject(forKey: legacyUnregistrationPhaseKey)
        defaults.set(false, forKey: legacyUnregistrationPendingKey)
        defaults.set(false, forKey: legacyGateReopenPendingKey)
        defaults.removeObject(forKey: legacyGateReopenDigestKey)
    }

    private func cancelUnregistrationWithRetry() async throws {
        let delays: [UInt64] = [
            0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000,
        ]
        var lastError: Error?
        for delay in delays {
            if delay > 0 { try await sleep(delay) }
            do {
                try await lifecycle.cancelUnregistration()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PowerHelperServiceError.registrationDidNotComplete
    }

    private func registerWithRetry() async throws {
        let delays: [UInt64] = [
            0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000,
        ]
        var lastError: Error?

        for delay in delays {
            if delay > 0 { try await sleep(delay) }
            do {
                try requireActiveConsoleUser()
                try backend.register()
            } catch {
                if status == .enabled || status == .requiresApproval { return }
                guard Self.isTransientRegistrationError(error) else { throw error }
                lastError = error
                continue
            }
            if status == .enabled || status == .requiresApproval { return }
            lastError = PowerHelperServiceError.registrationDidNotComplete
        }

        throw lastError ?? PowerHelperServiceError.registrationDidNotComplete
    }

    private static func isTransientRegistrationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "SMAppServiceErrorDomain" && nsError.code == 1
    }

    private static func isAlreadyUnregisteredError(_ error: Error) -> Bool {
        // SMAppService documents kSMErrorJobNotFound as the only error that
        // proves this replay found no registered job. Other errors (notably an
        // operation-in-progress response) must not be combined with status and
        // a released process lock to manufacture a completion barrier.
        let nsError = error as NSError
        return nsError.domain == "SMAppServiceErrorDomain"
            && nsError.code == Int(kSMErrorJobNotFound)
    }

    private func rememberDefinition(_ digest: String) {
        defaults.set(digest, forKey: digestKey)
        defaults.set(false, forKey: pendingDigestKey)
    }

    private func requireActiveConsoleUser() throws {
        guard currentProcessIsActiveConsoleUser() else {
            throw PowerHelperServiceError.notActiveConsoleUser
        }
    }

    private static func bundleDefinitionDigest() -> String? {
        let contents = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
        guard let plist = try? Data(contentsOf: contents
                .appendingPathComponent("Library/LaunchDaemons/\(plistName)")),
              let helper = try? Data(contentsOf: contents
                .appendingPathComponent("MacOS/DetachPowerHelper")) else {
            return nil
        }
        var data = Data()
        data.append(plist)
        data.append(helper)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
