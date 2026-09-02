import Foundation

private struct NodeSemanticVersion: Comparable {
    private struct Identifier: Equatable {
        let raw: String
        let numeric: Bool

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs.numeric, rhs.numeric) {
            case (true, true):
                if lhs.raw.count != rhs.raw.count {
                    return lhs.raw.count < rhs.raw.count
                }
                return lhs.raw < rhs.raw
            case (true, false): return true
            case (false, true): return false
            case (false, false): return lhs.raw < rhs.raw
            }
        }
    }

    private let core: [Identifier]
    private let prerelease: [Identifier]?

    init?(_ entry: String) {
        var value = entry[...]
        if value.first == "v" || value.first == "V" {
            value = value.dropFirst()
        }
        let withoutBuild = value.split(
            separator: "+", maxSplits: 1,
            omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(
            separator: "-", maxSplits: 1,
            omittingEmptySubsequences: false)
        let coreParts = parts[0].split(
            separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3 else { return nil }
        var parsedCore: [Identifier] = []
        for part in coreParts {
            let raw = String(part)
            guard Self.isNumeric(raw),
                  raw == "0" || raw.first != "0" else { return nil }
            parsedCore.append(Identifier(raw: raw, numeric: true))
        }
        let parsedPrerelease: [Identifier]?
        if parts.count == 2 {
            let identifiers = parts[1].split(
                separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            var parsed: [Identifier] = []
            for identifier in identifiers {
                let raw = String(identifier)
                guard !raw.isEmpty,
                      raw.utf8.allSatisfy({
                          ($0 >= 48 && $0 <= 57)
                              || ($0 >= 65 && $0 <= 90)
                              || ($0 >= 97 && $0 <= 122)
                              || $0 == 45
                      }) else { return nil }
                let numeric = Self.isNumeric(raw)
                guard !numeric || raw == "0" || raw.first != "0" else {
                    return nil
                }
                parsed.append(Identifier(raw: raw, numeric: numeric))
            }
            parsedPrerelease = parsed
        } else {
            parsedPrerelease = nil
        }
        core = parsedCore
        prerelease = parsedPrerelease
    }

    static func < (lhs: NodeSemanticVersion, rhs: NodeSemanticVersion) -> Bool {
        for (left, right) in zip(lhs.core, rhs.core) where left != right {
            return left < right
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(left), .some(right)):
            for (leftIdentifier, rightIdentifier) in zip(left, right)
                where leftIdentifier != rightIdentifier {
                return leftIdentifier < rightIdentifier
            }
            return left.count < right.count
        }
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

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

public enum DetachCLIStreamError: Error, Equatable, Sendable {
    case unavailable
    case invalidEvent
    case exited(Int32)
}

public protocol DetachCLIRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult
    func run(
        arguments: [String],
        timeout: TimeInterval,
        currentDirectoryURL: URL?
    ) async throws -> CLIResult
    func sessionEvents() -> AsyncThrowingStream<SessionEvent, Error>
}

public extension DetachCLIRunning {
    func run(
        arguments: [String],
        timeout: TimeInterval,
        currentDirectoryURL _: URL?
    ) async throws -> CLIResult {
        try await run(arguments: arguments, timeout: timeout)
    }

    func sessionEvents() -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DetachCLIStreamError.unavailable)
        }
    }
}

public final class ProcessDetachCLI: DetachCLIRunning, Sendable {
    public let executable: URL
    private let environment: [String: String]
    private let processRunner: BoundedProcessRunner
    private let terminationGrace: TimeInterval
    private let outputDrainGrace: TimeInterval

    public init(
        executable: URL,
        environment: [String: String]? = nil,
        processRunner: BoundedProcessRunner = BoundedProcessRunner(),
        terminationGrace: TimeInterval = 2,
        outputDrainGrace: TimeInterval = 0.05
    ) {
        self.executable = executable
        self.environment = Self.runtimeEnvironment(
            environment ?? ProcessInfo.processInfo.environment,
            allowsDetachOverrides: environment != nil)
        self.processRunner = processRunner
        self.terminationGrace = terminationGrace
        self.outputDrainGrace = outputDrainGrace
    }

    static func runtimeEnvironment(
        _ base: [String: String],
        allowsDetachOverrides: Bool = true
    ) -> [String: String] {
        var environment = base
        if !allowsDetachOverrides {
            for key in environment.keys where key.hasPrefix("DETACH_")
                    && !key.hasPrefix("DETACH_UI_E2E_") {
                environment.removeValue(forKey: key)
            }
        }
        var paths = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let home = base["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.volta/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.fnm/current/bin",
            "\(home)/.npm-global/bin",
        ] + versionManagerBinPaths(home: home)
        for path in commonPaths where !paths.contains(path) {
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    private static func versionManagerBinPaths(home: String) -> [String] {
        let roots = [
            "\(home)/.nvm/versions/node",
            "\(home)/.local/share/mise/installs/node",
        ]
        let fileManager = FileManager.default
        return roots.flatMap { root -> [String] in
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else {
                return []
            }
            return entries.sorted { left, right in
                switch (NodeSemanticVersion(left), NodeSemanticVersion(right)) {
                case let (.some(leftVersion), .some(rightVersion)):
                    return leftVersion == rightVersion
                        ? left > right : leftVersion > rightVersion
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return left > right
                }
            }.map { "\(root)/\($0)/bin" }
        }
    }

    public func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        try await run(
            arguments: arguments,
            timeout: timeout,
            currentDirectoryURL: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true))
    }

    public func run(
        arguments: [String],
        timeout: TimeInterval,
        currentDirectoryURL: URL?
    ) async throws -> CLIResult {
        let request = BoundedProcessRequest(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout,
            terminationGrace: terminationGrace,
            outputDrainGrace: outputDrainGrace)
        let runner = processRunner
        let result = try await Task.detached {
            try runner.run(request)
        }.value
        return CLIResult(
            exitCode: result.exitCode,
            stdout: String(decoding: result.standardOutput, as: UTF8.self),
            stderr: String(decoding: result.standardError, as: UTF8.self),
            timedOut: result.timedOut)
    }

    public func sessionEvents() -> AsyncThrowingStream<SessionEvent, Error> {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["watch", "--json"]
        process.environment = environment
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            let task = Task.detached {
                defer {
                    if process.isRunning { process.terminate() }
                    try? output.fileHandleForReading.close()
                }
                do {
                    try Task.checkCancellation()
                    try process.run()
                    // A cancellation that landed between the check above and
                    // launch would otherwise leave this watcher running with
                    // no owner until its first line.
                    if Task.isCancelled {
                        process.terminate()
                        throw CancellationError()
                    }
                    for try await line in output.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()
                        guard let event = SessionEventParser.parse(line) else {
                            throw DetachCLIStreamError.invalidEvent
                        }
                        continuation.yield(event)
                    }
                    process.waitUntilExit()
                    guard Task.isCancelled || process.terminationStatus == 0 else {
                        throw DetachCLIStreamError.exited(process.terminationStatus)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
                try? output.fileHandleForReading.close()
            }
        }
    }
}
