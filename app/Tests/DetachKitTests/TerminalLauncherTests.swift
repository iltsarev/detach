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
            try XCTUnwrap(contents.range(of: "/bin/rm -f -- \"$command_file\" || exit 125")?.lowerBound),
            try XCTUnwrap(contents.range(of: "exec /bin/zsh -lic")?.lowerBound))
        XCTAssertTrue(contents.contains("[[ ! -e \"$command_file\" ]] || exit 125"))
        XCTAssertTrue(contents.contains("/bin/rmdir -- \"$command_dir\""))
        XCTAssertTrue(contents.contains("exec /bin/zsh -lic \(shellQuoted(command))"))
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
