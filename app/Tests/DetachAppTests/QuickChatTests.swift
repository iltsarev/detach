import Foundation
import XCTest
@testable import DetachKit
@testable import DetachApp

@MainActor
final class QuickChatTests: XCTestCase {
    func testDefaultsMatchTheExistingSessionProviderAndTemporaryFolder() {
        XCTAssertEqual(AppSettings.defaultQuickChatProvider, Provider.claude.rawValue)
        XCTAssertEqual(AppSettings.defaultQuickChatDirectoryPath, "/tmp")
        XCTAssertEqual(
            AppSettings.defaultProjectsDirectoryPath,
            FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testDirectoryPreferenceAcceptsOnlyExistingAbsoluteDirectories() {
        XCTAssertNotNil(DirectoryPreference.existingDirectoryURL(path: "/tmp"))
        XCTAssertNil(DirectoryPreference.existingDirectoryURL(path: "relative"))
        XCTAssertNil(DirectoryPreference.existingDirectoryURL(
            path: "/tmp/detach-missing-\(UUID().uuidString)"))
        XCTAssertNil(DirectoryPreference.existingDirectoryURL(path: "/etc/hosts"))
    }

    func testDirectoryPreferenceFallsBackWhenTheSettingIsStale() {
        let fallback = URL(fileURLWithPath: "/tmp", isDirectory: true)
        XCTAssertEqual(
            DirectoryPreference.configuredOrFallback(
                path: "/tmp/detach-missing-\(UUID().uuidString)",
                fallback: fallback),
            fallback)
    }

    func testQuickChatCreatesDistinctPrivateProjectDirectories() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-quick-chat-test-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }

        let first = try QuickChatProjectDirectory.create(inside: parent)
        let second = try QuickChatProjectDirectory.create(inside: parent)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), parent.standardizedFileURL)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("detach-chat-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testQuickChatLaunchUsesTheDefaultPrivateProjectDirectory() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-quick-chat-launch-test-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let cli = QuickChatRecordingCLI()

        _ = await QuickChatLaunch.start(
            store: SessionStore(cli: cli),
            providerRawValue: Provider.codex.rawValue,
            directoryPath: parent.path)

        let project = try XCTUnwrap(cli.calls.first?.currentDirectory)
        XCTAssertEqual(project.deletingLastPathComponent(), parent.standardizedFileURL)
        XCTAssertTrue(project.lastPathComponent.hasPrefix("detach-chat-"))
    }

    func testQuickChatUsesConfiguredProviderAndWorkingDirectory() async {
        let directory = try! XCTUnwrap(
            DirectoryPreference.existingDirectoryURL(path: "/tmp"))
        let cli = QuickChatRecordingCLI()
        cli.responses["list --json"] = CLIResult(
            exitCode: 0,
            stdout: #"{"schema":1,"provider":"codex","session_name":"detach-codex-tmp-1","name":"tmp-1","effective_status":"running","meta_status":"running","agent_session_id":"u1","project_dir":"\#(directory.path)","created_at":"2026-08-31T00:00:00Z","last_checkpoint_at":null,"finished_at":null}"#,
            stderr: "",
            timedOut: false)
        let store = SessionStore(cli: cli)

        let result = await QuickChatLaunch.start(
            store: store,
            providerRawValue: Provider.codex.rawValue,
            directoryPath: "/tmp",
            createProjectDirectory: { directory, _ in directory })

        XCTAssertEqual(result.sessionID, "detach-codex-tmp-1")
        XCTAssertNil(result.message)
        XCTAssertEqual(cli.calls.map(\.arguments), [
            ["codex", "--detach"],
            ["list", "--json"],
        ])
        XCTAssertEqual(cli.calls.first?.currentDirectory?.path, directory.path)
    }

    func testRepeatedQuickChatsUseDistinctProjectDirectories() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "detach-repeated-chat-test-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstProject = try QuickChatProjectDirectory.create(inside: parent)
        let secondProject = try QuickChatProjectDirectory.create(inside: parent)
        let cli = QuickChatRecordingCLI()
        let store = SessionStore(cli: cli)

        func line(id: String, project: URL) -> String {
            #"{"schema":1,"provider":"codex","session_name":"\#(id)","name":"Quick","effective_status":"running","project_dir":"\#(project.path)"}"#
        }
        cli.responses["list --json"] = CLIResult(
            exitCode: 0,
            stdout: line(id: "detach-codex-quick-1", project: firstProject),
            stderr: "",
            timedOut: false)
        let first = await QuickChatLaunch.start(
            store: store,
            providerRawValue: Provider.codex.rawValue,
            directoryPath: parent.path,
            createProjectDirectory: { _, _ in firstProject })

        cli.responses["list --json"] = CLIResult(
            exitCode: 0,
            stdout: line(id: "detach-codex-quick-2", project: secondProject),
            stderr: "",
            timedOut: false)
        let second = await QuickChatLaunch.start(
            store: store,
            providerRawValue: Provider.codex.rawValue,
            directoryPath: parent.path,
            createProjectDirectory: { _, _ in secondProject })

        XCTAssertEqual(first.sessionID, "detach-codex-quick-1")
        XCTAssertEqual(second.sessionID, "detach-codex-quick-2")
        XCTAssertEqual(
            cli.calls.filter { $0.arguments == ["codex", "--detach"] }
                .compactMap(\.currentDirectory),
            [firstProject, secondProject])
    }

    func testQuickChatSelectsTheTypedStartingSessionBeforeLaunchFinishes() async {
        let directory = try! XCTUnwrap(
            DirectoryPreference.existingDirectoryURL(path: "/tmp"))
        let line = #"{"schema":1,"provider":"codex","session_name":"detach-codex-tmp-1","name":"tmp-1","effective_status":"starting","meta_status":"starting","agent_session_id":null,"project_dir":"\#(directory.path)","created_at":"2026-08-31T00:00:00Z","last_checkpoint_at":null,"finished_at":null}"#
        let cli = SlowQuickChatCLI(listOutput: line)
        let store = SessionStore(cli: cli)
        let selected = expectation(description: "starting session selected")
        var selectedID: String?

        let launch = Task { @MainActor in
            await QuickChatLaunch.start(
                store: store,
                providerRawValue: Provider.codex.rawValue,
                directoryPath: "/tmp",
                onSessionAvailable: { sessionID in
                    selectedID = sessionID
                    selected.fulfill()
                },
                createProjectDirectory: { directory, _ in directory })
        }

        await cli.waitUntilStartBegan()
        await store.refresh() // the production FSEvents hint requests this snapshot
        await fulfillment(of: [selected], timeout: 1)
        XCTAssertEqual(selectedID, "detach-codex-tmp-1")
        XCTAssertEqual(store.sessions.first?.effectiveStatus, .starting)

        await cli.finishStart()
        let result = await launch.value
        let listCallCount = await cli.listCallCount

        XCTAssertEqual(result.sessionID, "detach-codex-tmp-1")
        XCTAssertEqual(listCallCount, 2)
    }

    func testQuickChatReconcilesAnEarlySelectionAfterLaunchFailure() async {
        let directory = try! XCTUnwrap(
            DirectoryPreference.existingDirectoryURL(path: "/tmp"))
        let line = #"{"schema":1,"provider":"codex","session_name":"detach-codex-tmp-1","name":"tmp-1","effective_status":"starting","meta_status":"starting","agent_session_id":null,"project_dir":"\#(directory.path)","created_at":"2026-08-31T00:00:00Z","last_checkpoint_at":null,"finished_at":null}"#
        let cli = SlowQuickChatCLI(listOutput: line)
        let store = SessionStore(cli: cli)
        let selected = expectation(description: "starting session selected")

        let launch = Task { @MainActor in
            await QuickChatLaunch.start(
                store: store,
                providerRawValue: Provider.codex.rawValue,
                directoryPath: "/tmp",
                onSessionAvailable: { _ in selected.fulfill() },
                createProjectDirectory: { directory, _ in directory })
        }

        await cli.waitUntilStartBegan()
        await store.refresh() // the production FSEvents hint requests this snapshot
        await fulfillment(of: [selected], timeout: 1)
        await cli.finishStart(exitCode: 17, stderr: "start refused\n")
        let result = await launch.value
        let listCallCount = await cli.listCallCount

        XCTAssertEqual(result.message, "start refused")
        XCTAssertEqual(listCallCount, 2)
    }

    func testQuickChatRejectsAnUnavailableFolderWithoutCallingTheCLI() async {
        let cli = QuickChatRecordingCLI()
        let missing = "/tmp/detach-missing-\(UUID().uuidString)"

        let result = await QuickChatLaunch.start(
            store: SessionStore(cli: cli),
            providerRawValue: Provider.claude.rawValue,
            directoryPath: missing)

        XCTAssertEqual(
            result.message,
            L10n.format("Quick chat folder is unavailable: %@", missing))
        XCTAssertTrue(cli.calls.isEmpty)
    }

    func testQuickChatReportsProjectDirectoryCreationFailure() async {
        enum Failure: Error { case denied }
        let cli = QuickChatRecordingCLI()

        let result = await QuickChatLaunch.start(
            store: SessionStore(cli: cli),
            providerRawValue: Provider.codex.rawValue,
            directoryPath: "/tmp",
            createProjectDirectory: { _, _ in throw Failure.denied })

        XCTAssertNotNil(result.message)
        XCTAssertTrue(cli.calls.isEmpty)
    }

    func testUnknownStoredProviderFallsBackToClaude() {
        XCTAssertEqual(
            QuickChatLaunch.provider(rawValue: "removed-provider"),
            .claude)
    }

    func testQuickChatSnapshotsEveryExistingSessionID() throws {
        let sessions = SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"existing-codex","name":"Codex","effective_status":"running"}
        {"schema":1,"provider":"claude","session_name":"existing-claude","name":"Claude","effective_status":"stopped"}
        """).sessions

        XCTAssertEqual(
            QuickChatLaunch.existingSessionIDs(in: sessions),
            ["existing-codex", "existing-claude"])
    }

    func testNavigationCreatesDistinctQuickChatRequests() {
        let navigation = MainNavigation()
        XCTAssertNil(navigation.quickChatRequestID)

        navigation.requestQuickChat()
        let first = navigation.quickChatRequestID
        navigation.requestQuickChat()

        XCTAssertNotNil(first)
        XCTAssertNotEqual(navigation.quickChatRequestID, first)
        XCTAssertFalse(navigation.requestsNewSession)
        navigation.requestNewSession()
        XCTAssertTrue(navigation.requestsNewSession)
        navigation.requestSession("detach-codex-project-12345678")
        XCTAssertEqual(
            navigation.requestedSessionID,
            "detach-codex-project-12345678")
    }

    func testSidebarGuideListsImplementedAndStandardShortcuts() {
        XCTAssertEqual(
            SidebarShortcutPresentation.hints.map(\.shortcut),
            ["⌘N", "⌘T", "⌘,", "⌘F"])
        XCTAssertEqual(
            SidebarShortcutPresentation.hints.map(\.title),
            [
                L10n.string("New session"),
                L10n.string("Quick chat"),
                L10n.string("Settings"),
                L10n.string("Find output"),
            ])
        XCTAssertEqual(
            SidebarShortcutPresentation.hints.map(\.id),
            ["⌘N", "⌘T", "⌘,", "⌘F"])
    }

    func testSessionCommandsBuildWithTheSharedNavigation() {
        let commands = SessionCommands(
            navigation: MainNavigation(),
            store: SessionStore(cli: QuickChatRecordingCLI()),
            shortcuts: SessionShortcutRegistry())
        _ = commands.body
    }
}

private actor SlowQuickChatCLI: DetachCLIRunning {
    private let listOutput: String
    private var startContinuation: CheckedContinuation<CLIResult, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startBegan = false
    private(set) var listCallCount = 0

    init(listOutput: String) {
        self.listOutput = listOutput
    }

    func run(
        arguments: [String], timeout: TimeInterval
    ) async throws -> CLIResult {
        if arguments == ["list", "--json"] {
            listCallCount += 1
            return CLIResult(
                exitCode: 0,
                stdout: listOutput,
                stderr: "",
                timedOut: false)
        }

        startBegan = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitUntilStartBegan() async {
        if startBegan { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishStart(exitCode: Int32 = 0, stderr: String = "") {
        startContinuation?.resume(returning: CLIResult(
            exitCode: exitCode,
            stdout: exitCode == 0
                ? "Started detach-codex-tmp-1 in /tmp\n" : "",
            stderr: stderr,
            timedOut: false))
        startContinuation = nil
    }
}

private final class QuickChatRecordingCLI: DetachCLIRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
        let currentDirectory: URL?
    }

    var responses: [String: CLIResult] = [:]
    private(set) var calls: [Call] = []

    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        calls.append(Call(arguments: arguments, currentDirectory: nil))
        return response(for: arguments)
    }

    func run(
        arguments: [String],
        timeout: TimeInterval,
        currentDirectoryURL: URL?
    ) async throws -> CLIResult {
        calls.append(Call(
            arguments: arguments,
            currentDirectory: currentDirectoryURL))
        return response(for: arguments)
    }

    private func response(for arguments: [String]) -> CLIResult {
        responses[arguments.joined(separator: " ")]
            ?? CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}
