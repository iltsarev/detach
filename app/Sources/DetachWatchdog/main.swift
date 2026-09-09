import Darwin
import DetachKit
import Foundation

@_silgen_name("flock")
private func watchdogLifetimeFileLock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

private enum WatchdogLifetimeLockError: Error {
    case insecurePath
    case fileSystem(operation: String, code: Int32)
}

private final class WatchdogLifetimeLease {
    private let descriptor: Int32

    init(fileURL: URL) throws {
        descriptor = Darwin.open(
            fileURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw WatchdogLifetimeLockError.fileSystem(
                operation: "open", code: errno)
        }
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw WatchdogLifetimeLockError.fileSystem(
                    operation: "inspect", code: errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_nlink == 1,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0 else {
                throw WatchdogLifetimeLockError.insecurePath
            }
            guard watchdogLifetimeFileLock(
                descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw WatchdogLifetimeLockError.fileSystem(
                    operation: "lock", code: errno)
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw WatchdogLifetimeLockError.fileSystem(
                    operation: "fsync", code: errno)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = watchdogLifetimeFileLock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

let fileManager = FileManager.default
let environment = ProcessInfo.processInfo.environment
func environmentPath(_ key: String) -> String? {
    guard let value = environment[key], !value.isEmpty else { return nil }
    return value
}

let home = environmentPath("HOME") ?? fileManager.homeDirectoryForCurrentUser.path
// Keep this precedence aligned with WatchdogLifetimeBarrier.fileURL in the
// GUI: POWER override, then STATE, then XDG/detach, then HOME/.local/state.
let stateBaseRoot = environmentPath("DETACH_STATE_ROOT")
    ?? environmentPath("XDG_STATE_HOME").map {
        URL(fileURLWithPath: $0, isDirectory: true)
            .appendingPathComponent("detach", isDirectory: true).path
    }
    ?? URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".local/state/detach", isDirectory: true).path
let stateRoot = environmentPath("DETACH_POWER_STATE_ROOT")
    ?? URL(fileURLWithPath: stateBaseRoot, isDirectory: true)
        .appendingPathComponent("power", isDirectory: true).path
let logURL = URL(fileURLWithPath: stateRoot).appendingPathComponent("watchdog.log")
let statusURL = URL(fileURLWithPath: stateRoot).appendingPathComponent("watchdog-status.json")
let lifetimeLockURL = URL(fileURLWithPath: stateRoot)
    .appendingPathComponent("watchdog-lifetime.lock")
let detachURL = URL(fileURLWithPath: home)
    .appendingPathComponent(".local/bin/detach")

struct WatchdogHeartbeat: Codable {
    let schema: Int
    let checkedAt: String
    let state: String
    let powerState: String?
    let thermalState: String?
    let thermalSafetyActive: Bool?
    let lowBatteryThreshold: Int?
    let exitStatus: Int32

    enum CodingKeys: String, CodingKey {
        case schema
        case checkedAt = "checked_at"
        case state
        case powerState = "power_state"
        case thermalState = "thermal_state"
        case thermalSafetyActive = "thermal_safety_active"
        case lowBatteryThreshold = "low_battery_threshold"
        case exitStatus = "exit_status"
    }
}

func recordHeartbeat(
    state: String,
    powerState: String? = nil,
    thermalState: String? = nil,
    thermalSafetyActive: Bool? = nil,
    lowBatteryThreshold: Int? = nil,
    exitStatus: Int32
) {
    let heartbeat = WatchdogHeartbeat(
        schema: 1,
        checkedAt: ISO8601DateFormatter().string(from: Date()),
        state: state,
        powerState: powerState,
        thermalState: thermalState,
        thermalSafetyActive: thermalSafetyActive,
        lowBatteryThreshold: lowBatteryThreshold,
        exitStatus: exitStatus)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(heartbeat) else { return }
    try? data.write(to: statusURL, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600],
                                   ofItemAtPath: statusURL.path)
}

do {
    try fileManager.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let lifetimeLease = try WatchdogLifetimeLease(fileURL: lifetimeLockURL)
    defer { withExtendedLifetime(lifetimeLease) {} }
    if !fileManager.fileExists(atPath: logURL.path) {
        fileManager.createFile(atPath: logURL.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
    }
    let log = try FileHandle(forWritingTo: logURL)
    try log.seekToEnd()

    guard fileManager.isExecutableFile(atPath: detachURL.path) else {
        let message = "DetachWatchdog: CLI is not installed at \(detachURL.path)\n"
        try log.write(contentsOf: Data(message.utf8))
        recordHeartbeat(state: "cli_missing", exitStatus: 0)
        exit(0)
    }

    var childEnvironment = environment
    let commonPath = [
        "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")
    childEnvironment["PATH"] = commonPath
    childEnvironment["DETACH_POWER_STATE_ROOT"] = stateRoot
    let statusResult = try BoundedProcessRunner().run(BoundedProcessRequest(
        executableURL: detachURL,
        arguments: ["power", "status", "--json"],
        environment: childEnvironment,
        timeout: 5,
        terminationGrace: 1,
        maximumOutputBytes: 65_536))
    if !statusResult.standardError.isEmpty {
        try log.write(contentsOf: statusResult.standardError)
    }
    let statusData = statusResult.standardOutput

    if statusResult.timedOut {
        let message = "DetachWatchdog: power status timed out\n"
        try log.write(contentsOf: Data(message.utf8))
        recordHeartbeat(state: "status_timed_out", exitStatus: 1)
        exit(1)
    }

    guard statusResult.exitCode == 0 else {
        recordHeartbeat(
            state: "status_failed",
            exitStatus: statusResult.exitCode)
        exit(statusResult.exitCode)
    }

    struct PowerStatus: Decodable {
        let state: String
        let thermalState: String
        let thermalSafetyActive: Bool
        let lowBatteryThreshold: Int?

        enum CodingKeys: String, CodingKey {
            case state
            case thermalState = "thermal_state"
            case thermalSafetyActive = "thermal_safety_active"
            case lowBatteryThreshold = "low_battery_threshold"
        }
    }
    let knownStates: Set<String> = [
        "allowed", "transitioning", "protected", "low_battery", "temperature",
        "unavailable", "unknown",
    ]
    let knownThermalStates: Set<String> = [
        "nominal", "fair", "serious", "critical", "unknown",
    ]
    guard let powerStatus = try? JSONDecoder().decode(
            PowerStatus.self, from: statusData),
          knownStates.contains(powerStatus.state),
          knownThermalStates.contains(powerStatus.thermalState) else {
        let message = "DetachWatchdog: detach returned invalid power status JSON\n"
        try log.write(contentsOf: Data(message.utf8))
        recordHeartbeat(state: "invalid_status", exitStatus: 1)
        exit(1)
    }
    recordHeartbeat(
        state: "ok",
        powerState: powerStatus.state,
        thermalState: powerStatus.thermalState,
        thermalSafetyActive: powerStatus.thermalSafetyActive,
        lowBatteryThreshold: PowerLowBatteryThreshold.parse(
            powerStatus.lowBatteryThreshold).rawValue,
        exitStatus: 0)
    exit(0)
} catch {
    recordHeartbeat(state: "helper_failed", exitStatus: 1)
    FileHandle.standardError.write(Data("DetachWatchdog: \(error)\n".utf8))
    exit(1)
}
