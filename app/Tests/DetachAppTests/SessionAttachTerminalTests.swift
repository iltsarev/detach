import AppKit
import Darwin
import MetalKit
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
          "codex attach detach-codex-proj-abcd1234")
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
                == "codex attach detach-codex-proj-abcd1234"
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
            "codex attach detach-codex-proj-abcd1234")
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

    func testCoordinatorOwnsThePublicAttachInvocation() throws {
        let session = try XCTUnwrap(Self.session())
        let view = SessionAttachTerminalView(
            detachPath: "/tmp/detach",
            session: session,
            fontPointSize: 14,
            baseEnvironment: [
                "PATH": "/bin",
                "HOME": "/tmp",
                "TMUX": "/tmp/foreign.sock,1,0",
            ])
        let coordinator = view.makeCoordinator()
        XCTAssertEqual(coordinator.controller.invocation.executable, "/tmp/detach")
        XCTAssertEqual(
            coordinator.controller.invocation.arguments,
            ["codex", "attach", "detach-codex-proj-abcd1234"])
        XCTAssertFalse(
            coordinator.controller.invocation.environment.contains {
                $0.hasPrefix("TMUX=")
            })
    }

    func testTerminalFocusRequestIsHandledOnce() throws {
        let session = try XCTUnwrap(Self.session())
        let coordinator = SessionAttachTerminalView(
            detachPath: "/tmp/detach",
            session: session,
            fontPointSize: 14).makeCoordinator()
        let requestID = UUID()

        XCTAssertFalse(coordinator.shouldHandleFocusRequest(nil))
        XCTAssertTrue(coordinator.shouldHandleFocusRequest(requestID))
        XCTAssertFalse(coordinator.shouldHandleFocusRequest(requestID))
        XCTAssertTrue(coordinator.shouldHandleFocusRequest(UUID()))
    }

    @MainActor
    func testStoppedSessionDetailUsesTheLogFallback() throws {
        let session = try XCTUnwrap(Self.session(status: "stopped"))
        _ = SessionDetailView(
            session: session,
            store: SessionStore(cli: SilentDetachCLI()),
            detachPath: "/tmp/detach").body
    }

    @MainActor
    func testRunningSessionDetailEmbedsTheAttachClient() throws {
        let session = try XCTUnwrap(Self.session(status: "running"))
        XCTAssertTrue(SessionAttachInvocation.shouldEmbed(session, clientActive: true))
        _ = SessionDetailView(
            session: session,
            store: SessionStore(cli: SilentDetachCLI()),
            detachPath: "/tmp/detach").body
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

    func testRealtimeRendererRequiresPausedOnDemandMetal() {
        let view = MTKView(frame: .zero)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = false
        XCTAssertTrue(SessionAttachRendering.isPausedOnDemand(view))

        view.isPaused = false
        XCTAssertFalse(SessionAttachRendering.isPausedOnDemand(view))
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

    func testRealtimeRendererFailureKeepsTheFallbackAvailable() {
        enum Failure: Error { case unavailable }
        XCTAssertFalse(SessionAttachRendering.enableOnDemandMetal {
            throw Failure.unavailable
        })
        XCTAssertTrue(SessionAttachRendering.enableOnDemandMetal {})
    }

    @MainActor
    func testRealtimeRendererKeepsTheCoreGraphicsTerminalInteractive() {
        let terminal = SessionAttachLocalProcessTerminalView(frame: .zero)

        XCTAssertFalse(
            SessionAttachRendering.hasEnergyEfficientMetalRenderer(in: terminal))
        terminal.cursorStyleChanged(
            source: terminal.terminal,
            newStyle: .steadyBlock)
        XCTAssertFalse(terminal.isUsingMetalRenderer)
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
        let coordinator = SessionAttachTerminalView.Coordinator(
            controller: SessionAttachController(invocation: Self.invocation()),
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

    private static func session(status: String = "running") -> Session? {
        SessionListParser.parse("""
        {"schema":1,"provider":"codex","session_name":"detach-codex-proj-abcd1234","name":"proj-abcd1234","effective_status":"\(status)","meta_status":null,"agent_session_id":"1111-2222","project_dir":"/tmp/p","created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null}
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
