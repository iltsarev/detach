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

    public init(executable: URL) {
        self.executable = executable
    }

    public func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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
        while process.isRunning {
            if !timedOut && Date() > deadline {
                timedOut = true
                process.terminate()
                Task.detached { [pid = process.processIdentifier] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    kill(pid, SIGKILL)
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let stdout = String(data: await stdoutTask.value, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrTask.value, encoding: .utf8) ?? ""
        return CLIResult(exitCode: process.terminationStatus,
                         stdout: stdout, stderr: stderr, timedOut: timedOut)
    }
}
