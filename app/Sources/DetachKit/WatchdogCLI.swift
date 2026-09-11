import Darwin
import Foundation

/// Resolves the installed public CLI the same way production does: a regular
/// payload command under `libexec/detach/versions`, sibling `detach-core`, and
/// no inherited `DETACH_*_BIN` or `DYLD_*`.
public enum WatchdogCLI {
    public struct Resolution: Equatable, Sendable {
        public let executableURL: URL
        public let environment: [String: String]

        public init(executableURL: URL, environment: [String: String]) {
            self.executableURL = executableURL
            self.environment = environment
        }
    }

    public enum ResolutionFailure: Error, Equatable, Sendable {
        case missing
        case notRegularPayload
    }

    public static func resolve(
        home: URL,
        environment: [String: String],
        powerStateRoot: String,
        fileManager: FileManager = .default
    ) -> Result<Resolution, ResolutionFailure> {
        let publicCommand = home.appendingPathComponent(".local/bin/detach")
        guard fileManager.fileExists(atPath: publicCommand.path) else {
            return .failure(.missing)
        }
        guard let resolved = resolvePath(publicCommand, fileManager: fileManager),
              isRegularExecutable(resolved),
              isInstalledPayloadCommand(resolved, home: home),
              isRegularExecutable(
                resolved.deletingLastPathComponent()
                    .appendingPathComponent("detach-core"))
        else {
            return .failure(.notRegularPayload)
        }
        return .success(Resolution(
            executableURL: resolved,
            environment: childEnvironment(
                from: environment,
                home: home.path,
                powerStateRoot: powerStateRoot)))
    }

    public static func childEnvironment(
        from environment: [String: String],
        home: String,
        powerStateRoot: String
    ) -> [String: String] {
        var sanitized = environment
        for key in Array(sanitized.keys) {
            if key.hasPrefix("DYLD_")
                || (key.hasPrefix("DETACH_") && key.hasSuffix("_BIN")) {
                sanitized.removeValue(forKey: key)
            }
        }
        sanitized["PATH"] = [
            "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        sanitized["DETACH_POWER_STATE_ROOT"] = powerStateRoot
        return sanitized
    }

    static func resolvePath(
        _ source: URL,
        fileManager: FileManager
    ) -> URL? {
        var current = source
        var depth = 0
        while true {
            guard depth <= 40 else { return nil }
            guard fileManager.fileExists(atPath: current.path) else {
                return nil
            }
            if let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: current.path
            ) {
                if destination.hasPrefix("/") {
                    current = URL(fileURLWithPath: destination)
                } else {
                    current = current.deletingLastPathComponent()
                        .appendingPathComponent(destination)
                }
                depth += 1
                continue
            }
            let directory = current.deletingLastPathComponent()
                .resolvingSymlinksInPath()
            return directory.appendingPathComponent(current.lastPathComponent)
        }
    }

    static func isRegularExecutable(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func isInstalledPayloadCommand(_ url: URL, home: URL) -> Bool {
        guard url.lastPathComponent == "detach" else { return false }
        let versionsRoot = home
            .appendingPathComponent(".local/libexec/detach/versions", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let command = url.standardizedFileURL
        let versionDirectory = command.deletingLastPathComponent()
        let versions = versionDirectory.deletingLastPathComponent()
            .standardizedFileURL
        guard versions.path == versionsRoot.path else { return false }
        let versionID = versionDirectory.lastPathComponent
        return !versionID.isEmpty
            && versionID != "."
            && versionID != ".."
            && !versionID.hasPrefix(".")
            && !versionID.contains("/")
    }
}
