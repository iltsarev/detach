import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import DetachKit

/// A bounded, passive cache of the last rendered text for live terminals.
/// It keeps switching immediate without retaining hidden PTYs or renderers.
@MainActor
final class SessionTerminalScreenCache {
    nonisolated static let capacity = 9
    nonisolated static let lineLimit = 500
    nonisolated static let maximumConcurrentPrefetches = 3

    private struct Key: Hashable {
        let provider: Provider
        let sessionName: String
    }

    private var screens: [Key: Data] = [:]
    private var recency: [Key] = []
    private var cli: (any DetachCLIRunning)?
    private var configurationID = ""
    private var pendingPrefetch: [Session] = []
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration: UInt64 = 0

    func configure(
        cli: any DetachCLIRunning,
        configurationID: String,
        sessions: [Session] = []
    ) {
        guard configurationID != self.configurationID else {
            schedulePrefetch(for: sessions)
            return
        }
        prefetchGeneration &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        pendingPrefetch = []
        screens = [:]
        recency = []
        self.cli = cli
        self.configurationID = configurationID
        // A presentation snapshot can populate the store before RootView's
        // task configures this cache. Warm that existing list here because a
        // byte-identical fresh snapshot intentionally emits no later change.
        schedulePrefetch(for: sessions)
    }

    /// Warms recent live screens once from retained output. The work is a
    /// bounded event-triggered burst; it keeps no process after completion.
    func schedulePrefetch(for sessions: [Session]) {
        let targets = prefetchTargets(in: sessions, limit: Self.capacity)
            .filter { screens[key(for: $0)] == nil }
        guard !targets.isEmpty else { return }
        pendingPrefetch = targets
        guard prefetchTask == nil else { return }
        let generation = prefetchGeneration
        prefetchTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.drainPendingPrefetch(generation: generation)
        }
    }

    /// Deterministic entry point for focused tests.
    func prefetch(_ sessions: [Session], limit: Int = capacity) async {
        guard let cli else { return }
        let targets = prefetchTargets(in: sessions, limit: limit).filter {
            screens[key(for: $0)] == nil
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (Session, Data?).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < targets.count else { return }
                let session = targets[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return (session, nil) }
                    do {
                        let result = try await cli.run(
                            arguments: [
                                session.provider.rawValue,
                                "logs",
                                "--ansi",
                                session.sessionName,
                            ],
                            timeout: 5)
                        guard result.exitCode == 0, !result.timedOut else {
                            return (session, nil)
                        }
                        return (session, Data(result.stdout.utf8))
                    } catch {
                        return (session, nil)
                    }
                }
            }
            for _ in 0..<min(
                Self.maximumConcurrentPrefetches, targets.count) {
                enqueueNext()
            }
            while let (session, data) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let data { store(data, for: session) }
                enqueueNext()
            }
        }
    }

    func screen(for session: Session) -> Data? {
        let key = Key(provider: session.provider, sessionName: session.sessionName)
        guard let screen = screens[key] else { return nil }
        touch(key)
        return screen
    }

    func store(_ rawScreen: Data, for session: Session) {
        let key = Key(provider: session.provider, sessionName: session.sessionName)
        guard let screen = Self.normalized(rawScreen) else {
            screens.removeValue(forKey: key)
            recency.removeAll { $0 == key }
            return
        }
        screens[key] = screen
        touch(key)
        trimToCapacity()
    }

    private func trimToCapacity() {
        while recency.count > Self.capacity {
            let removed = recency.removeFirst()
            screens.removeValue(forKey: removed)
        }
    }

    static func normalized(_ rawScreen: Data) -> Data? {
        guard let text = String(data: rawScreen, encoding: .utf8) else {
            return nil
        }
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(Self.lineLimit)
        let visible = tail.joined(separator: "\r\n")
        guard visible.contains(where: { !$0.isWhitespace }) else { return nil }
        return Data(visible.utf8)
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func key(for session: Session) -> Key {
        Key(provider: session.provider, sessionName: session.sessionName)
    }

    private func prefetchTargets(
        in sessions: [Session],
        limit: Int
    ) -> [Session] {
        guard limit > 0 else { return [] }
        return Array(sessions.lazy
            .filter { SessionAttachInvocation.isEligible($0) }
            .prefix(limit))
    }

    private func drainPendingPrefetch(generation: UInt64) async {
        while generation == prefetchGeneration,
              !pendingPrefetch.isEmpty,
              !Task.isCancelled {
            let targets = pendingPrefetch
            pendingPrefetch = []
            await prefetch(targets)
        }
        if generation == prefetchGeneration { prefetchTask = nil }
    }
}

final class SessionAttachLocalProcessTerminalView: LocalProcessTerminalView {
    var onDroppedPaths: ((String) -> Void)?
    var onFirstVisibleFrame: (() -> Void)?
    private var didConfigureEventDrivenRenderer = false
    private var retainedScreenView: NSView?
    private var frameReadinessCheck: DispatchWorkItem?
    private var didReportFirstVisibleFrame = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        configureRealtimeRendererIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Keeps the previous rendered screen above the new PTY until the attach
    /// client has produced a non-empty frame. tmux clears the terminal during
    /// attach, so feeding cached bytes into the terminal alone can still show
    /// a black frame between the clear and the first repaint.
    func retainScreen(
        _ screen: Data,
        fontPointSize: CGFloat
    ) {
        removeRetainedScreen()
        let overlay = RetainedTerminalScreenView(
            frame: bounds,
            screen: screen,
            fontPointSize: fontPointSize)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .above, relativeTo: nil)
        retainedScreenView = overlay
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        guard !didReportFirstVisibleFrame,
              frameReadinessCheck == nil else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.frameReadinessCheck = nil
            guard Self.hasVisibleContent(in: self.terminal) else { return }
            self.didReportFirstVisibleFrame = true
            self.removeRetainedScreen()
            self.onFirstVisibleFrame?()
        }
        frameReadinessCheck = check
        // Let all chunks already queued by LocalProcess reach SwiftTerm and
        // give CoreGraphics two display frames before exposing the new view.
        // Do not postpone this check for a continuously streaming session.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(80),
            execute: check)
    }

    func removeRetainedScreen() {
        retainedScreenView?.removeFromSuperview()
        retainedScreenView = nil
    }

    func stopFrameObservation() {
        frameReadinessCheck?.cancel()
        frameReadinessCheck = nil
        onFirstVisibleFrame = nil
    }

    var isRetainingScreen: Bool { retainedScreenView != nil }

    static func hasVisibleContent(in terminal: Terminal) -> Bool {
        (0..<terminal.rows).contains { row in
            guard let line = terminal.getLine(row: row) else { return false }
            return line.translateToString(trimRight: true)
                .contains(where: { !$0.isWhitespace })
        }
    }

// quality-coverage:begin swiftterm-renderer
    func configureRealtimeRendererIfNeeded() {
        guard !didConfigureEventDrivenRenderer else { return }
        didConfigureEventDrivenRenderer = true
        // SwiftTerm's stable Metal path can retain an MTKView display loop on
        // macOS 26. Keep its event-driven CoreGraphics renderer until the
        // upstream idle-pausing frame driver reaches a stable release.
        try? setUseMetal(false)
        terminal.setCursorStyle(SessionAttachRendering.steadyCursorStyle(
            for: terminal.options.cursorStyle))
    }

    override func cursorStyleChanged(
        source: Terminal,
        newStyle: CursorStyle
    ) {
        let steadyStyle = SessionAttachRendering.steadyCursorStyle(for: newStyle)
        if steadyStyle.tagName != newStyle.tagName {
            source.setCursorStyle(steadyStyle)
            return
        }
        super.cursorStyleChanged(source: source, newStyle: steadyStyle)
    }
// quality-coverage:end swiftterm-renderer

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptedDragOperation(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDroppedPaths(from: sender.draggingPasteboard)
    }

    func acceptedDragOperation(from pasteboard: NSPasteboard) -> NSDragOperation {
        SessionAttachDroppedPaths.insertionText(from: pasteboard) == nil ? [] : .copy
    }

    func acceptDroppedPaths(from pasteboard: NSPasteboard) -> Bool {
        guard let text = SessionAttachDroppedPaths.insertionText(
            from: pasteboard) else {
            return false
        }
        window?.makeFirstResponder(self)
        onDroppedPaths?(text)
        return true
    }
}

/// A passive text screen that cannot take focus or intercept pointer input.
/// It exists only while a new terminal makes its first cold attachment.
private final class RetainedTerminalScreenView: NSView {
    init(
        frame: NSRect,
        screen: Data,
        fontPointSize: CGFloat
    ) {
        super.init(frame: frame)
        let terminal = TerminalView(
            frame: bounds,
            font: SessionAttachController.terminalFont(
                pointSize: fontPointSize))
        terminal.nativeBackgroundColor = ANSIParser.terminalBackground
        terminal.nativeForegroundColor = NSColor(white: 0.85, alpha: 1)
        terminal.terminal.setCursorStyle(.steadyBlock)
        try? terminal.setUseMetal(false)
        terminal.feed(byteArray: Array(screen)[...])
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum SessionAttachRendering {
    static func steadyCursorStyle(for style: CursorStyle) -> CursorStyle {
        switch style {
        case .blinkBlock, .steadyBlock:
            return .steadyBlock
        case .blinkUnderline, .steadyUnderline:
            return .steadyUnderline
        case .blinkBar, .steadyBar:
            return .steadyBar
        }
    }

// quality-coverage:begin swiftterm-renderer
    static func hasEnergyEfficientRenderer(
        in terminalView: LocalProcessTerminalView
    ) -> Bool {
        guard !terminalView.isUsingMetalRenderer else { return false }
        let style = terminalView.terminal.options.cursorStyle
        return steadyCursorStyle(for: style).tagName == style.tagName
    }
// quality-coverage:end swiftterm-renderer
}

/// Preserves provider shortcuts that must reach the child as conventional
/// control bytes, even after the child negotiates an enhanced keyboard mode.
enum SessionAttachKeyboard {
    enum AppAction: Equatable {
        case copy
        case paste
        case find
    }

    static func appAction(for event: NSEvent) -> AppAction? {
        let flags = event.modifierFlags.intersection(
            [.command, .control, .option, .shift, .function])
        guard flags == .command else { return nil }
        switch event.keyCode {
        case 8: return .copy
        case 9: return .paste
        case 3: return .find
        default: return nil
        }
    }

    static func providerInput(for event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control),
              flags.intersection([.command, .option, .shift, .function]).isEmpty,
              (event.keyCode == 9
                  || event.charactersIgnoringModifiers?.lowercased() == "v") else {
            return nil
        }
        return [0x16]
    }

    @discardableResult
    static func routeProviderShortcut(
        from event: NSEvent,
        send: ([UInt8]) -> Void
    ) -> Bool {
        guard let bytes = providerInput(for: event) else { return false }
        send(bytes)
        return true
    }
}

enum SessionAttachDroppedPaths {
    static func insertionText(from pasteboard: NSPasteboard) -> String? {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ?? []
        let paths = objects.compactMap { object -> String? in
            guard let url = object as? URL, url.isFileURL else { return nil }
            let path = url.standardizedFileURL.path
            return path.hasPrefix("/") ? shellEscaped(path) : nil
        }
        guard !paths.isEmpty else { return nil }
        return paths.joined(separator: " ") + " "
    }

    static func shellEscaped(_ path: String) -> String {
        if path.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) {
            let escaped = path.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x27: return "\\'"
                case 0x5c: return "\\\\"
                case 0x0a: return "\\n"
                case 0x0d: return "\\r"
                case 0x09: return "\\t"
                default:
                    guard CharacterSet.controlCharacters.contains(scalar) else {
                        return String(scalar)
                    }
                    if scalar.value <= 0xff {
                        return String(format: "\\x%02X", scalar.value)
                    }
                    if scalar.value <= 0xffff {
                        return String(format: "\\u%04X", scalar.value)
                    }
                    return String(format: "\\U%08X", scalar.value)
                }
            }.joined()
            return "$'\(escaped)'"
        }
        let safe = path.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || "/._-+=,:@%".unicodeScalars.contains(scalar)
        }
        guard !safe else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Hosts one ephemeral PTY client for a live managed session.
final class SessionAttachController: NSObject, LocalProcessTerminalViewDelegate {
    let invocation: SessionAttachInvocation
    private(set) weak var terminalView: LocalProcessTerminalView?
    private(set) var lastSize: (cols: Int, rows: Int)?
    private(set) var exitCode: Int32?
    var onTerminated: ((Int32?) -> Void)?

    init(invocation: SessionAttachInvocation) {
        self.invocation = invocation
    }

    func applyFont(pointSize: CGFloat) {
        guard let terminalView else { return }
        applyFont(to: terminalView, pointSize: pointSize)
    }

    func start() {
        guard let terminalView else { return }
        start(on: terminalView)
    }

    func terminateClient() {
        guard let terminalView else { return }
        Self.terminate(process: terminalView.process)
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        terminalView?.send(data: bytes[...])
    }

    func copySelection(to pasteboard: NSPasteboard = .general) -> String {
        SessionAttachClipboard.write(
            terminalView?.selection.getSelectedText() ?? "",
            to: pasteboard)
    }

    func selectAllText() {
        terminalView?.selectAll(nil)
    }

    func recordSize(cols: Int, rows: Int) {
        lastSize = (cols, rows)
    }

    func handleProcessExit(_ exitCode: Int32?) {
        self.exitCode = exitCode
        if Thread.isMainThread {
            onTerminated?(exitCode)
        } else {
            DispatchQueue.main.async { [onTerminated] in
                onTerminated?(exitCode)
            }
        }
    }

    static func terminalFont(pointSize: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: max(pointSize, 1), weight: .regular)
    }

    static func terminate(process: LocalProcess, timeout: TimeInterval = 1) {
        let pid = process.shellPid
        process.terminate()
        guard pid > 0 else { return }

        // Normal tmux clients exit from TERM and SwiftTerm reaps them. One
        // deadline check is enough for escalation; a 10 ms waitpid loop added
        // needless wakeups to every slow teardown and did not improve UX.
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, WNOHANG)
            } while result == -1 && errno == EINTR
            guard result == 0 else { return }
            _ = Darwin.kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

// quality-coverage:begin swiftterm-renderer
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        recordSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        handleProcessExit(exitCode)
    }

    func configure(_ view: LocalProcessTerminalView, fontPointSize: CGFloat) {
        view.processDelegate = self
        view.font = Self.terminalFont(pointSize: fontPointSize)
        view.nativeBackgroundColor = ANSIParser.terminalBackground
        view.nativeForegroundColor = NSColor(white: 0.85, alpha: 1)
        view.setAccessibilityIdentifier("session-preview-terminal")
        view.setAccessibilityLabel(L10n.string("Live session terminal"))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        terminalView = view
    }

    func applyFont(to view: LocalProcessTerminalView, pointSize: CGFloat) {
        let font = Self.terminalFont(pointSize: pointSize)
        guard view.font.pointSize != font.pointSize else { return }
        view.font = font
    }

    func start(on view: LocalProcessTerminalView) {
        view.startProcess(
            executable: invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment)
    }
// quality-coverage:end swiftterm-renderer
}

enum SessionAttachClipboard {
    @discardableResult
    static func write(_ text: String, to pasteboard: NSPasteboard) -> String {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }
}

struct SessionAttachTerminalView: NSViewRepresentable {
    let detachPath: String
    let session: Session
    let fontPointSize: CGFloat
    let screenCache: SessionTerminalScreenCache
    var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var onTerminated: (Int32?) -> Void = { _ in }
    var onFirstVisibleFrame: () -> Void = {}
    var onSwitchFailed: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: SessionAttachController(
                invocation: SessionAttachInvocation(
                    detachPath: detachPath,
                    session: session,
                    baseEnvironment: baseEnvironment)),
            session: session,
            screenCache: screenCache,
            onTerminated: onTerminated,
            onFirstVisibleFrame: onFirstVisibleFrame,
            onSwitchFailed: onSwitchFailed)
    }

// quality-coverage:begin swiftterm-host
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = SessionAttachLocalProcessTerminalView(frame: .zero)
        view.onDroppedPaths = { [weak controller = context.coordinator.controller] text in
            controller?.send(text)
        }
        view.onFirstVisibleFrame = {
            [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.reportFirstVisibleFrame(from: view)
        }
        context.coordinator.controller.onTerminated = context.coordinator.onTerminated
        context.coordinator.controller.configure(view, fontPointSize: fontPointSize)
        context.coordinator.installKeyboardMonitor(for: view)
        if let screen = context.coordinator.screenCache.screen(
            for: context.coordinator.session) {
            view.feed(byteArray: Array(screen)[...])
            view.retainScreen(
                screen,
                fontPointSize: fontPointSize)
        }
        context.coordinator.controller.start()
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTerminated = onTerminated
        context.coordinator.onFirstVisibleFrame = onFirstVisibleFrame
        context.coordinator.onSwitchFailed = onSwitchFailed
        context.coordinator.controller.onTerminated = onTerminated
        context.coordinator.controller.applyFont(pointSize: fontPointSize)
        context.coordinator.requestSession(session, in: view)
    }

    static func dismantleNSView(
        _ view: LocalProcessTerminalView,
        coordinator: Coordinator
    ) {
        coordinator.removeKeyboardMonitor()
        coordinator.cancelSwitch()
        coordinator.captureScreen(from: view)
        if let view = view as? SessionAttachLocalProcessTerminalView {
            view.stopFrameObservation()
            view.removeRetainedScreen()
            view.onDroppedPaths = nil
        }
        coordinator.controller.terminateClient()
    }
// quality-coverage:end swiftterm-host

    @MainActor
    final class Coordinator {
        let controller: SessionAttachController
        private(set) var session: Session
        let screenCache: SessionTerminalScreenCache
        var onTerminated: (Int32?) -> Void
        var onFirstVisibleFrame: () -> Void
        var onSwitchFailed: (String) -> Void
        private let switchCLI: any DetachCLIRunning
        private var keyboardMonitor: Any?
        private weak var attachedView: LocalProcessTerminalView?
        private var desiredSession: Session
        private var switchTask: Task<Void, Never>?

        init(
            controller: SessionAttachController,
            session: Session,
            screenCache: SessionTerminalScreenCache,
            onTerminated: @escaping (Int32?) -> Void,
            onFirstVisibleFrame: @escaping () -> Void = {},
            onSwitchFailed: @escaping (String) -> Void = { _ in },
            switchCLI: (any DetachCLIRunning)? = nil
        ) {
            self.controller = controller
            self.session = session
            self.desiredSession = session
            self.screenCache = screenCache
            self.onTerminated = onTerminated
            self.onFirstVisibleFrame = onFirstVisibleFrame
            self.onSwitchFailed = onSwitchFailed
            self.switchCLI = switchCLI ?? ProcessDetachCLI(
                executable: URL(fileURLWithPath: controller.invocation.executable))
        }

        func requestSession(
            _ target: Session,
            in view: LocalProcessTerminalView
        ) {
            attachedView = view
            desiredSession = target
            guard target.id != session.id, switchTask == nil else { return }
            switchTask = Task { @MainActor [weak self, weak view] in
                await self?.drainSwitches(in: view)
            }
        }

        func cancelSwitch() {
            switchTask?.cancel()
            switchTask = nil
            attachedView = nil
        }

        private func drainSwitches(in view: LocalProcessTerminalView?) async {
            defer { switchTask = nil }
            guard let view else { return }
            while !Task.isCancelled, desiredSession.id != session.id {
                let source = session
                let target = desiredSession
                let clientPID = view.process.shellPid
                guard attachedView === view,
                      view.process.running,
                      clientPID > 1 else {
                    onSwitchFailed(L10n.string(
                        "Could not identify the active terminal client"))
                    return
                }
                captureScreen(from: view)
                let result: CLIResult
                do {
                    result = try await switchCLI.run(
                        arguments: SessionClientSwitchInvocation.arguments(
                            clientPID: clientPID,
                            from: source,
                            to: target),
                        timeout: 2)
                } catch {
                    guard !Task.isCancelled, attachedView === view else { return }
                    onSwitchFailed(error.localizedDescription)
                    return
                }
                guard !Task.isCancelled, attachedView === view else { return }
                guard !result.timedOut, result.exitCode == 0 else {
                    let message = result.stderr
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    onSwitchFailed(message.isEmpty
                        ? L10n.string("Could not switch the terminal session")
                        : message)
                    return
                }
                session = target
            }
        }

        func captureScreen(from view: LocalProcessTerminalView) {
            let data = view.terminal.getBufferAsData()
            MainActor.assumeIsolated {
                guard SessionTerminalScreenCache.normalized(data) != nil else {
                    return
                }
                screenCache.store(data, for: session)
            }
        }

        func reportFirstVisibleFrame(from view: LocalProcessTerminalView) {
            captureScreen(from: view)
            onFirstVisibleFrame()
        }

        func installKeyboardMonitor(for view: LocalProcessTerminalView) {
            removeKeyboardMonitor()
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak view] event in
                guard let self, let view else { return event }
                return self.routeKeyboardEvent(
                    event,
                    window: event.window,
                    firstResponder: event.window?.firstResponder,
                    in: view,
                    send: view.send)
            }
        }

        func routeKeyboardEvent(
            _ event: NSEvent,
            window: NSWindow?,
            firstResponder: NSResponder?,
            in view: LocalProcessTerminalView,
            send: ([UInt8]) -> Void,
            performAppAction: ((SessionAttachKeyboard.AppAction) -> Void)? = nil
        ) -> NSEvent? {
            guard window === view.window,
                  Self.isFocused(view, firstResponder: firstResponder) else {
                return event
            }
            if let action = SessionAttachKeyboard.appAction(for: event) {
                (performAppAction ?? { Self.perform($0, in: view) })(action)
                return nil
            }
            return SessionAttachKeyboard.routeProviderShortcut(
                from: event,
                send: send) ? nil : event
        }

        func removeKeyboardMonitor() {
            guard let keyboardMonitor else { return }
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }

        private static func isFocused(
            _ view: LocalProcessTerminalView,
            firstResponder: NSResponder?
        ) -> Bool {
            guard let responder = firstResponder else { return false }
            if responder === view { return true }
            return (responder as? NSView)?.isDescendant(of: view) == true
        }

        static func perform(
            _ action: SessionAttachKeyboard.AppAction,
            in view: LocalProcessTerminalView
        ) {
            switch action {
            case .copy:
                view.copy(view)
            case .paste:
                view.paste(view)
            case .find:
                let menuItem = NSMenuItem()
                menuItem.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                view.performFindPanelAction(menuItem)
            }
        }

        deinit {
            switchTask?.cancel()
            if let keyboardMonitor {
                NSEvent.removeMonitor(keyboardMonitor)
            }
        }
    }
}
