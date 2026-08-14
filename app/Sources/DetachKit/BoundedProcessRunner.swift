import Darwin
import Foundation

public struct BoundedProcessRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL?
    public let timeout: TimeInterval
    public let terminationGrace: TimeInterval
    public let outputDrainGrace: TimeInterval
    public let maximumOutputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 2,
        outputDrainGrace: TimeInterval = 0.05,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = max(0.01, timeout)
        self.terminationGrace = max(0.01, terminationGrace)
        self.outputDrainGrace = max(0.01, outputDrainGrace)
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }
}

public struct BoundedProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let timedOut: Bool
}

public enum BoundedProcessError: Error, Equatable, Sendable {
    case posix(operation: String, code: Int32)
}

extension BoundedProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .posix(operation, code):
            return "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

private final class NonblockingPipeCapture: @unchecked Sendable {
    private let descriptor: Int32
    private let maximumBytes: Int
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var shouldStop = false
    private var captured = Data()

    init(descriptor: Int32, maximumBytes: Int) {
        self.descriptor = descriptor
        self.maximumBytes = maximumBytes
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                _ = Darwin.close(descriptor)
                group.leave()
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while !stopping {
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0)
                let pollResult = Darwin.poll(&pollDescriptor, 1, 50)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if pollResult == 0 { continue }
                while true {
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    if count > 0 {
                        append(bytes, count: Int(count))
                        continue
                    }
                    if count == 0 { return }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return
                }
            }
        }
    }

    func wait(until deadline: Date) -> Bool {
        group.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
    }

    func stopAndWait() {
        lock.lock()
        shouldStop = true
        lock.unlock()
        group.wait()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private var stopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop
    }

    private func append(_ bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard captured.count < maximumBytes else { return }
        captured.append(contentsOf: bytes.prefix(
            min(count, maximumBytes - captured.count)))
    }
}

/// Launches one command in its own process group, drains both output pipes,
/// and applies TERM/KILL to the complete group on timeout. A descendant that
/// merely inherits a pipe cannot keep the caller blocked after the leader
/// exits.
public struct BoundedProcessRunner: Sendable {
    public init() {}

    public func run(_ request: BoundedProcessRequest) throws -> BoundedProcessResult {
        let stdoutPipe = try makePipe()
        var stderrPipe: (read: Int32, write: Int32)?
        do {
            stderrPipe = try makePipe()
        } catch {
            _ = Darwin.close(stdoutPipe.read)
            _ = Darwin.close(stdoutPipe.write)
            throw error
        }
        guard let stderrPipe else {
            throw BoundedProcessError.posix(operation: "pipe", code: EIO)
        }

        let childPID: pid_t
        do {
            childPID = try spawn(
                request,
                stdoutDescriptor: stdoutPipe.write,
                stderrDescriptor: stderrPipe.write,
                inheritedDescriptors: [stdoutPipe.read, stderrPipe.read])
        } catch {
            for descriptor in [
                stdoutPipe.read, stdoutPipe.write,
                stderrPipe.read, stderrPipe.write,
            ] {
                _ = Darwin.close(descriptor)
            }
            throw error
        }
        _ = Darwin.close(stdoutPipe.write)
        _ = Darwin.close(stderrPipe.write)

        let stdout = NonblockingPipeCapture(
            descriptor: stdoutPipe.read,
            maximumBytes: request.maximumOutputBytes)
        let stderr = NonblockingPipeCapture(
            descriptor: stderrPipe.read,
            maximumBytes: request.maximumOutputBytes)
        stdout.start()
        stderr.start()

        var waitStatus: Int32 = 0
        var timedOut = false
        var sentKill = false
        let deadline = Date().addingTimeInterval(request.timeout)
        var killDeadline: Date?
        while true {
            let waitResult = Darwin.waitpid(childPID, &waitStatus, WNOHANG)
            if waitResult == childPID { break }
            if waitResult < 0 {
                if errno == EINTR { continue }
                let waitError = errno
                signalGroup(childPID, SIGKILL)
                stdout.stopAndWait()
                stderr.stopAndWait()
                throw BoundedProcessError.posix(
                    operation: "waitpid", code: waitError)
            }
            let instant = Date()
            if !timedOut && instant >= deadline {
                timedOut = true
                signalGroup(childPID, SIGTERM)
                killDeadline = instant.addingTimeInterval(
                    request.terminationGrace)
            } else if let killDeadline,
                      !sentKill,
                      instant >= killDeadline {
                signalGroup(childPID, SIGKILL)
                sentKill = true
            }
            usleep(10_000)
        }

        if timedOut {
            let forcedAt = killDeadline ?? Date()
            while processGroupExists(childPID), Date() < forcedAt {
                usleep(10_000)
            }
            if processGroupExists(childPID) {
                signalGroup(childPID, SIGKILL)
            }
        }

        let drainDeadline = Date().addingTimeInterval(
            request.outputDrainGrace)
        let stdoutFinished = stdout.wait(until: drainDeadline)
        let stderrFinished = stderr.wait(until: drainDeadline)
        if !stdoutFinished || !stderrFinished {
            // The leader is already reaped, so an open pipe proves that a
            // descendant inherited it. Retire that owned group before closing
            // the local reader.
            signalGroup(childPID, SIGTERM)
            let groupDeadline = Date().addingTimeInterval(
                request.outputDrainGrace)
            while processGroupExists(childPID), Date() < groupDeadline {
                usleep(10_000)
            }
            if processGroupExists(childPID) {
                signalGroup(childPID, SIGKILL)
            }
        }
        stdout.stopAndWait()
        stderr.stopAndWait()

        return BoundedProcessResult(
            exitCode: exitCode(from: waitStatus),
            standardOutput: stdout.data,
            standardError: stderr.data,
            timedOut: timedOut)
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw BoundedProcessError.posix(operation: "pipe", code: errno)
        }
        _ = Darwin.fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        return (descriptors[0], descriptors[1])
    }

    private func spawn(
        _ request: BoundedProcessRequest,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        inheritedDescriptors: [Int32]
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            throw BoundedProcessError.posix(
                operation: "posix_spawn_file_actions_init",
                code: actionsResult)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var actionResult = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, $0, O_RDONLY, 0)
        }
        guard actionResult == 0 else {
            throw BoundedProcessError.posix(
                operation: "posix_spawn_file_actions_addopen",
                code: actionResult)
        }
        for (source, destination) in [
            (stdoutDescriptor, STDOUT_FILENO),
            (stderrDescriptor, STDERR_FILENO),
        ] {
            actionResult = posix_spawn_file_actions_adddup2(
                &actions, source, destination)
            guard actionResult == 0 else {
                throw BoundedProcessError.posix(
                    operation: "posix_spawn_file_actions_adddup2",
                    code: actionResult)
            }
            actionResult = posix_spawn_file_actions_addclose(&actions, source)
            guard actionResult == 0 else {
                throw BoundedProcessError.posix(
                    operation: "posix_spawn_file_actions_addclose",
                    code: actionResult)
            }
        }
        for descriptor in inheritedDescriptors {
            actionResult = posix_spawn_file_actions_addclose(
                &actions, descriptor)
            guard actionResult == 0 else {
                throw BoundedProcessError.posix(
                    operation: "posix_spawn_file_actions_addclose",
                    code: actionResult)
            }
        }
        if let directory = request.currentDirectoryURL {
            actionResult = directory.path.withCString {
                // POSIX addchdir is macOS 26+; Darwin addchdir_np is the 15+ equivalent.
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
            guard actionResult == 0 else {
                throw BoundedProcessError.posix(
                    operation: "posix_spawn_file_actions_addchdir_np",
                    code: actionResult)
            }
        }

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            throw BoundedProcessError.posix(
                operation: "posix_spawnattr_init", code: attributesResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flagsResult = posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard flagsResult == 0 else {
            throw BoundedProcessError.posix(
                operation: "posix_spawnattr_setflags", code: flagsResult)
        }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else {
            throw BoundedProcessError.posix(
                operation: "posix_spawnattr_setpgroup", code: groupResult)
        }

        let arguments = [request.executableURL.path] + request.arguments
        let environment = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var childPID: pid_t = 0
        let spawnResult = try withCStringArray(arguments) { argumentPointers in
            try withCStringArray(environment) { environmentPointers in
                request.executableURL.path.withCString { path in
                    posix_spawn(
                        &childPID,
                        path,
                        &actions,
                        &attributes,
                        argumentPointers,
                        environmentPointers)
                }
            }
        }
        guard spawnResult == 0 else {
            throw BoundedProcessError.posix(
                operation: "posix_spawn", code: spawnResult)
        }
        return childPID
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else {
                throw BoundedProcessError.posix(
                    operation: "strdup", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw BoundedProcessError.posix(
                    operation: "CString array", code: EINVAL)
            }
            return try body(baseAddress)
        }
    }

    private func signalGroup(_ childPID: pid_t, _ signal: Int32) {
        _ = Darwin.kill(-childPID, signal)
    }

    private func processGroupExists(_ childPID: pid_t) -> Bool {
        Darwin.kill(-childPID, 0) == 0 || errno == EPERM
    }

    private func exitCode(from waitStatus: Int32) -> Int32 {
        let terminationStatus = waitStatus & 0x7f
        if terminationStatus == 0 { return (waitStatus >> 8) & 0xff }
        if terminationStatus != 0x7f { return 128 + terminationStatus }
        return 1
    }
}
