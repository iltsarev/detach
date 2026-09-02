import Foundation
import Observation
import DetachKit

enum InstallationContextOperation: Equatable, Sendable {
    case refresh
    case repair
}

@MainActor
protocol InstallationWatchdogServicing: AnyObject {
    var status: WatchdogStatus { get }
    func reconcileAfterAppUpdate(forceReplacement: Bool) async throws
    func enable() async throws
    func disable() async throws
    func openLoginItemsSettings()
}

extension WatchdogService: InstallationWatchdogServicing {}

@MainActor
protocol InstallationPowerHelperServicing: AnyObject {
    var status: PowerHelperRegistrationStatus { get }
    func reconcileAfterAppUpdate() async throws
        -> PowerHelperReconciliationOutcome
    func enable() async throws
    func disable() async throws
    func openApprovalSettings()
}

extension PowerHelperService: InstallationPowerHelperServicing {}

@MainActor
protocol InstallationDistributionServicing {
    func synchronize(repair: Bool) async throws -> String
    func doctor() async throws -> DoctorReport
}

extension DistributionClient: InstallationDistributionServicing {}

@Observable @MainActor
final class InstallationStore {
    private struct BundledMetadata {
        let version: String
        let build: String
        let payloadID: String
    }

    enum Phase: Equatable {
        case idle
        case syncing
        case updateDeferred
        case actionRequired
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: DoctorReport?
    private(set) var watchdogStatus: WatchdogStatus = .unavailable
    private(set) var watchdogError: String?
    /// Timestamp-only watchdog writes update the backing snapshot without
    /// invalidating SwiftUI. A semantic power or freshness change uses the
    /// observation registrar and redraws all dependent surfaces at once.
    @ObservationIgnored private var watchdogHeartbeatStorage:
        PowerHeartbeatSnapshot
    var watchdogHeartbeat: PowerHeartbeatSnapshot {
        access(keyPath: \.watchdogHeartbeat)
        return watchdogHeartbeatStorage
    }
    private(set) var powerHelperStatus: PowerHelperRegistrationStatus = .unavailable
    private(set) var powerHelperError: String?
    private(set) var lastInstallMessage: String?
    private(set) var distributionMatchesBundle = false
    private(set) var powerProtectionState: PowerProtectionState = .unknown
    /// True only after a coordinated reconciliation finished with the helper
    /// reported `.enabled` and no error — the readiness barrier. A bare
    /// `SMAppService.status` read is never sufficient: after approval the
    /// helper journal may still be mid-`registering` with the root gate
    /// closed, and a session started then would fail to acquire protection.
    private(set) var powerHelperReadinessConfirmed = false
    private(set) var onboardingEverCompleted: Bool
    private var uiE2EOnboardingStep: OnboardingStep?

    private static let onboardingCompletedKey = "onboardingCompleted"
    private let detachPath: String
    private let watchdog: any InstallationWatchdogServicing
    private let powerHelper: any InstallationPowerHelperServicing
    private let payloadDirectory: URL?
    private let bundleURL: URL
    private let bundledMetadata: BundledMetadata?
    private let powerStateRoot: URL
    private let heartbeatReader: PowerHeartbeatReader
    private let defaults: UserDefaults
    private let contextOperationOverride:
        (@MainActor (InstallationContextOperation) async -> Void)?
    private let applicationLocationValidator: @MainActor (URL) -> Bool
    private let distributionClientFactory:
        @MainActor (URL, URL, URL, URL) -> any InstallationDistributionServicing
    private let cliFactory: @MainActor (URL) -> any DetachCLIRunning
    private var contextOperationRunning = false
    @ObservationIgnored private var currentContextOperation:
        InstallationContextOperation?
    @ObservationIgnored private var pendingContextRefresh = false
    @ObservationIgnored private var pendingContextRepair = false
    @ObservationIgnored private var contextOperationWaiters:
        [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var heartbeatMonitor: PowerHeartbeatMonitor?
    @ObservationIgnored var onPowerSnapshot:
        (@MainActor (PowerHeartbeatSnapshot) async -> Void)?

    init(
        detachPath: String,
        bundle: Bundle = .main,
        powerStateRoot: URL? = nil,
        defaults: UserDefaults = .standard,
        uiE2EScenario: String? = AppSettings.uiE2E?.scenario,
        contextOperationOverride:
            (@MainActor (InstallationContextOperation) async -> Void)? = nil,
        watchdog: (any InstallationWatchdogServicing)? = nil,
        powerHelper: (any InstallationPowerHelperServicing)? = nil,
        applicationLocationValidator: @escaping @MainActor (URL) -> Bool = {
            UpdateConfiguration.isStableApplicationLocation($0)
        },
        distributionClientFactory: (@MainActor
            (URL, URL, URL, URL) -> any InstallationDistributionServicing)? = nil,
        cliFactory: (@MainActor (URL) -> any DetachCLIRunning)? = nil
    ) {
        self.detachPath = detachPath
        self.watchdog = watchdog ?? WatchdogService()
        self.powerHelper = powerHelper ?? PowerHelperService()
        self.powerStateRoot = powerStateRoot ?? Self.defaultPowerStateRoot
        let heartbeatReader = PowerHeartbeatReader(
            statusURL: self.powerStateRoot
                .appendingPathComponent("watchdog-status.json"))
        self.heartbeatReader = heartbeatReader
        watchdogHeartbeatStorage = heartbeatReader.read()
        self.defaults = defaults
        onboardingEverCompleted = defaults.bool(
            forKey: Self.onboardingCompletedKey)
        self.contextOperationOverride = contextOperationOverride
        self.applicationLocationValidator = applicationLocationValidator
        self.distributionClientFactory = distributionClientFactory
            ?? Self.makeDistributionClient
        self.cliFactory = cliFactory ?? Self.makeCLI
        switch uiE2EScenario {
        case "onboarding-first-run": uiE2EOnboardingStep = .done
        case "onboarding-provider": uiE2EOnboardingStep = .provider
        case "onboarding-approval": uiE2EOnboardingStep = .permissions
        default: uiE2EOnboardingStep = nil
        }
        bundleURL = bundle.bundleURL.standardizedFileURL
        let candidate = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/DetachCLI", isDirectory: true)
        payloadDirectory = FileManager.default.fileExists(atPath: candidate.path)
            ? candidate : nil
        if let version = try? String(contentsOf: candidate.appendingPathComponent("VERSION"),
                                     encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let build = try? String(contentsOf: candidate.appendingPathComponent("BUILD"),
                                   encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let payloadID = try? String(contentsOf: candidate.appendingPathComponent("PAYLOAD_ID"),
                                       encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            bundledMetadata = BundledMetadata(version: version, build: build, payloadID: payloadID)
        } else {
            bundledMetadata = nil
        }
        powerProtectionState = watchdogHeartbeat.effectivePowerState
    }

    static func makeDistributionClient(
        installerURL: URL,
        cliURL: URL,
        payloadDirectory: URL,
        versionURL: URL
    ) -> any InstallationDistributionServicing {
        DistributionClient(
            installer: ProcessDetachCLI(executable: installerURL),
            cli: ProcessDetachCLI(executable: cliURL),
            payloadDirectory: payloadDirectory,
            versionFile: versionURL)
    }

    static func makeCLI(executable: URL) -> any DetachCLIRunning {
        ProcessDetachCLI(executable: executable)
    }

    var hasDistributionPayload: Bool { payloadDirectory != nil }
    var presentsUIE2EOnboarding: Bool { uiE2EOnboardingStep != nil }
    var isStableApplicationLocation: Bool {
        guard hasDistributionPayload else { return true }
        return applicationLocationValidator(bundleURL)
    }
    var isBusy: Bool { phase == .syncing || contextOperationRunning }

    func refreshPowerProtectionState() {
        publishPowerSnapshot(heartbeatReader.read())
    }

    func startPowerObservation() {
        guard heartbeatMonitor == nil else { return }
        let monitor = PowerHeartbeatMonitor(reader: heartbeatReader) {
            [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.publishPowerSnapshot(snapshot)
            }
        }
        heartbeatMonitor = monitor
        monitor.start()
        if let onPowerSnapshot {
            let snapshot = watchdogHeartbeat
            Task { @MainActor in
                await onPowerSnapshot(snapshot)
            }
        }
    }

    private func publishPowerSnapshot(_ snapshot: PowerHeartbeatSnapshot) {
        let previous = watchdogHeartbeatStorage
        let presentedStateChanged = !snapshot.hasSamePresentedState(as: previous)
        if presentedStateChanged {
            withMutation(keyPath: \.watchdogHeartbeat) {
                watchdogHeartbeatStorage = snapshot
            }
        } else {
            // Keep checked_at current without waking every view that reads the
            // heartbeat. The vnode monitor still reschedules its stale
            // deadline from every document.
            watchdogHeartbeatStorage = snapshot
        }
        if snapshot.effectivePowerState != powerProtectionState {
            powerProtectionState = snapshot.effectivePowerState
        }
        guard presentedStateChanged, let onPowerSnapshot else { return }
        Task { @MainActor in
            await onPowerSnapshot(snapshot)
        }
    }

    /// Pure registration-status read for live onboarding polling: no
    /// reconciliation, no doctor run, no XPC. A regression away from
    /// `.enabled` also withdraws the readiness confirmation so the
    /// permissions step cannot stay "passed" on stale evidence.
    func refreshRegistrationStatusesOnly() {
        refreshPowerProtectionState()
        powerHelperStatus = powerHelper.status
        watchdogStatus = watchdog.status
        if powerHelperStatus != .enabled {
            powerHelperReadinessConfirmed = false
        }
    }

    func markOnboardingCompleted() {
        refreshPowerProtectionState()
        guard watchdogHeartbeat.healthy else { return }
        onboardingEverCompleted = true
        defaults.set(true, forKey: Self.onboardingCompletedKey)
        uiE2EOnboardingStep = nil
    }

    var providerCheckPassed: Bool {
        report?.checks.first { $0.id == "provider" }?.status == .ok
    }

    /// The assistant card derived from current state; `.mainApp` means the
    /// dashboard is shown instead of onboarding.
    var onboardingStep: OnboardingStep {
        if let uiE2EOnboardingStep { return uiE2EOnboardingStep }
        var failureMessage: String?
        if case .failed(let message) = phase { failureMessage = message }
        return Self.onboardingStep(
            phase: phase,
            onboardingEverCompleted: onboardingEverCompleted,
            input: OnboardingStepInput(
            isStableApplicationLocation: isStableApplicationLocation,
            // `.idle` precedes the automatic bootstrap; both present as the
            // hands-off setting-up card.
            isBusy: isBusy || phase == .idle,
            failureMessage: failureMessage,
            distributionMatchesBundle: distributionMatchesBundle,
            powerHelperEnabled: powerHelperStatus == .enabled,
            watchdogEnabled: watchdogStatus == .enabled,
            powerReadinessConfirmed: powerHelperReadinessConfirmed,
            providerInstalled: providerCheckPassed,
            onboardingEverCompleted: onboardingEverCompleted))
    }

    static func onboardingStep(
        phase: Phase,
        onboardingEverCompleted: Bool,
        input: OnboardingStepInput
    ) -> OnboardingStep {
        let step = SetupGuidance.step(for: input)
        // A returning user keeps access to existing sessions when power
        // readiness regresses. The dashboard and Settings surface the error;
        // the runtime still fails closed before starting a new provider.
        if onboardingEverCompleted {
            switch phase {
            case .idle, .syncing, .updateDeferred, .ready:
                return .mainApp
            case .actionRequired, .failed:
                if !input.isStableApplicationLocation {
                    return .moveToApplications
                }
                if !input.distributionMatchesBundle {
                    return step
                }
                return .mainApp
            }
        }
        return step
    }

    func bootstrap() async {
        guard phase == .idle else { return }
        guard payloadDirectory != nil else {
            phase = .ready // `swift run` / tests keep the developer CLI workflow.
            return
        }
        guard isStableApplicationLocation else {
            phase = .actionRequired
            return
        }
        await synchronize(repair: false)
    }

    func repair() async {
        guard isStableApplicationLocation else { return }
        // A direct bootstrap/uninstall still owns `.syncing`; context work is
        // queued only behind another coordinated refresh/repair operation.
        guard phase != .syncing || contextOperationRunning else { return }
        await performContextOperation(.repair)
    }

    func openLoginItemsSettings() {
        watchdog.openLoginItemsSettings()
    }

    func openPowerHelperApprovalSettings() {
        powerHelper.openApprovalSettings()
    }

    var appContextChecks: [DiagnosticCheck] {
        let locationCheck = DiagnosticCheck(
            id: "app_location", section: .base,
            label: L10n.string("Application Location"),
            required: true, status: isStableApplicationLocation ? .ok : .error,
            path: bundleURL.path,
            summary: isStableApplicationLocation
                ? L10n.string("Detach.app is running from /Applications")
                : L10n.string("Move Detach.app to Applications and open the installed copy"))
        let distributionCheck = DiagnosticCheck(
            id: "app_cli_match", section: .base,
            label: L10n.string("App and CLI Version"),
            required: true, status: distributionMatchesBundle ? .ok : .error,
            path: detachPath,
            summary: distributionMatchesBundle
                ? L10n.string("The active CLI matches the application's version, build, and payload")
                : L10n.string("The CLI is missing or belongs to another build; run Repair from the intended app version"))
        let powerHelperCheck: DiagnosticCheck
        switch powerHelperStatus {
        case .enabled:
            if powerHelperReadinessConfirmed {
                powerHelperCheck = DiagnosticCheck(
                    id: "app_power_helper", section: .base,
                    label: L10n.string("Native Sleep Protection"),
                    required: true, status: .ok, path: nil,
                    summary: L10n.string("Native sleep protection is enabled"))
            } else {
                powerHelperCheck = DiagnosticCheck(
                    id: "app_power_helper", section: .base,
                    label: L10n.string("Native Sleep Protection"),
                    required: true,
                    status: powerHelperError == nil ? .warning : .error,
                    path: nil,
                    summary: L10n.string("Confirming protection readiness…"))
            }
        case .requiresApproval:
            powerHelperCheck = DiagnosticCheck(
                id: "app_power_helper", section: .base,
                label: L10n.string("Native Sleep Protection"),
                required: true, status: .warning, path: nil,
                summary: L10n.string(
                    "macOS is waiting for one-time administrator approval"))
        case .notRegistered:
            powerHelperCheck = DiagnosticCheck(
                id: "app_power_helper", section: .base,
                label: L10n.string("Native Sleep Protection"),
                required: true, status: .warning, path: nil,
                summary: L10n.string("Native sleep protection is not enabled yet"))
        case .unavailable:
            powerHelperCheck = DiagnosticCheck(
                id: "app_power_helper", section: .base,
                label: L10n.string("Native Sleep Protection"),
                required: true, status: .error, path: nil,
                summary: L10n.string("macOS could not register the native power helper"))
        }

        let watchdogCheck: DiagnosticCheck
        switch watchdogStatus {
        case .enabled:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Power Monitor"),
                required: true, status: .ok, path: nil,
                summary: L10n.string("Background power checks are enabled"))
        case .requiresApproval:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Power Monitor"),
                required: true, status: .error, path: nil,
                summary: L10n.string(
                    "macOS is waiting for permission to monitor power in the background"))
        case .notRegistered:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Power Monitor"),
                required: true, status: .error, path: nil,
                summary: L10n.string("Background power checks are not enabled yet"))
        case .unavailable:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Power Monitor"),
                required: true, status: .error, path: nil,
                summary: L10n.string("macOS has not registered the power monitor yet"))
        }
        return [
            locationCheck, distributionCheck, powerHelperCheck, watchdogCheck,
            watchdogHeartbeatCheck,
        ]
    }

    private var watchdogHeartbeatCheck: DiagnosticCheck {
        let snapshot = watchdogHeartbeat
        let expected = watchdogStatus == .enabled
        let healthySummary: String
        if let powerState = snapshot.powerState?.rawValue,
           !powerState.isEmpty {
            healthySummary = L10n.format(
                "The background monitor reported power state: %@", powerState)
        } else {
            healthySummary = L10n.string(
                "The background power monitor ran within the last three minutes")
        }
        return DiagnosticCheck(
            id: "watchdog_heartbeat", section: .base,
            label: L10n.string("Background Power Monitor Launch"),
            required: false,
            status: snapshot.healthy ? .ok : (expected ? .warning : .unknown),
            path: snapshot.statusURL.path,
            summary: snapshot.healthy
                ? healthySummary
                : (expected
                    ? L10n.string("The background power monitor is starting or needs attention")
                    : L10n.string("The background power monitor has not started yet")))
    }

    private static var defaultPowerStateRoot: URL {
        PowerHeartbeatReader.defaultStatusURL().deletingLastPathComponent()
    }

    @discardableResult
    func refreshContext() async -> Bool {
        // This read is side-effect free and useful even when a direct
        // bootstrap/uninstall owns `.syncing`; the coordinated trailing pass
        // will publish it again after refresh/repair work drains.
        refreshPowerProtectionState()
        guard phase != .syncing || contextOperationRunning else { return false }
        await performContextOperation(.refresh)
        return true
    }

    private func performContextOperation(
        _ requested: InstallationContextOperation
    ) async {
        if contextOperationRunning {
            switch requested {
            case .refresh:
                pendingContextRefresh = true
            case .repair:
                if currentContextOperation != .repair {
                    pendingContextRepair = true
                }
                // When Repair arrives during a refresh, converge once more
                // after Repair instead of letting the earlier refresh win.
                pendingContextRefresh = true
            }
            await withCheckedContinuation { continuation in
                contextOperationWaiters.append(continuation)
            }
            return
        }

        contextOperationRunning = true
        var operation: InstallationContextOperation? = requested
        while let current = operation {
            currentContextOperation = current
            if let contextOperationOverride {
                await contextOperationOverride(current)
            } else {
                switch current {
                case .refresh:
                    await refreshContextUncoordinated()
                case .repair:
                    guard isStableApplicationLocation else { break }
                    await synchronize(repair: true)
                }
            }
            currentContextOperation = nil
            if pendingContextRepair {
                pendingContextRepair = false
                operation = .repair
            } else if pendingContextRefresh {
                pendingContextRefresh = false
                operation = .refresh
            } else {
                operation = nil
            }
        }
        contextOperationRunning = false
        let waiters = contextOperationWaiters
        contextOperationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    private func refreshContextUncoordinated() async {
        refreshPowerProtectionState()
        if phase == .idle {
            await bootstrap()
            return
        }
        if phase == .updateDeferred && !distributionMatchesBundle {
            await synchronize(repair: false)
            return
        }
        let wasReady = phase == .ready
        if !wasReady { phase = .syncing }
        powerHelperStatus = powerHelper.status
        var powerHelperUpdateDeferred = false
        if distributionMatchesBundle {
            do {
                powerHelperUpdateDeferred = try await powerHelper
                    .reconcileAfterAppUpdate() == .deferredForActiveLeases
                powerHelperError = nil
            } catch {
                powerHelperError = error.localizedDescription
            }
            powerHelperStatus = powerHelper.status
        }
        // Keep a previously proven readiness snapshot through unrelated
        // doctor/provider refreshes. A registration regression or reconcile
        // failure withdraws it immediately; the fresh doctor pass below then
        // publishes the new proof. This prevents Provider -> Permissions UI
        // flashes on a routine provider refresh.
        if !distributionMatchesBundle || powerHelperError != nil
            || powerHelperStatus != .enabled {
            powerHelperReadinessConfirmed = false
        }
        watchdogStatus = watchdog.status
        if distributionMatchesBundle {
            do {
                let replaceSilentRegistration = !onboardingEverCompleted
                    && watchdogStatus == .enabled
                    && !watchdogHeartbeat.healthy
                try await watchdog.reconcileAfterAppUpdate(
                    forceReplacement: replaceSilentRegistration)
                watchdogError = nil
            } catch {
                watchdogError = error.localizedDescription
            }
            watchdogStatus = watchdog.status
        }
        if watchdogStatus == .enabled { watchdogError = nil }
        guard isStableApplicationLocation else {
            phase = .actionRequired
            return
        }
        if report != nil {
            await refreshDoctor(
                powerHelperUpdateDeferred: powerHelperUpdateDeferred)
        } else if powerHelperUpdateDeferred && onboardingEverCompleted {
            phase = .updateDeferred
        } else {
            updatePhase()
        }
    }

    func uninstall(purgeState: Bool) async {
        guard !isBusy, let payloadDirectory else { return }
        phase = .syncing
        let shouldRestoreWatchdog: Bool
        switch watchdog.status {
        case .enabled, .requiresApproval: shouldRestoreWatchdog = true
        case .notRegistered, .unavailable: shouldRestoreWatchdog = false
        }
        let shouldRestorePowerHelper: Bool
        switch powerHelper.status {
        case .enabled, .requiresApproval: shouldRestorePowerHelper = true
        case .notRegistered, .unavailable: shouldRestorePowerHelper = false
        }
        do {
            try await watchdog.disable()
            try await powerHelper.disable()
            let installer = cliFactory(
                payloadDirectory.appendingPathComponent("detach-install"))
            let result = try await installer.run(
                arguments: ["uninstall", purgeState ? "--purge-state" : "--keep-state"],
                timeout: 30)
            guard result.exitCode == 0, !result.timedOut else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DistributionClientError.installerFailed(
                    detail.isEmpty ? L10n.string("Uninstall failed") : detail)
            }
            report = nil
            distributionMatchesBundle = false
            watchdogStatus = watchdog.status
            powerHelperStatus = powerHelper.status
            powerHelperReadinessConfirmed = false
            lastInstallMessage = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .actionRequired
        } catch {
            if shouldRestorePowerHelper {
                try? await powerHelper.enable()
            }
            if shouldRestoreWatchdog {
                try? await watchdog.enable()
            }
            watchdogStatus = watchdog.status
            powerHelperStatus = powerHelper.status
            phase = .failed(L10n.format(
                "Could not remove components: %@",
                error.localizedDescription))
        }
    }

    private func synchronize(repair: Bool) async {
        guard let payloadDirectory else { phase = .ready; return }
        phase = .syncing
        let installerURL = payloadDirectory.appendingPathComponent("detach-install")
        let versionURL = payloadDirectory.appendingPathComponent("VERSION")
        let cliURL = URL(fileURLWithPath: detachPath)
        let client = distributionClientFactory(
            installerURL, cliURL, payloadDirectory, versionURL)
        do {
            lastInstallMessage = try await client.synchronize(repair: repair)
            report = try await client.doctor()
            guard let bundledMetadata, let report,
                  Self.installedRuntimeMatches(
                    report: report,
                    version: bundledMetadata.version,
                    build: bundledMetadata.build,
                    payloadID: bundledMetadata.payloadID) else {
                distributionMatchesBundle = false
                let unknown = L10n.string("unknown")
                let active = L10n.format(
                    "%@ build %@",
                    report?.version ?? unknown,
                    report?.build ?? unknown)
                throw DistributionClientError.installerFailed(
                    L10n.format(
                        "The active CLI (%@) does not match this application's payload; helper registration was cancelled",
                        active))
            }
            distributionMatchesBundle = true
        } catch {
            phase = !repair && onboardingEverCompleted
                ? .updateDeferred : .failed(error.localizedDescription)
            return
        }

        // The privileged daemon owns only the narrow closed-lid setting. Its
        // renewable leases and timer remain effective when Detach.app closes.
        powerHelperError = nil
        var powerHelperUpdateDeferred = false
        do {
            powerHelperUpdateDeferred = try await powerHelper
                .reconcileAfterAppUpdate() == .deferredForActiveLeases
        } catch {
            powerHelperError = error.localizedDescription
        }
        powerHelperStatus = powerHelper.status
        // Registration may legitimately stop at requiresApproval. Even an
        // enabled status is not sufficient until the post-registration doctor
        // pass proves the helper is reachable over XPC.
        powerHelperReadinessConfirmed = false

        // The user agent records an independently observable power heartbeat.
        watchdogError = nil
        do {
            refreshPowerProtectionState()
            let watchdogStatusBeforeReconcile = watchdog.status
            let replaceSilentRegistration = watchdogStatusBeforeReconcile == .enabled
                && !watchdogHeartbeat.healthy
                && (repair || !onboardingEverCompleted)
            try await watchdog.reconcileAfterAppUpdate(
                forceReplacement: replaceSilentRegistration)
        } catch {
            watchdogError = error.localizedDescription
        }
        watchdogStatus = watchdog.status

        // The first doctor run happens before SMAppService registration. Read
        // readiness again so a newly reachable helper can satisfy onboarding,
        // while approval or XPC failures remain visible instead of using the
        // stale pre-registration report.
        do {
            report = try await client.doctor()
        } catch {
            phase = powerHelperUpdateDeferred && onboardingEverCompleted
                ? .updateDeferred : .failed(error.localizedDescription)
            return
        }
        powerHelperReadinessConfirmed = Self.powerHelperReadiness(
            distributionMatchesBundle: distributionMatchesBundle,
            powerHelperStatus: powerHelperStatus,
            powerHelperError: powerHelperError,
            report: report)
        if powerHelperUpdateDeferred && onboardingEverCompleted {
            phase = .updateDeferred
        } else {
            updatePhase()
        }
    }

    private func refreshDoctor(
        powerHelperUpdateDeferred: Bool = false
    ) async {
        guard let payloadDirectory else { phase = .ready; return }
        let client = distributionClientFactory(
            payloadDirectory.appendingPathComponent("detach-install"),
            URL(fileURLWithPath: detachPath),
            payloadDirectory,
            payloadDirectory.appendingPathComponent("VERSION"))
        do {
            report = try await client.doctor()
            if let bundledMetadata, let report {
                distributionMatchesBundle = Self.installedRuntimeMatches(
                    report: report,
                    version: bundledMetadata.version,
                    build: bundledMetadata.build,
                    payloadID: bundledMetadata.payloadID)
            }
            guard distributionMatchesBundle else {
                powerHelperReadinessConfirmed = false
                phase = .failed(L10n.string(
                    "The CLI is missing or belongs to another build; run Repair from the intended app version"))
                return
            }
            powerHelperReadinessConfirmed = Self.powerHelperReadiness(
                distributionMatchesBundle: distributionMatchesBundle,
                powerHelperStatus: powerHelperStatus,
                powerHelperError: powerHelperError,
                report: report)
            if powerHelperUpdateDeferred && onboardingEverCompleted {
                phase = .updateDeferred
            } else {
                updatePhase()
            }
        } catch {
            powerHelperReadinessConfirmed = false
            phase = powerHelperUpdateDeferred && onboardingEverCompleted
                ? .updateDeferred : .failed(error.localizedDescription)
        }
    }

    private func updatePhase() {
        let requiredDoctorChecksHealthy = report.map { report in
            report.checks
                .filter {
                    $0.required && $0.id != "watchdog" && $0.id != "cli_path"
                }
                .allSatisfy { $0.status == .ok }
        }
        phase = Self.phaseForReadiness(
            isStableApplicationLocation: isStableApplicationLocation,
            distributionMatchesBundle: distributionMatchesBundle,
            requiredDoctorChecksHealthy: requiredDoctorChecksHealthy,
            watchdogStatus: watchdogStatus,
            powerHelperStatus: powerHelperStatus,
            powerHelperError: powerHelperError)
    }

    static func phaseForReadiness(
        isStableApplicationLocation: Bool,
        distributionMatchesBundle: Bool,
        requiredDoctorChecksHealthy: Bool?,
        watchdogStatus: WatchdogStatus,
        powerHelperStatus: PowerHelperRegistrationStatus,
        powerHelperError: String?
    ) -> Phase {
        guard isStableApplicationLocation,
              distributionMatchesBundle,
              requiredDoctorChecksHealthy == true,
              watchdogStatus == .enabled,
              powerHelperStatus == .enabled,
              powerHelperError == nil else {
            return .actionRequired
        }
        return .ready
    }

    static func powerHelperReadiness(
        distributionMatchesBundle: Bool,
        powerHelperStatus: PowerHelperRegistrationStatus,
        powerHelperError: String?,
        report: DoctorReport?
    ) -> Bool {
        guard distributionMatchesBundle,
              powerHelperStatus == .enabled,
              powerHelperError == nil,
              let check = report?.checks.first(where: { $0.id == "power_helper" }) else {
            return false
        }
        return check.status == .ok
    }

    static func installedRuntimeMatches(
        report: DoctorReport,
        version: String,
        build: String,
        payloadID: String
    ) -> Bool {
        guard report.matches(
            version: version, build: build, payloadID: payloadID) else {
            return false
        }
        let requiredIDs: Set<String> = [
            "integrity", "cli", "manifest", "tmux", "state_helper",
            "power_runtime",
        ]
        let healthyIDs = Set(report.checks.lazy.filter {
            $0.status == .ok && requiredIDs.contains($0.id)
        }.map(\.id))
        return healthyIDs == requiredIDs
    }
}
