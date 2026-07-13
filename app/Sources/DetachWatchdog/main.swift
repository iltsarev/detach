import Foundation

let fileManager = FileManager.default
let environment = ProcessInfo.processInfo.environment
func environmentPath(_ key: String) -> String? {
    guard let value = environment[key], !value.isEmpty else { return nil }
    return value
}

let home = environmentPath("HOME") ?? fileManager.homeDirectoryForCurrentUser.path
let stateBaseRoot = environmentPath("DETACH_STATE_ROOT")
    ?? environmentPath("XDG_STATE_HOME").map {
        URL(fileURLWithPath: $0, isDirectory: true)
            .appendingPathComponent("detach", isDirectory: true).path
    }
    ?? URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".local/state/detach", isDirectory: true).path
let stateRoot = environmentPath("DETACH_AMPHETAMINE_STATE_ROOT")
    ?? URL(fileURLWithPath: stateBaseRoot, isDirectory: true)
        .appendingPathComponent("amphetamine", isDirectory: true).path
let logURL = URL(fileURLWithPath: stateRoot).appendingPathComponent("watchdog.log")
let statusURL = URL(fileURLWithPath: stateRoot).appendingPathComponent("watchdog-status.json")
let detachURL = URL(fileURLWithPath: home)
    .appendingPathComponent(".local/bin/detach")

struct WatchdogHeartbeat: Codable {
    let schema: Int
    let checkedAt: String
    let state: String
    let exitStatus: Int32
}

func recordHeartbeat(state: String, exitStatus: Int32) {
    let heartbeat = WatchdogHeartbeat(
        schema: 1,
        checkedAt: ISO8601DateFormatter().string(from: Date()),
        state: state,
        exitStatus: exitStatus)
    guard let data = try? JSONEncoder().encode(heartbeat) else { return }
    try? data.write(to: statusURL, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600],
                                   ofItemAtPath: statusURL.path)
}

do {
    try fileManager.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
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

    let process = Process()
    process.executableURL = detachURL
    process.arguments = ["__reconcile_amphetamine"]
    var childEnvironment = environment
    let commonPath = [
        "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")
    childEnvironment["PATH"] = commonPath
    childEnvironment["DETACH_AMPHETAMINE_STATE_ROOT"] = stateRoot
    process.environment = childEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = log
    try process.run()
    process.waitUntilExit()
    recordHeartbeat(
        state: process.terminationStatus == 0 ? "ok" : "reconcile_failed",
        exitStatus: process.terminationStatus)
    exit(process.terminationStatus)
} catch {
    recordHeartbeat(state: "helper_failed", exitStatus: 1)
    FileHandle.standardError.write(Data("DetachWatchdog: \(error)\n".utf8))
    exit(1)
}
