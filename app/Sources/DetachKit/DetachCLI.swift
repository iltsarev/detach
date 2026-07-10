import Foundation

public struct CLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public protocol DetachCLIRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult
}

public final class ProcessDetachCLI: DetachCLIRunning, Sendable {
    public let executable: URL
    private let environment: [String: String]

    public init(executable: URL, environment: [String: String]? = nil) {
        self.executable = executable
        self.environment = Self.runtimeEnvironment(
            environment ?? ProcessInfo.processInfo.environment)
    }

    static func runtimeEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        var paths = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let home = base["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
        ]
        for path in commonPaths where !paths.contains(path) {
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    public func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Drain both pipes concurrently so >64 KiB of output cannot deadlock.
        let stdoutTask = Task.detached {
            (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let stderrTask = Task.detached {
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }

        // Poll for exit: no terminationHandler, no continuation races.
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var killDeadline: Date?
        while process.isRunning {
            let now = Date()
            if !timedOut && now > deadline {
                timedOut = true
                process.terminate()
                killDeadline = now.addingTimeInterval(2)
            } else if let forcedKillAt = killDeadline, now > forcedKillAt {
                // Kill only while this Process instance still reports its child
                // alive; do not leave a delayed task that can target a reused PID.
                kill(process.processIdentifier, SIGKILL)
                killDeadline = nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let stdout = String(data: await stdoutTask.value, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrTask.value, encoding: .utf8) ?? ""
        return CLIResult(exitCode: process.terminationStatus,
                         stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}
