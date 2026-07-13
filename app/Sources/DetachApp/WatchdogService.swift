import AppKit
import CryptoKit
import Foundation
import ServiceManagement

enum WatchdogStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
final class WatchdogService {
    static let plistName = "dev.tsarev.codex-detached-watchdog.plist"
    private let service = SMAppService.agent(plistName: plistName)
    private let digestKey = "watchdogDefinitionDigest"
    private let pendingDigestKey = "watchdogDefinitionReconcilePending"

    var status: WatchdogStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func reconcileAfterAppUpdate() async throws {
        guard let digest = definitionDigest() else { return }
        let previous = UserDefaults.standard.string(forKey: digestKey)
        let pending = UserDefaults.standard.bool(forKey: pendingDigestKey)
        guard previous != digest || pending else { return }
        switch status {
        case .enabled, .requiresApproval:
            UserDefaults.standard.set(true, forKey: pendingDigestKey)
            try await unregisterAndWait()
        case .notRegistered where pending:
            break
        case .notRegistered, .unavailable:
            return
        }
        do {
            try registerAllowingApproval()
        } catch {
            UserDefaults.standard.set(true, forKey: pendingDigestKey)
            throw error
        }
        UserDefaults.standard.set(digest, forKey: digestKey)
        UserDefaults.standard.set(false, forKey: pendingDigestKey)
    }

    func enable() async throws {
        if status == .enabled {
            rememberDefinition()
            UserDefaults.standard.set(false, forKey: pendingDigestKey)
            return
        }
        let migration = try prepareLegacyMigration()
        do {
            try registerAllowingApproval()
            if let migration {
                try? FileManager.default.removeItem(at: migration.backup)
            }
            rememberDefinition()
            UserDefaults.standard.set(false, forKey: pendingDigestKey)
        } catch {
            if let migration {
                try? migration.contents.write(to: migration.original, options: .atomic)
                _ = runLaunchctl(["bootstrap", "gui/\(getuid())", migration.original.path])
            }
            throw error
        }
    }

    func disable() async throws {
        guard status != .notRegistered && status != .unavailable else { return }
        try await unregisterAndWait()
        UserDefaults.standard.removeObject(forKey: digestKey)
        UserDefaults.standard.removeObject(forKey: pendingDigestKey)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func unregisterAndWait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func registerAllowingApproval() throws {
        do {
            try service.register()
        } catch {
            guard service.status == .requiresApproval else { throw error }
        }
    }

    private func definitionDigest() -> String? {
        let contents = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
        guard let plist = try? Data(contentsOf: contents
                .appendingPathComponent("Library/LaunchAgents/\(Self.plistName)")),
              let helper = try? Data(contentsOf: contents
                .appendingPathComponent("MacOS/DetachWatchdog")) else { return nil }
        var data = Data()
        data.append(plist)
        data.append(helper)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func rememberDefinition() {
        if let digest = definitionDigest() {
            UserDefaults.standard.set(digest, forKey: digestKey)
        }
    }

    private struct LegacyMigration {
        let original: URL
        let backup: URL
        let contents: Data
    }

    private func prepareLegacyMigration() throws -> LegacyMigration? {
        let original = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.plistName)")
        let backup = original.appendingPathExtension("detach-backup")
        let source = FileManager.default.fileExists(atPath: original.path) ? original : backup
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let contents = try Data(contentsOf: source)
        try contents.write(to: backup, options: .atomic)
        if FileManager.default.fileExists(atPath: original.path) {
            _ = runLaunchctl(["bootout", "gui/\(getuid())", original.path])
            try FileManager.default.removeItem(at: original)
        }
        return LegacyMigration(original: original, backup: backup, contents: contents)
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
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
