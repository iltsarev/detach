import Foundation
import Observation
import DetachKit

enum InstallationContextOperation: Equatable, Sendable {
    case refresh
    case repair
}

@Observable @MainActor
final class InstallationStore {
    private struct BundledMetadata {
        let version: String
        let build: String
        let payloadID: String
    }

    private struct WatchdogHeartbeat: Decodable {
        let state: String
        let powerState: String?

        private enum CodingKeys: String, CodingKey {
            case state
            case powerState = "power_state"
        }
    }

    private struct WatchdogHeartbeatSnapshot {
        let statusURL: URL
        let heartbeat: WatchdogHeartbeat?
        let fresh: Bool

        var healthy: Bool { fresh && heartbeat?.state == "ok" }
    }

    enum Phase: Equatable {
        case idle
        case syncing
        case actionRequired
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: DoctorReport?
    private(set) var watchdogStatus: WatchdogStatus = .unavailable
    private(set) var watchdogError: String?
    private(set) var powerHelperStatus: PowerHelperRegistrationStatus = .unavailable
    private(set) var powerHelperError: String?
    private(set) var lastInstallMessage: String?
    private(set) var distributionMatchesBundle = false
    private(set) var powerProtectionState: PowerProtectionState = .unknown

    private let detachPath: String
    private let watchdog = WatchdogService()
    private let powerHelper = PowerHelperService()
    private let payloadDirectory: URL?
    private let bundleURL: URL
    private let bundledMetadata: BundledMetadata?
    private let powerStateRoot: URL
    private let contextOperationOverride:
        (@MainActor (InstallationContextOperation) async -> Void)?
    private var contextOperationRunning = false
    @ObservationIgnored private var currentContextOperation:
        InstallationContextOperation?
    @ObservationIgnored private var pendingContextRefresh = false
    @ObservationIgnored private var pendingContextRepair = false
    @ObservationIgnored private var contextOperationWaiters:
        [CheckedContinuation<Void, Never>] = []

    init(
        detachPath: String,
        bundle: Bundle = .main,
        powerStateRoot: URL? = nil,
        contextOperationOverride:
            (@MainActor (InstallationContextOperation) async -> Void)? = nil
    ) {
        self.detachPath = detachPath
        self.powerStateRoot = powerStateRoot ?? Self.defaultPowerStateRoot
        self.contextOperationOverride = contextOperationOverride
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
        refreshPowerProtectionState()
    }

    var hasDistributionPayload: Bool { payloadDirectory != nil }
    var isStableApplicationLocation: Bool {
        guard hasDistributionPayload else { return true }
        return UpdateConfiguration.isStableApplicationLocation(bundleURL)
    }
    var isBusy: Bool { phase == .syncing || contextOperationRunning }
    func refreshPowerProtectionState() {
        let snapshot = watchdogHeartbeatSnapshot
        guard snapshot.healthy,
              let rawValue = snapshot.heartbeat?.powerState,
              let state = PowerProtectionState(rawValue: rawValue) else {
            powerProtectionState = .unknown
            return
        }
        powerProtectionState = state
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
            powerHelperCheck = DiagnosticCheck(
                id: "app_power_helper", section: .base,
                label: L10n.string("Native Sleep Protection"),
                required: true, status: .ok, path: nil,
                summary: L10n.string("Native sleep protection is enabled"))
        case .requiresApproval:
            powerHelperCheck = DiagnosticCheck(
                id: "app_power_helper", section: .base,
                label: L10n.string("Native Sleep Protection"),
                required: true, status: .error, path: nil,
                summary: L10n.string(
                    "macOS is waiting for one-time administrator approval"))
        case .notRegistered:
            powerHelperCheck = DiagnosticCheck(
                id: "app_power_helper", section: .base,
                label: L10n.string("Native Sleep Protection"),
                required: true, status: .error, path: nil,
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
        let snapshot = watchdogHeartbeatSnapshot
        let expected = watchdogStatus == .enabled
        let healthySummary: String
        if let powerState = snapshot.heartbeat?.powerState,
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

    private var watchdogHeartbeatSnapshot: WatchdogHeartbeatSnapshot {
        let statusURL = powerStateRoot
            .appendingPathComponent("watchdog-status.json")
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: statusURL.path)
        let modified = attributes?[.modificationDate] as? Date
        let fresh = modified.map {
            let age = Date().timeIntervalSince($0)
            return age >= 0 && age < 180
        } ?? false
        let heartbeat = (try? Data(contentsOf: statusURL))
            .flatMap {
                try? JSONDecoder().decode(
                    WatchdogHeartbeat.self, from: $0)
            }
        return WatchdogHeartbeatSnapshot(
            statusURL: statusURL, heartbeat: heartbeat, fresh: fresh)
    }

    private static var defaultPowerStateRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }
        if let explicit = path("DETACH_POWER_STATE_ROOT") {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let base: URL
        if let explicit = path("DETACH_STATE_ROOT") {
            base = URL(fileURLWithPath: explicit, isDirectory: true)
        } else if let xdgStateHome = path("XDG_STATE_HOME") {
            base = URL(fileURLWithPath: xdgStateHome, isDirectory: true)
                .appendingPathComponent("detach", isDirectory: true)
        } else {
            let home = path("HOME").map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.homeDirectoryForCurrentUser
            base = home.appendingPathComponent(".local/state/detach", isDirectory: true)
        }
        return base.appendingPathComponent("power", isDirectory: true)
    }

    func refreshContext() async {
        // This read is side-effect free and useful even when a direct
        // bootstrap/uninstall owns `.syncing`; the coordinated trailing pass
        // will publish it again after refresh/repair work drains.
        refreshPowerProtectionState()
        guard phase != .syncing || contextOperationRunning else { return }
        await performContextOperation(.refresh)
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
        let wasReady = phase == .ready
        if !wasReady { phase = .syncing }
        powerHelperStatus = powerHelper.status
        if distributionMatchesBundle {
            do {
                try await powerHelper.reconcileAfterAppUpdate()
                powerHelperError = nil
            } catch {
                powerHelperError = error.localizedDescription
            }
            powerHelperStatus = powerHelper.status
        }
        watchdogStatus = watchdog.status
        if distributionMatchesBundle {
            do {
                try await watchdog.reconcileAfterAppUpdate()
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
            await refreshDoctor()
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
            let installer = ProcessDetachCLI(
                executable: payloadDirectory.appendingPathComponent("detach-install"))
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
        let client = DistributionClient(
            installer: ProcessDetachCLI(executable: installerURL),
            cli: ProcessDetachCLI(executable: cliURL),
            payloadDirectory: payloadDirectory,
            versionFile: versionURL)
        do {
            lastInstallMessage = try await client.synchronize(repair: repair)
            report = try await client.doctor()
            guard let bundledMetadata,
                  report?.matches(version: bundledMetadata.version,
                                  build: bundledMetadata.build,
                                  payloadID: bundledMetadata.payloadID) == true else {
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
            phase = .failed(error.localizedDescription)
            return
        }

        // The privileged daemon owns only the narrow closed-lid setting. Its
        // renewable leases and timer remain effective when Detach.app closes.
        powerHelperError = nil
        do {
            try await powerHelper.reconcileAfterAppUpdate()
        } catch {
            powerHelperError = error.localizedDescription
        }
        powerHelperStatus = powerHelper.status

        // The user agent records an independently observable power heartbeat.
        watchdogError = nil
        do {
            try await watchdog.reconcileAfterAppUpdate()
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
            phase = .failed(error.localizedDescription)
            return
        }
        updatePhase()
    }

    private func refreshDoctor() async {
        guard let payloadDirectory else { phase = .ready; return }
        let client = DistributionClient(
            installer: ProcessDetachCLI(executable: payloadDirectory.appendingPathComponent("detach-install")),
            cli: ProcessDetachCLI(executable: URL(fileURLWithPath: detachPath)),
            payloadDirectory: payloadDirectory,
            versionFile: payloadDirectory.appendingPathComponent("VERSION"))
        do {
            report = try await client.doctor()
            if let bundledMetadata {
                distributionMatchesBundle = report?.matches(
                    version: bundledMetadata.version,
                    build: bundledMetadata.build,
                    payloadID: bundledMetadata.payloadID) == true
            }
            updatePhase()
        } catch {
            phase = .failed(error.localizedDescription)
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
}
