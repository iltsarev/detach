import AppKit
import Darwin
import SwiftUI
import XCTest
import SwiftTerm
import DetachKit
@testable import DetachApp

private final class SilentDetachCLI: DetachCLIRunning, @unchecked Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

private actor TerminalScreenPrefetchCLI: DetachCLIRunning {
    private(set) var calls: [[String]] = []
    private var activeCalls = 0
    private var peakActiveCalls = 0

    func run(arguments: [String], timeout: TimeInterval) async throws
        -> CLIResult
    {
        calls.append(arguments)
        activeCalls += 1
        peakActiveCalls = max(peakActiveCalls, activeCalls)
        defer { activeCalls -= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        return CLIResult(
            exitCode: 0,
            stdout: "\u{001B}[32mprefetched screen\u{001B}[0m\n",
            stderr: "",
            timedOut: false)
    }

    func recordedCalls() -> [[String]] { calls }
    func peakConcurrency() -> Int { peakActiveCalls }
}

private actor BlankTerminalScreenCLI: DetachCLIRunning {
    private(set) var calls: [[String]] = []

    func run(arguments: [String], timeout: TimeInterval) async throws
        -> CLIResult
    {
        calls.append(arguments)
        return CLIResult(exitCode: 0, stdout: "\n   \n", stderr: "", timedOut: false)
    }

    func recordedCalls() -> [[String]] { calls }
}

private actor SuspendedTerminalScreenCLI: DetachCLIRunning {
    private var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func run(arguments: [String], timeout: TimeInterval) async throws
        -> CLIResult
    {
        calls += 1
        await withCheckedContinuation { continuations.append($0) }
        return CLIResult(
            exitCode: 0,
            stdout: "retained screen",
            stderr: "",
            timedOut: false)
    }

    func callCount() -> Int { calls }

    func releaseAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

private actor RecordingSessionSwitchCLI: DetachCLIRunning {
    private var calls: [[String]] = []

    func run(arguments: [String], timeout: TimeInterval) async throws
        -> CLIResult
    {
        calls.append(arguments)
        return CLIResult(
            exitCode: 0,
            stdout: "",
            stderr: "",
            timedOut: false)
    }

    func recordedCalls() -> [[String]] { calls }
}

private final class RecordingTerminalView: LocalProcessTerminalView {
    enum Action: Equatable {
        case copy
        case paste
        case find(Int)
    }

    private(set) var actions: [Action] = []

    override func copy(_ sender: Any) {
        actions.append(.copy)
    }

    override func paste(_ sender: Any) {
        actions.append(.paste)
    }

    override func performFindPanelAction(_ sender: Any?) {
        actions.append(.find((sender as? NSMenuItem)?.tag ?? -1))
    }
}

final class SessionAttachTerminalTests: XCTestCase {
    func testPublicAttachRoundTripResizeCopyAndTermination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = root.appendingPathComponent("args")
        let detach = root.appendingPathComponent("detach")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" > '\(record.path)'
        case "$*" in
          "codex attach --terminal-features sync detach-codex-proj-abcd1234")
            exec /bin/cat
            ;;
        esac
        exit 2
        """.write(to: detach, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: detach.path)

        let session = try XCTUnwrap(Self.session())
        let invocation = SessionAttachInvocation(
            detachPath: detach.path,
            session: session,
            baseEnvironment: [
                "PATH": "/bin:/usr/bin",
                "HOME": root.path,
                "TMUX": "/tmp/foreign.sock,1,0",
                "TMUX_PANE": "%1",
            ])

        var exitCode: Int32?
        let terminal = HeadlessTerminal { exitCode = $0 }
        terminal.process.startProcess(
            executable: invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment,
            currentDirectory: root.path)

        try waitUntil {
            (try? String(contentsOf: record, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "codex attach --terminal-features sync detach-codex-proj-abcd1234"
        }
        XCTAssertGreaterThan(terminal.process.shellPid, 0)
        XCTAssertTrue(terminal.process.running)

        terminal.send("round-trip\n")
        try waitUntil {
            bufferText(terminal).contains("round-trip")
        }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let copied = SessionAttachClipboard.write(bufferText(terminal), to: pasteboard)
        XCTAssertTrue(copied.contains("round-trip"), copied)
        XCTAssertEqual(pasteboard.string(forType: .string), copied)

        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(terminal.process.childfd, TIOCSWINSZ, &size), 0)
        var current = winsize()
        XCTAssertEqual(ioctl(terminal.process.childfd, TIOCGWINSZ, &current), 0)
        XCTAssertEqual(current.ws_col, 120)
        XCTAssertEqual(current.ws_row, 40)

        let childPID = terminal.process.shellPid
        SessionAttachController.terminate(process: terminal.process)
        try waitUntil { exitCode != nil || !terminal.process.running }
        try waitUntil {
            errno = 0
            return Darwin.kill(childPID, 0) == -1 && errno == ESRCH
        }

        XCTAssertFalse(terminal.process.running)
        XCTAssertEqual(
            try String(contentsOf: record, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "codex attach --terminal-features sync detach-codex-proj-abcd1234")
    }

    func testTerminationEscalatesWhenTheClientIgnoresTerm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-attach-kill-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ready = root.appendingPathComponent("ready")
        let terminal = HeadlessTerminal { _ in }
        terminal.process.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "trap '' TERM; : > '\(ready.path)'; exec /bin/sleep 5",
            ],
            environment: ["PATH=/bin:/usr/bin"],
            currentDirectory: root.path)

        try waitUntil {
            FileManager.default.fileExists(atPath: ready.path)
                && terminal.process.running
        }
        let childPID = terminal.process.shellPid
        XCTAssertGreaterThan(childPID, 0)

        SessionAttachController.terminate(
            process: terminal.process,
            timeout: 0.02)

        try waitUntil {
            errno = 0
            return Darwin.kill(childPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertFalse(terminal.process.running)
    }

    func testIdleControllerDoesNotTouchATerminalView() {
        let controller = SessionAttachController(invocation: Self.invocation())
        controller.applyFont(pointSize: 12)
        controller.start()
        controller.terminateClient()
        controller.send("noop")
        controller.selectAllText()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(controller.copySelection(to: pasteboard), "")
        XCTAssertNil(controller.terminalView)
        XCTAssertNil(controller.lastSize)
        XCTAssertNil(controller.exitCode)
        controller.recordSize(cols: 80, rows: 24)
        XCTAssertEqual(controller.lastSize?.cols, 80)
        XCTAssertEqual(controller.lastSize?.rows, 24)
    }

    func testProcessExitDeliversOnTheMainQueue() {
        let controller = SessionAttachController(invocation: Self.invocation())
        let onMain = expectation(description: "main-thread exit")
        var seen: Int32?
        controller.onTerminated = { code in
            XCTAssertTrue(Thread.isMainThread)
            seen = code
            onMain.fulfill()
        }
        controller.handleProcessExit(0)
        wait(for: [onMain], timeout: 1)
        XCTAssertEqual(controller.exitCode, 0)
        XCTAssertEqual(seen, 0)

        let offMain = expectation(description: "off-main exit")
        controller.onTerminated = { code in
            XCTAssertTrue(Thread.isMainThread)
            seen = code
            offMain.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            controller.handleProcessExit(9)
        }
        wait(for: [offMain], timeout: 1)
        XCTAssertEqual(controller.exitCode, 9)
        XCTAssertEqual(seen, 9)
    }

    @MainActor
    func testCoordinatorOwnsThePublicAttachInvocation() throws {
        let session = try XCTUnwrap(Self.session())
        let view = SessionAttachTerminalView(
            detachPath: "/tmp/detach",
            session: session,
            fontPointSize: 14,
            screenCache: SessionTerminalScreenCache(),
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/tmp",
                "TMUX": "/tmp/foreign.sock,1,0",
            ])
        let coordinator = view.makeCoordinator()
        XCTAssertEqual(coordinator.controller.invocation.executable, "/tmp/detach")
        XCTAssertEqual(
            coordinator.controller.invocation.arguments,
            [
                "codex", "attach", "--terminal-features", "sync",
                "detach-codex-proj-abcd1234",
            ])
        XCTAssertFalse(
            coordinator.controller.invocation.environment.contains {
                $0.hasPrefix("TMUX=")
            })
    }

    @MainActor
    func testLiveSessionSwitchKeepsTheExistingPTYAndUsesExactClientPID() async throws {
        let source = try XCTUnwrap(Self.session(
            name: "detach-codex-source"))
        let target = try XCTUnwrap(Self.session(
            name: "detach-codex-target"))
        var invocation = Self.invocation()
        invocation.executable = "/bin/sleep"
        invocation.arguments = ["5"]
        invocation.environment = ["PATH=/bin:/usr/bin"]
        let controller = SessionAttachController(invocation: invocation)
        let terminal = LocalProcessTerminalView(frame: NSRect(
            x: 0, y: 0, width: 320, height: 180))
        controller.configure(terminal, fontPointSize: 14)
        controller.start()
        let clientPID = terminal.process.shellPid
        XCTAssertGreaterThan(clientPID, 1)
        let cli = RecordingSessionSwitchCLI()
        let coordinator = SessionAttachTerminalView.Coordinator(
            controller: controller,
            session: source,
            screenCache: SessionTerminalScreenCache(),
            onTerminated: { _ in },
            switchCLI: cli)

        coordinator.requestSession(target, in: terminal)
        await waitUntilAsync {
            await cli.recordedCalls().count == 1
                && coordinator.session.id == target.id
        }

        XCTAssertTrue(terminal.process.running)
        XCTAssertEqual(terminal.process.shellPid, clientPID)
        let calls = await cli.recordedCalls()
        XCTAssertEqual(
            calls,
            [SessionClientSwitchInvocation.arguments(
                clientPID: clientPID,
                from: source,
                to: target)])
        coordinator.cancelSwitch()
        controller.terminateClient()
    }

    @MainActor
    func testStoppedSessionDetailUsesTheLogFallback() throws {
        let session = try XCTUnwrap(Self.session(status: "stopped"))
        let cache = SessionLogSnapshotCache(
            cli: SilentDetachCLI(), configurationID: "/tmp/detach")
        _ = SessionDetailView(
            session: session,
            store: SessionStore(cli: SilentDetachCLI()),
            detachPath: "/tmp/detach",
            terminalScreens: SessionTerminalScreenCache(),
            cachedLog: cache.poller(for: session)).body
    }

    func testDetachedLiveLogRefreshKeysOnSessionAndCacheIdentity() throws {
        let live = try XCTUnwrap(Self.session(status: "running"))
        let finished = try XCTUnwrap(Self.session(status: "stopped"))
        let firstPoller = NSObject()
        let secondPoller = NSObject()
        let first = ObjectIdentifier(firstPoller)
        let second = ObjectIdentifier(secondPoller)

        // A detached live surface keeps one bounded refresh task for the
        // selection; unrelated snapshots must not restart it.
        XCTAssertEqual(
            SessionDetailLogRefresh.taskID(
                session: live,
                showsEmbeddedTerminal: false,
                cachedLogIdentity: nil),
            SessionDetailLogRefresh.taskID(
                session: live,
                showsEmbeddedTerminal: false,
                cachedLogIdentity: nil))
        XCTAssertEqual(
            SessionDetailLogRefresh.taskID(
                session: live,
                showsEmbeddedTerminal: true,
                cachedLogIdentity: nil),
            SessionDetailLogRefresh.taskID(
                session: live,
                showsEmbeddedTerminal: true,
                cachedLogIdentity: nil))
        // A replaced cache entry for a finished session must reload it.
        XCTAssertNotEqual(
            SessionDetailLogRefresh.taskID(
                session: finished,
                showsEmbeddedTerminal: false,
                cachedLogIdentity: first),
            SessionDetailLogRefresh.taskID(
                session: finished,
                showsEmbeddedTerminal: false,
                cachedLogIdentity: second))
        XCTAssertEqual(
            SessionDetailLogRefresh.taskID(
                session: finished,
                showsEmbeddedTerminal: false,
                cachedLogIdentity: first),
            SessionDetailLogRefresh.taskID(
                session: finished,
                showsEmbeddedTerminal: false,
                cachedLogIdentity: first))
    }

    func testDetailTransitionKeepsOutgoingFrameUntilTargetIsReady() throws {
        let first = try XCTUnwrap(Self.session(name: "detach-codex-first"))
        let second = try XCTUnwrap(Self.session(name: "detach-codex-second"))
        var transition = SessionDetailTransitionState(presented: first)

        let generation = try XCTUnwrap(transition.present(second))

        XCTAssertEqual(transition.presented.id, second.id)
        XCTAssertEqual(transition.outgoing?.id, first.id)
        XCTAssertFalse(transition.complete(
            sessionID: first.id,
            generation: generation))
        XCTAssertTrue(transition.complete(
            sessionID: second.id,
            generation: generation))
        XCTAssertNil(transition.outgoing)
    }

    func testRapidDetailTransitionKeepsLastCompositedFrameAndRejectsLateReady() throws {
        let first = try XCTUnwrap(Self.session(name: "detach-codex-first"))
        let second = try XCTUnwrap(Self.session(name: "detach-codex-second"))
        let third = try XCTUnwrap(Self.session(name: "detach-codex-third"))
        var transition = SessionDetailTransitionState(presented: first)

        let secondGeneration = try XCTUnwrap(transition.present(second))
        let thirdGeneration = try XCTUnwrap(transition.present(third))

        XCTAssertEqual(transition.presented.id, third.id)
        XCTAssertEqual(transition.outgoing?.id, first.id)
        XCTAssertFalse(transition.complete(
            sessionID: second.id,
            generation: secondGeneration))
        XCTAssertEqual(transition.outgoing?.id, first.id)
        XCTAssertTrue(transition.complete(
            sessionID: third.id,
            generation: thirdGeneration))
        XCTAssertNil(transition.outgoing)
    }

    func testDetailRevisionUpdatesWithoutStartingAVisualTransition() throws {
        let first = try XCTUnwrap(Self.session(name: "detach-codex-same"))
        var updated = first
        updated.displayName = "Updated title"
        var transition = SessionDetailTransitionState(presented: first)

        XCTAssertNil(transition.present(updated))

        XCTAssertEqual(transition.presented.displayName, "Updated title")
        XCTAssertNil(transition.outgoing)
        XCTAssertEqual(transition.generation, 0)
    }

    @MainActor
    func testRunningSessionDetailEmbedsTheAttachClient() throws {
        let session = try XCTUnwrap(Self.session(status: "running"))
        XCTAssertTrue(SessionAttachInvocation.shouldEmbed(session, clientActive: true))
        _ = SessionDetailView(
            session: session,
            store: SessionStore(cli: SilentDetachCLI()),
            detachPath: "/tmp/detach",
            terminalScreens: SessionTerminalScreenCache(),
                cachedLog: nil).body
    }

    @MainActor
    func testTerminalScreenCacheBoundsAndRestoresRecentText() throws {
        let cache = SessionTerminalScreenCache()
        for index in 0...SessionTerminalScreenCache.capacity {
            let session = try XCTUnwrap(Self.session(
                name: "detach-codex-project-\(index)"))
            cache.store(
                Data("screen \(index)\nnext".utf8),
                for: session)
        }

        XCTAssertNil(cache.screen(for: try XCTUnwrap(Self.session(
            name: "detach-codex-project-0"))))
        XCTAssertEqual(
            cache.screen(for: try XCTUnwrap(Self.session(
                name: "detach-codex-project-9"))),
            Data("screen 9\r\nnext".utf8))
    }

    @MainActor
    func testTerminalScreenCacheKeepsOnlyTheVisibleTail() {
        let source = (0...SessionTerminalScreenCache.lineLimit)
            .map(String.init)
            .joined(separator: "\n")
        let normalized = SessionTerminalScreenCache.normalized(Data(source.utf8))
        let text = normalized.flatMap { String(data: $0, encoding: .utf8) }

        XCTAssertNotNil(text)
        XCTAssertFalse(text?.hasPrefix("0\r\n") == true)
        XCTAssertTrue(text?.hasPrefix("1\r\n") == true)
        XCTAssertTrue(text?.hasSuffix(String(SessionTerminalScreenCache.lineLimit)) == true)
        XCTAssertNil(SessionTerminalScreenCache.normalized(Data("\n  \n".utf8)))
    }

    @MainActor
    func testCoordinatorCapturesTerminalTextBeforeDismantle() throws {
        let session = try XCTUnwrap(Self.session())
        let cache = SessionTerminalScreenCache()
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.feed(text: "visible screen")
        let coordinator = SessionAttachTerminalView.Coordinator(
            controller: SessionAttachController(invocation: Self.invocation()),
            session: session,
            screenCache: cache,
            onTerminated: { _ in })

        coordinator.captureScreen(from: terminal)

        let screen = try XCTUnwrap(cache.screen(for: session))
        XCTAssertTrue(String(decoding: screen, as: UTF8.self)
            .contains("visible screen"))
    }

    @MainActor
    func testFirstVisibleFrameIsCapturedBeforeReadinessIsReported() throws {
        let session = try XCTUnwrap(Self.session())
        let cache = SessionTerminalScreenCache()
        let terminal = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        terminal.feed(text: "first visible frame")
        var reportedScreen: Data?
        let coordinator = SessionAttachTerminalView.Coordinator(
            controller: SessionAttachController(invocation: Self.invocation()),
            session: session,
            screenCache: cache,
            onTerminated: { _ in },
            onFirstVisibleFrame: {
                reportedScreen = cache.screen(for: session)
            })

        coordinator.reportFirstVisibleFrame(from: terminal)

        let screen = try XCTUnwrap(reportedScreen)
        XCTAssertTrue(String(decoding: screen, as: UTF8.self)
            .contains("first visible frame"))
    }

    @MainActor
    func testTerminalScreenPrefetchWarmsOnlyLiveAttachableSessions() async throws {
        let live = try XCTUnwrap(Self.session(
            status: "running", name: "detach-codex-live"))
        let stopped = try XCTUnwrap(Self.session(
            status: "stopped", name: "detach-codex-stopped"))
        let cli = TerminalScreenPrefetchCLI()
        let cache = SessionTerminalScreenCache()
        cache.configure(cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch([live, stopped])
        await cache.prefetch([live, stopped])

        let screen = try XCTUnwrap(cache.screen(for: live))
        XCTAssertTrue(String(decoding: screen, as: UTF8.self)
            .contains("prefetched screen"))
        XCTAssertNil(cache.screen(for: stopped))
        let calls = await cli.recordedCalls()
        XCTAssertEqual(calls, [[
            "codex", "logs", "--ansi", "detach-codex-live",
        ]])
    }

    @MainActor
    func testConfigureWarmsLiveSessionsAlreadyPresentAtStartup() async throws {
        let live = try XCTUnwrap(Self.session(
            status: "running", name: "detach-codex-startup-live"))
        let cli = TerminalScreenPrefetchCLI()
        let cache = SessionTerminalScreenCache()

        cache.schedulePrefetch(for: [live])
        for _ in 0..<20 { await Task.yield() }
        let callsBeforeConfiguration = await cli.recordedCalls()
        XCTAssertTrue(callsBeforeConfiguration.isEmpty)

        cache.configure(
            cli: cli,
            configurationID: "/tmp/detach",
            sessions: [live])
        await waitUntilAsync { cache.screen(for: live) != nil }

        XCTAssertNotNil(cache.screen(for: live))
        let callsAfterConfiguration = await cli.recordedCalls()
        XCTAssertEqual(callsAfterConfiguration, [[
            "codex", "logs", "--ansi", "detach-codex-startup-live",
        ]])
    }

    @MainActor
    func testBlankScreenIsNotRefetchedUntilTheTypedTurnChanges() async throws {
        let starting = try XCTUnwrap(Self.session(
            status: "running", name: "detach-codex-blank"))
        let cli = BlankTerminalScreenCLI()
        let cache = SessionTerminalScreenCache()
        cache.configure(cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch([starting])
        await cache.prefetch([starting])
        XCTAssertNil(cache.screen(for: starting))
        let repeatedCalls = await cli.recordedCalls()
        XCTAssertEqual(repeatedCalls.count, 1)

        var working = starting
        working.agentTurnState = .working
        working.agentTurnID = "turn-1"
        await cache.prefetch([working])
        let changedCalls = await cli.recordedCalls()
        XCTAssertEqual(changedCalls.count, 2)
    }

    @MainActor
    func testNewRunUnderTheSameNameNeverInheritsAnOldScreen() async throws {
        let first = try XCTUnwrap(Self.session(
            status: "running", name: "detach-codex-reused",
            createdAt: "2026-09-01T10:00:00Z"))
        let cli = TerminalScreenPrefetchCLI()
        let cache = SessionTerminalScreenCache()
        cache.configure(cli: cli, configurationID: "/tmp/detach")
        await cache.prefetch([first])
        XCTAssertNotNil(cache.screen(for: first))

        // The same explicit name starts a fresh run with a new creation time.
        let replacement = try XCTUnwrap(Self.session(
            status: "running", name: "detach-codex-reused",
            createdAt: "2026-09-02T10:00:00Z"))
        cache.schedulePrefetch(for: [replacement])
        XCTAssertNil(cache.screen(for: first))
        await waitUntilAsync { cache.screen(for: replacement) != nil }
        let calls = await cli.recordedCalls()
        XCTAssertEqual(calls.count, 2)
    }

    @MainActor
    func testTerminalScreenPrefetchBoundsConcurrentProcesses() async throws {
        let sessions = try (0..<SessionTerminalScreenCache.capacity).map {
            try XCTUnwrap(Self.session(
                status: "running", name: "detach-codex-live-\($0)"))
        }
        let cli = TerminalScreenPrefetchCLI()
        let cache = SessionTerminalScreenCache()
        cache.configure(cli: cli, configurationID: "/tmp/detach")

        await cache.prefetch(sessions)

        let peak = await cli.peakConcurrency()
        let calls = await cli.recordedCalls()
        XCTAssertEqual(peak, SessionTerminalScreenCache.maximumConcurrentPrefetches)
        XCTAssertEqual(calls.count, sessions.count)
        for session in sessions {
            XCTAssertNotNil(cache.screen(for: session))
        }
    }

    @MainActor
    func testCancelledScreenPrefetchCannotClearAReplacementTask() async throws {
        let session = try XCTUnwrap(Self.session(
            status: "running", name: "detach-codex-generation"))
        let oldCLI = SuspendedTerminalScreenCLI()
        let newCLI = SuspendedTerminalScreenCLI()
        let cache = SessionTerminalScreenCache()
        cache.configure(cli: oldCLI, configurationID: "old")
        cache.schedulePrefetch(for: [session])
        await waitUntilAsync { await oldCLI.callCount() == 1 }

        cache.configure(cli: newCLI, configurationID: "new")
        cache.schedulePrefetch(for: [session])
        await waitUntilAsync { await newCLI.callCount() == 1 }
        await oldCLI.releaseAll()
        for _ in 0..<20 { await Task.yield() }

        cache.schedulePrefetch(for: [session])
        for _ in 0..<20 { await Task.yield() }
        let replacementCallCount = await newCLI.callCount()
        XCTAssertEqual(replacementCallCount, 1)
        await newCLI.releaseAll()
    }

    func testTerminalFontMatchesTheAppSize() {
        XCTAssertEqual(SessionAttachController.terminalFont(pointSize: 17).pointSize, 17)
        XCTAssertTrue(SessionAttachController.terminalFont(pointSize: 14).isFixedPitch)
    }

    func testClipboardWriteCopiesUTF8Selection() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(
            SessionAttachClipboard.write("selected text", to: pasteboard),
            "selected text")
        XCTAssertEqual(pasteboard.string(forType: .string), "selected text")
    }

    func testDroppedFileURLsBecomeShellSafeAbsolutePaths() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/photo.png")
        let second = URL(fileURLWithPath: "/tmp/Project File/a'b.txt")
        XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL]))

        XCTAssertEqual(
            SessionAttachDroppedPaths.insertionText(from: pasteboard),
            "/tmp/photo.png '/tmp/Project File/a'\\''b.txt' ")
    }

    func testDroppedPathsIgnoreNonFileURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = try XCTUnwrap(URL(string: "https://example.com/file.png"))
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        XCTAssertNil(SessionAttachDroppedPaths.insertionText(from: pasteboard))
    }

    @MainActor
    func testTerminalViewAcceptsFileDropsAndTakesFocus() {
        let filePasteboard = NSPasteboard.withUniqueName()
        let emptyPasteboard = NSPasteboard.withUniqueName()
        defer {
            filePasteboard.releaseGlobally()
            emptyPasteboard.releaseGlobally()
        }
        XCTAssertTrue(filePasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/Project File/image.png") as NSURL,
        ]))

        let terminal = SessionAttachLocalProcessTerminalView(frame: .zero)
        XCTAssertTrue(terminal.registeredDraggedTypes.contains(.fileURL))
        XCTAssertEqual(terminal.acceptedDragOperation(from: filePasteboard), .copy)
        XCTAssertEqual(terminal.acceptedDragOperation(from: emptyPasteboard), [])

        var insertedText: String?
        terminal.onDroppedPaths = { insertedText = $0 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: false)
        window.contentView = terminal

        XCTAssertFalse(terminal.acceptDroppedPaths(from: emptyPasteboard))
        XCTAssertTrue(terminal.acceptDroppedPaths(from: filePasteboard))
        XCTAssertEqual(insertedText, "'/tmp/Project File/image.png' ")
        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testRealtimeRendererUsesSteadyCursorVariants() {
        let mappings: [(CursorStyle, String)] = [
            (.blinkBlock, CursorStyle.steadyBlock.tagName),
            (.steadyBlock, CursorStyle.steadyBlock.tagName),
            (.blinkUnderline, CursorStyle.steadyUnderline.tagName),
            (.steadyUnderline, CursorStyle.steadyUnderline.tagName),
            (.blinkBar, CursorStyle.steadyBar.tagName),
            (.steadyBar, CursorStyle.steadyBar.tagName),
        ]
        for (input, expected) in mappings {
            XCTAssertEqual(
                SessionAttachRendering.steadyCursorStyle(for: input).tagName,
                expected)
        }
    }

    @MainActor
    func testRealtimeRendererUsesEventDrivenCoreGraphics() {
        let terminal = SessionAttachLocalProcessTerminalView(frame: .zero)

        terminal.configureRealtimeRendererIfNeeded()
        terminal.cursorStyleChanged(
            source: terminal.terminal,
            newStyle: .blinkUnderline)

        XCTAssertFalse(terminal.isUsingMetalRenderer)
        XCTAssertEqual(
            terminal.terminal.options.cursorStyle.tagName,
            CursorStyle.steadyUnderline.tagName)
        XCTAssertTrue(
            SessionAttachRendering.hasEnergyEfficientRenderer(in: terminal))
    }

    @MainActor
    func testRetainedScreenSurvivesAttachClearUntilAFrameIsReady() throws {
        let terminal = SessionAttachLocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let retained = Data("retained session output".utf8)
        terminal.feed(byteArray: Array(retained)[...])
        terminal.retainScreen(
            retained,
            fontPointSize: 13)
        var visibleFrameCount = 0
        terminal.onFirstVisibleFrame = { visibleFrameCount += 1 }

        XCTAssertTrue(terminal.isRetainingScreen)
        terminal.dataReceived(slice: Array("\u{001B}[2J\u{001B}[H".utf8)[...])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))

        XCTAssertFalse(
            SessionAttachLocalProcessTerminalView.hasVisibleContent(
                in: terminal.terminal))
        XCTAssertTrue(terminal.isRetainingScreen)
        XCTAssertEqual(visibleFrameCount, 0)

        terminal.dataReceived(slice: Array("attached session output".utf8)[...])
        try waitUntil(timeout: 0.5) { !terminal.isRetainingScreen }
        XCTAssertTrue(
            SessionAttachLocalProcessTerminalView.hasVisibleContent(
                in: terminal.terminal))
        XCTAssertEqual(visibleFrameCount, 1)

        terminal.dataReceived(slice: Array("more output".utf8)[...])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        XCTAssertEqual(visibleFrameCount, 1)
    }

    func testDroppedPathNeverInsertsAControlCharacter() {
        XCTAssertEqual(
            SessionAttachDroppedPaths.shellEscaped("/tmp/line\nbreak.txt"),
            "$'/tmp/line\\nbreak.txt'")
        XCTAssertEqual(
            SessionAttachDroppedPaths.shellEscaped(
                "/tmp/a'\\\r\t\u{01}\u{200E}\u{E0001}b"),
            "$'/tmp/a" + "\\'" + "\\\\" + "\\r" + "\\t"
                + "\\x01\\u200E\\U000E0001b'")
    }

    @MainActor
    func testControlVReachesTheProviderAsTheRawClipboardImageShortcut() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "detach-attach-control-v-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ready = root.appendingPathComponent("ready")
        let received = root.appendingPathComponent("received")
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "stty raw -echo; : > '\(ready.path)'; "
                    + "dd bs=1 count=1 of='\(received.path)' 2>/dev/null",
            ],
            environment: ["PATH=/bin:/usr/bin"])
        defer { SessionAttachController.terminate(process: terminal.process) }

        try waitUntil {
            FileManager.default.fileExists(atPath: ready.path)
                && terminal.process.running
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))

        XCTAssertTrue(SessionAttachKeyboard.routeProviderShortcut(
            from: event,
            send: terminal.send))

        try waitUntil {
            (try? Data(contentsOf: received).count) == 1
        }
        XCTAssertEqual(try Data(contentsOf: received), Data([0x16]))
    }

    func testProviderClipboardShortcutRequiresUnmodifiedControlV() throws {
        let controlV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "м",
            isARepeat: false,
            keyCode: 9))
        let commandV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))

        XCTAssertEqual(
            SessionAttachKeyboard.providerInput(for: controlV),
            [0x16])
        XCTAssertNil(SessionAttachKeyboard.providerInput(for: commandV))
    }

    func testNativeTerminalCommandsUsePhysicalCommandKeys() throws {
        let expected: [(UInt16, String, SessionAttachKeyboard.AppAction)] = [
            (8, "с", .copy),
            (9, "м", .paste),
            (3, "а", .find),
        ]
        for (keyCode, characters, action) in expected {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .capsLock],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode))
            XCTAssertEqual(SessionAttachKeyboard.appAction(for: event), action)
        }

        let unrelatedCommand = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0))
        XCTAssertNil(SessionAttachKeyboard.appAction(for: unrelatedCommand))

        let shiftedPaste = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "V",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))
        XCTAssertNil(SessionAttachKeyboard.appAction(for: shiftedPaste))
    }

    @MainActor
    func testNativeTerminalActionsCallSwiftTermCommands() {
        let terminal = RecordingTerminalView(frame: .zero)
        SessionAttachTerminalView.Coordinator.perform(.copy, in: terminal)
        SessionAttachTerminalView.Coordinator.perform(.paste, in: terminal)
        SessionAttachTerminalView.Coordinator.perform(.find, in: terminal)

        XCTAssertEqual(terminal.actions, [
            .copy,
            .paste,
            .find(Int(NSFindPanelAction.showFindPanel.rawValue)),
        ])
    }

    @MainActor
    func testScopedKeyboardRouting() throws {
        let terminal = LocalProcessTerminalView(frame: .zero)
        let session = try XCTUnwrap(Self.session())
        let coordinator = SessionAttachTerminalView.Coordinator(
            controller: SessionAttachController(invocation: Self.invocation()),
            session: session,
            screenCache: SessionTerminalScreenCache(),
            onTerminated: { _ in })

        let controlV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{16}",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))
        var received: [UInt8] = []

        XCTAssertNil(coordinator.routeKeyboardEvent(
            controlV,
            window: nil,
            firstResponder: terminal,
            in: terminal,
            send: { received = $0 }))
        XCTAssertEqual(received, [0x16])

        let commandPaste = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9))
        var action: SessionAttachKeyboard.AppAction?
        XCTAssertNil(coordinator.routeKeyboardEvent(
            commandPaste,
            window: nil,
            firstResponder: terminal,
            in: terminal,
            send: { _ in },
            performAppAction: { action = $0 }))
        XCTAssertEqual(action, .paste)

        XCTAssertTrue(coordinator.routeKeyboardEvent(
            controlV,
            window: nil,
            firstResponder: nil,
            in: terminal,
            send: { _ in }) === controlV)
    }

    private func bufferText(_ terminal: HeadlessTerminal) -> String {
        String(data: terminal.terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        struct Timeout: Error {}
        throw Timeout()
    }

    @MainActor
    private func waitUntilAsync(
        attempts: Int = 200,
        _ predicate: @escaping () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("asynchronous condition did not become true")
    }

    private static func session(
        status: String = "running",
        name: String = "detach-codex-proj-abcd1234",
        createdAt: String? = nil
    ) -> Session? {
        let created = createdAt.map { "\"\($0)\"" } ?? "null"
        return SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"\(name)","name":"proj-abcd1234","effective_status":"\(status)","meta_status":null,"agent_session_id":"1111-2222","project_dir":"/tmp/p","created_at":\(created),"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """).sessions.first
    }

    private static func invocation() -> SessionAttachInvocation {
        SessionAttachInvocation(
            detachPath: "/tmp/detach",
            session: session()!,
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/tmp",
            ])
    }
}
