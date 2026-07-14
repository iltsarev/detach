import XCTest
@testable import DetachKit

final class TerminalLauncherTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCommandFileIsPrivateExecutableAndPreservesCommand() throws {
        let command = #"echo "it's $HOME" && exec '/tmp/a b'"#
        let url = try TerminalLauncher.writeCommandFile(
            command: command,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)

        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix("Detach-"))
        XCTAssertEqual(url.lastPathComponent, "run.command")
        XCTAssertEqual(url.pathExtension, "command")
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(
            directoryAttributes[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o700))
        XCTAssertTrue(contents.hasPrefix("#!/bin/zsh\n"))
        XCTAssertLessThan(
            try XCTUnwrap(contents.range(of: "builtin cd -q --")?.lowerBound),
            try XCTUnwrap(contents.range(of: "/bin/rm -f -- \"$command_file\"")?.lowerBound))
        XCTAssertLessThan(
            try XCTUnwrap(contents.range(of: "/bin/rm -f -- \"$command_file\" || exit 125")?.lowerBound),
            try XCTUnwrap(contents.range(of: "exec /bin/zsh -lic")?.lowerBound))
        XCTAssertTrue(contents.contains("[[ ! -e \"$command_file\" ]] || exit 125"))
        XCTAssertTrue(contents.contains("/bin/rmdir -- \"$command_dir\""))
        XCTAssertTrue(contents.contains("exec /bin/zsh -lic \(shellQuoted(command))"))
    }

    func testCommandFileLeavesItsDirectoryBeforeDeletingIt() throws {
        let safeHome = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
        let zdotdir = temporaryDirectory.appendingPathComponent("zdotdir", isDirectory: true)
        try FileManager.default.createDirectory(at: safeHome, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: false)
        let url = try TerminalLauncher.writeCommandFile(
            command: "exec /bin/pwd",
            temporaryDirectory: temporaryDirectory,
            fileManager: .default)
        let commandDirectory = url.deletingLastPathComponent()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["./run.command"]
        process.currentDirectoryURL = commandDirectory
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = safeHome.path
        environment["ZDOTDIR"] = zdotdir.path
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), safeHome.path)
        XCTAssertFalse(stderr.contains("getcwd"), stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandDirectory.path))
    }

    @MainActor
    func testSuccessfulLaunchRequiresCommandFileAcknowledgement() async throws {
        let terminal = TerminalApplication(
            bundleIdentifier: "test.terminal",
            displayName: "Test Terminal",
            applicationURL: URL(fileURLWithPath: "/Applications/Test Terminal.app"))
        var openedApplicationURL: URL?
        let failure = await TerminalLauncher.open(
            command: "exec /usr/bin/true",
            terminal: terminal,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default,
            acknowledgementTimeoutNanoseconds: 1_000_000,
            openApplication: { commandURL, applicationURL in
                openedApplicationURL = applicationURL
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: commandURL.path))
                try FileManager.default.removeItem(at: commandURL)
            })

        XCTAssertNil(failure)
        XCTAssertEqual(openedApplicationURL, terminal.applicationURL)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path))?.isEmpty
                == true)
    }

    @MainActor
    func testTerminalThatDoesNotExecuteCommandFileGetsExplicitFailure() async {
        let terminal = TerminalApplication(
            bundleIdentifier: "test.incompatible",
            displayName: "Viewer",
            applicationURL: URL(fileURLWithPath: "/Applications/Viewer.app"))
        var commandURL: URL?
        let failure = await TerminalLauncher.open(
            command: "exec /usr/bin/true",
            terminal: terminal,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default,
            acknowledgementTimeoutNanoseconds: 0,
            openApplication: { url, _ in commandURL = url })

        XCTAssertEqual(failure?.reason, .incompatible)
        XCTAssertTrue(failure?.requiresTerminalSelection == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandURL?.path ?? ""))
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path))?.isEmpty
                == true)
    }

    @MainActor
    func testWorkspaceOpenErrorRemovesCommandFile() async {
        struct OpenError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let terminal = TerminalApplication(
            bundleIdentifier: "test.terminal",
            displayName: "Test Terminal",
            applicationURL: URL(fileURLWithPath: "/Applications/Test Terminal.app"))
        var commandURL: URL?
        let failure = await TerminalLauncher.open(
            command: "exec /usr/bin/true",
            terminal: terminal,
            temporaryDirectory: temporaryDirectory,
            fileManager: .default,
            acknowledgementTimeoutNanoseconds: 0,
            openApplication: { url, _ in
                commandURL = url
                throw OpenError()
            })

        XCTAssertEqual(failure?.reason, .openFailed)
        XCTAssertTrue(failure?.message.contains("boom") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandURL?.path ?? ""))
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path))?.isEmpty
                == true)
    }
}
