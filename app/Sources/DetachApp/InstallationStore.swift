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
    private(set) var keepAwakeEnabled: Bool
    private(set) var distributionMatchesBundle = false

    private let detachPath: String
    private let watchdog = WatchdogService()
    private let payloadDirectory: URL?
    private let bundleURL: URL
    private let bundledMetadata: BundledMetadata?

    init(detachPath: String, bundle: Bundle = .main) {
        self.detachPath = detachPath
        bundleURL = bundle.bundleURL.standardizedFileURL
        keepAwakeEnabled = Self.readKeepAwakeSetting()
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
            id: "app_location", section: .base, label: "Расположение приложения",
            required: true, status: isStableApplicationLocation ? .ok : .error,
            path: bundleURL.path,
            summary: isStableApplicationLocation
                ? "Detach.app запущен из /Applications"
                : "Переместите Detach.app в Applications и откройте установленную копию")
        let distributionCheck = DiagnosticCheck(
            id: "app_cli_match", section: .base, label: "Версия app и CLI",
            required: true, status: distributionMatchesBundle ? .ok : .error,
            path: detachPath,
            summary: distributionMatchesBundle
                ? "Активный CLI совпадает с version/build/payload приложения"
                : "CLI отсутствует или принадлежит другой сборке; запусти Repair из нужной версии app")
        let watchdogCheck: DiagnosticCheck
        switch watchdogStatus {
        case .enabled:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Фоновая служба",
                required: keepAwakeEnabled, status: .ok, path: nil,
                summary: "Фоновая проверка включена")
        case .requiresApproval:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Фоновая служба",
                required: keepAwakeEnabled,
                status: keepAwakeEnabled ? .error : .warning, path: nil,
                summary: "macOS ожидает разрешение на фоновую работу")
        case .notRegistered:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Фоновая служба",
                required: keepAwakeEnabled,
                status: keepAwakeEnabled ? .error : .warning, path: nil,
                summary: "Фоновая проверка пока не включена")
        case .unavailable:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Фоновая служба",
                required: keepAwakeEnabled,
                status: keepAwakeEnabled ? .error : .warning, path: nil,
                summary: "macOS пока не зарегистрировала фоновую проверку")
        }
        return [locationCheck, distributionCheck, watchdogCheck, watchdogHeartbeatCheck]
    }

    private var watchdogHeartbeatCheck: DiagnosticCheck {
        struct Heartbeat: Decodable { let state: String }
        let statusURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/codex-detached-amphetamine/watchdog-status.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: statusURL.path)
        let modified = attributes?[.modificationDate] as? Date
        let fresh = modified.map { Date().timeIntervalSince($0) < 180 } ?? false
        let heartbeat = (try? Data(contentsOf: statusURL))
            .flatMap { try? JSONDecoder().decode(Heartbeat.self, from: $0) }
        let healthy = fresh && heartbeat?.state == "ok"
        let expected = watchdogStatus == .enabled && keepAwakeEnabled
        return DiagnosticCheck(
            id: "watchdog_heartbeat", section: .base, label: "Запуск фоновой службы",
            required: false,
            status: healthy ? .ok : (expected ? .warning : .unknown), path: statusURL.path,
            summary: healthy
                ? "Фоновая служба запускалась в последние три минуты"
                : (expected ? "Фоновая служба запускается или требует внимания"
                            : "Проверяется только при включённом keep-awake"))
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
        if keepAwakeEnabled && distributionMatchesBundle {
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

    func setKeepAwakeEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        phase = .syncing
        do {
            try Self.writeKeepAwakeSetting(enabled)
            keepAwakeEnabled = enabled
            if enabled {
                watchdogError = nil
                do {
                    try await watchdog.enable()
                } catch {
                    watchdogError = error.localizedDescription
                }
                watchdogStatus = watchdog.status
            } else {
                do {
                    try await watchdog.disable()
                    watchdogError = nil
                } catch {
                    watchdogError = error.localizedDescription
                }
                watchdogStatus = watchdog.status
            }
            await refreshDoctor()
        } catch {
            phase = .failed("Не удалось сохранить настройку keep-awake: \(error.localizedDescription)")
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
                    detail.isEmpty ? "Uninstall failed" : detail)
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
            phase = .failed("Не удалось удалить компоненты: \(error.localizedDescription)")
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
            keepAwakeEnabled = Self.readKeepAwakeSetting()
            report = try await client.doctor()
            guard let bundledMetadata,
                  report?.matches(version: bundledMetadata.version,
                                  build: bundledMetadata.build,
                                  payloadID: bundledMetadata.payloadID) == true else {
                distributionMatchesBundle = false
                let active = "\(report?.version ?? "unknown") build \(report?.build ?? "unknown")"
                throw DistributionClientError.installerFailed(
                    "Активная CLI (\(active)) не совпадает с payload этого приложения; откат watchdog отменён")
            }
            distributionMatchesBundle = true
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // The helper exists only for optional keep-awake cleanup. Register it
        // just in time when that feature is enabled; otherwise retire any
        // legacy/app service left by an older installation.
        watchdogError = nil
        do {
            if keepAwakeEnabled {
                try await watchdog.reconcileAfterAppUpdate()
            } else {
                try await watchdog.disable()
            }
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
        let backgroundHealthy = !keepAwakeEnabled || watchdogStatus == .enabled
        phase = baseHealthy && backgroundHealthy ? .ready : .actionRequired
    }

    private static var configURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["DETACH_CONFIG_ROOT"] {
            return URL(fileURLWithPath: root).appendingPathComponent("config")
        }
        if let root = environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: root).appendingPathComponent("detach/config")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/detach/config")
    }

    private static func readKeepAwakeSetting() -> Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }
        return text.split(separator: "\n").contains { $0 == "AMPHETAMINE=1" }
    }

    private static func writeKeepAwakeSetting(_ enabled: Bool) throws {
        let fileManager = FileManager.default
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("AMPHETAMINE=") }
        while lines.last == "" { lines.removeLast() }
        lines.append("AMPHETAMINE=\(enabled ? 1 : 0)")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: configURL.path)
    }
}
