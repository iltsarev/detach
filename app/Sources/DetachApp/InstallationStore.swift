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
    private(set) var lastInstallMessage: String?
    private(set) var keepAwakeEnabled: Bool
    private(set) var automationStatus: AutomationStatus = .notChecked
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
        if UserDefaults.standard.bool(forKey: "terminalAutomationWasAllowed") {
            automationStatus = .allowed
        }
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
        let path = bundleURL.path
        return (path == "/Applications/Detach.app" || path.hasPrefix("/Applications/"))
            && !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
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

    func enableWatchdog() async {
        guard !isBusy, isStableApplicationLocation, distributionMatchesBundle else { return }
        phase = .syncing
        do {
            try await watchdog.enable()
            watchdogStatus = watchdog.status
            await refreshDoctor()
        } catch {
            watchdogStatus = watchdog.status
            phase = .failed("Не удалось включить watchdog: \(error.localizedDescription)")
        }
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
                : "Перетащи Detach.app в /Applications и открой установленную копию")
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
                id: "app_watchdog", section: .base, label: "Watchdog",
                required: true, status: .ok, path: nil,
                summary: "LaunchAgent включён через Login Items")
        case .requiresApproval:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Watchdog",
                required: true, status: .error, path: nil,
                summary: "Нужно разрешить Detach в System Settings → Login Items")
        case .notRegistered:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Watchdog",
                required: true, status: .error, path: nil,
                summary: "LaunchAgent ещё не включён")
        case .unavailable:
            watchdogCheck = DiagnosticCheck(
                id: "app_watchdog", section: .base, label: "Watchdog",
                required: true, status: .error, path: nil,
                summary: "Bundled LaunchAgent недоступен")
        }

        let automationCheck: DiagnosticCheck
        switch automationStatus {
        case .notChecked:
            automationCheck = DiagnosticCheck(
                id: "terminal_automation", section: .base, label: "Terminal Automation",
                required: true, status: .error, path: nil,
                summary: "Нажми «Проверить Terminal», чтобы запросить системное разрешение")
        case .allowed:
            automationCheck = DiagnosticCheck(
                id: "terminal_automation", section: .base, label: "Terminal Automation",
                required: true, status: .ok, path: nil,
                summary: "Detach может открывать интерактивные сессии в Terminal")
        case .denied(let message):
            automationCheck = DiagnosticCheck(
                id: "terminal_automation", section: .base, label: "Terminal Automation",
                required: true, status: .error, path: nil, summary: message)
        }
        return [locationCheck, distributionCheck, watchdogCheck, automationCheck,
                watchdogHeartbeatCheck]
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
        return DiagnosticCheck(
            id: "watchdog_heartbeat", section: .base, label: "Watchdog heartbeat",
            required: false, status: healthy ? .ok : .warning, path: statusURL.path,
            summary: healthy
                ? "Bundled helper запускался в последние три минуты"
                : "Heartbeat отсутствует, устарел или helper сообщил ошибку")
    }

    func checkTerminalAutomation() async {
        guard !isBusy, isStableApplicationLocation else { return }
        phase = .syncing
        automationStatus = await AutomationDiagnostics.probeTerminal()
        UserDefaults.standard.set(automationStatus == .allowed,
                                  forKey: "terminalAutomationWasAllowed")
        updatePhase()
    }

    func refreshContext() async {
        if phase == .idle {
            await bootstrap()
            return
        }
        guard !isBusy else { return }
        phase = .syncing
        watchdogStatus = watchdog.status
        if let current = await AutomationDiagnostics.preflightTerminal() {
            automationStatus = current
            UserDefaults.standard.set(current == .allowed,
                                      forKey: "terminalAutomationWasAllowed")
        }
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

    func openAutomationSettings() {
        AutomationDiagnostics.openAutomationSettings()
    }

    func setKeepAwakeEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        phase = .syncing
        do {
            try Self.writeKeepAwakeSetting(enabled)
            keepAwakeEnabled = enabled
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
            try await watchdog.reconcileAfterAppUpdate()
            watchdogStatus = watchdog.status
            updatePhase()
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
            .filter { $0.required && $0.id != "watchdog" }
            .allSatisfy { $0.status == .ok }
        phase = baseHealthy && watchdogStatus == .enabled && automationStatus == .allowed
            ? .ready : .actionRequired
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
