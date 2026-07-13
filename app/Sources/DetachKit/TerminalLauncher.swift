import Foundation

#if canImport(AppKit)
import AppKit

public struct TerminalLaunchFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case terminalUnavailable
        case commandFile
        case openFailed
        case incompatible
    }

    public let message: String
    public let reason: Reason

    public var requiresTerminalSelection: Bool {
        reason == .terminalUnavailable || reason == .incompatible
    }

}

public enum TerminalLauncher {
    static let acknowledgementTimeoutNanoseconds: UInt64 = 30_000_000_000

    /// Opens a private, self-deleting command file in the selected terminal.
    /// The bundle identifier is resolved for every launch, so moving or
    /// renaming the application does not invalidate the preference.
    @MainActor
    @discardableResult
    public static func open(
        command: String,
        terminalBundleIdentifier: String
    ) async -> TerminalLaunchFailure? {
        guard let terminal = TerminalCatalog.application(
            bundleIdentifier: terminalBundleIdentifier) else {
            return TerminalLaunchFailure(
                message: "Выбранный терминал не найден или не поддерживает файлы .command. Выберите другой терминал в настройках.",
                reason: .terminalUnavailable)
        }
        return await open(
            command: command,
            terminal: terminal,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            fileManager: .default,
            acknowledgementTimeoutNanoseconds: acknowledgementTimeoutNanoseconds,
            openApplication: openApplication)
    }

    @MainActor
    static func open(
        command: String,
        terminal: TerminalApplication,
        temporaryDirectory: URL,
        fileManager: FileManager,
        acknowledgementTimeoutNanoseconds: UInt64,
        openApplication: (URL, URL) async throws -> Void
    ) async -> TerminalLaunchFailure? {
        let commandURL: URL
        do {
            commandURL = try writeCommandFile(
                command: command,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager)
        } catch {
            return TerminalLaunchFailure(
                message: "Не удалось безопасно подготовить временную команду: \(error.localizedDescription)",
                reason: .commandFile)
        }

        do {
            try await openApplication(commandURL, terminal.applicationURL)
        } catch {
            removeCommandDirectory(containing: commandURL, fileManager: fileManager)
            return TerminalLaunchFailure(
                message: "\(terminal.displayName) не смог открыть команду: \(error.localizedDescription)",
                reason: .openFailed)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        while fileManager.fileExists(atPath: commandURL.path) {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if elapsed >= acknowledgementTimeoutNanoseconds {
                removeCommandDirectory(containing: commandURL, fileManager: fileManager)
                return TerminalLaunchFailure(
                    message: "\(terminal.displayName) открыл файл, но не запустил команду. Выберите другой терминал в настройках.",
                    reason: .incompatible)
            }
            do {
                try await Task.sleep(nanoseconds: min(100_000_000, acknowledgementTimeoutNanoseconds))
            } catch {
                removeCommandDirectory(containing: commandURL, fileManager: fileManager)
                return TerminalLaunchFailure(
                    message: "Запуск команды был отменён.",
                    reason: .openFailed)
            }
        }
        // The script normally removes its private directory itself. Clean it
        // here as well in case a terminal removed only the command file.
        removeCommandDirectory(containing: commandURL, fileManager: fileManager)
        return nil
    }

    @MainActor
    private static func openApplication(
        commandURL: URL,
        applicationURL: URL
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open(
                [commandURL],
                withApplicationAt: applicationURL,
                configuration: configuration) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
        }
    }

    static func commandFileContents(command: String) throws -> Data {
        guard !command.contains("\0") else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let script = """
        #!/bin/zsh
        command_file=$0
        command_dir=${command_file:h}
        /bin/rm -f -- "$command_file" || exit 125
        [[ ! -e "$command_file" ]] || exit 125
        /bin/rmdir -- "$command_dir" 2>/dev/null || true
        unset command_file command_dir
        exec /bin/zsh -lic \(shellQuoted(command))

        """
        return Data(script.utf8)
    }

    static func writeCommandFile(
        command: String,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        // The containing directory is private from the moment it is created,
        // so the command (which may contain a prompt) is never briefly exposed
        // with default permissions before chmod runs.
        let directory = temporaryDirectory
            .appendingPathComponent("Detach-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("run.command")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            try commandFileContents(command: command)
                .write(to: url, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: url.path)
            return url
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func removeCommandDirectory(
        containing commandURL: URL,
        fileManager: FileManager
    ) {
        try? fileManager.removeItem(at: commandURL.deletingLastPathComponent())
    }
}
#endif
