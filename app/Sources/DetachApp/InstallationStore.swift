import Foundation
import Observation
import DetachKit

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
        case actionRequired
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: DoctorReport?
    private(set) var watchdogStatus: WatchdogStatus = .unavailable
    private(set) var watchdogError: String?
    private(set) var lastInstallMessage: String?
    private(set) var distributionMatchesBundle = false

    private let detachPath: String
    private let watchdog = WatchdogService()
    private let payloadDirectory: URL?
    private let bundleURL: URL
    private let bundledMetadata: BundledMetadata?

    init(detachPath: String, bundle: Bundle = .main) {
        self.detachPath = detachPath
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
    }

    var hasDistributionPayload: Bool { payloadDirectory != nil }
    var isStableApplicationLocation: Bool {
        guard hasDistributionPayload else { return true }
        return UpdateConfiguration.isStableApplicationLocation(bundleURL)
    }
    var isBusy: Bool { phase == .syncing }

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
        guard !isBusy, isStableApplicationLocation else { return }
        await synchronize(repair: true)
    }

    func openLoginItemsSettings() {
        watchdog.openLoginItemsSettings()
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
        let watchdogCheck: DiagnosticCheck
        switch watchdogStatus {
        case .enabled:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Service"),
                required: true, status: .ok, path: nil,
                summary: L10n.string("Background checks are enabled"))
        case .requiresApproval:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Service"),
                required: true, status: .error, path: nil,
                summary: L10n.string("macOS is waiting for permission to run in the background"))
        case .notRegistered:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Service"),
                required: true, status: .error, path: nil,
                summary: L10n.string("Background checks are not enabled yet"))
        case .unavailable:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base,
                label: L10n.string("Background Service"),
                required: true, status: .error, path: nil,
                summary: L10n.string("macOS has not registered the background check yet"))
        }
        return [locationCheck, distributionCheck, watchdogCheck, watchdogHeartbeatCheck]
    }

    private var watchdogHeartbeatCheck: DiagnosticCheck {
        struct Heartbeat: Decodable { let state: String }
        let statusURL = Self.amphetamineStateRoot
            .appendingPathComponent("watchdog-status.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: statusURL.path)
        let modified = attributes?[.modificationDate] as? Date
        let fresh = modified.map { Date().timeIntervalSince($0) < 180 } ?? false
        let heartbeat = (try? Data(contentsOf: statusURL))
            .flatMap { try? JSONDecoder().decode(Heartbeat.self, from: $0) }
        let healthy = fresh && heartbeat?.state == "ok"
        let expected = watchdogStatus == .enabled
        return DiagnosticCheck(
            id: "watchdog_heartbeat", section: .base,
            label: L10n.string("Background Service Launch"),
            required: false,
            status: healthy ? .ok : (expected ? .warning : .unknown), path: statusURL.path,
            summary: healthy
                ? L10n.string("The background service ran within the last three minutes")
                : (expected
                    ? L10n.string("The background service is starting or needs attention")
                    : L10n.string("The required background service has not started yet")))
    }

    private static var amphetamineStateRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String) -> String? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value
        }
        if let explicit = path("DETACH_AMPHETAMINE_STATE_ROOT") {
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
        return base.appendingPathComponent("amphetamine", isDirectory: true)
    }

    func refreshContext() async {
        if phase == .idle {
            await bootstrap()
            return
        }
        guard !isBusy else { return }
        let wasReady = phase == .ready
        if !wasReady { phase = .syncing }
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
        do {
            try await watchdog.disable()
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
            lastInstallMessage = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .actionRequired
        } catch {
            if shouldRestoreWatchdog {
                try? await watchdog.enable()
            }
            watchdogStatus = watchdog.status
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
                        "The active CLI (%@) does not match this application's payload; the watchdog rollback was cancelled",
                        active))
            }
            distributionMatchesBundle = true
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // Keep-awake is a core prerequisite. The helper must stay registered so
        // it can reconcile stale Amphetamine leases even when the app is closed.
        watchdogError = nil
        do {
            try await watchdog.reconcileAfterAppUpdate()
        } catch {
            watchdogError = error.localizedDescription
        }
        watchdogStatus = watchdog.status
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
        guard isStableApplicationLocation, distributionMatchesBundle else {
            phase = .actionRequired
            return
        }
        guard let report else { phase = .actionRequired; return }
        let baseHealthy = report.checks
            .filter { $0.required && $0.id != "watchdog" && $0.id != "cli_path" }
            .allSatisfy { $0.status == .ok }
        let backgroundHealthy = watchdogStatus == .enabled
        phase = baseHealthy && backgroundHealthy ? .ready : .actionRequired
    }
}
