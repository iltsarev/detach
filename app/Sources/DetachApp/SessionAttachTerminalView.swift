import AppKit
import Darwin
import MetalKit
import SwiftUI
import SwiftTerm
import DetachKit

final class SessionAttachLocalProcessTerminalView: LocalProcessTerminalView {
    var onDroppedPaths: ((String) -> Void)?
    private var didConfigureRealtimeRenderer = false

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

// quality-coverage:begin swiftterm-metal
    func configureRealtimeRendererIfNeeded() {
        guard !didConfigureRealtimeRenderer else { return }
        didConfigureRealtimeRenderer = true
        let enabled = SessionAttachRendering.enableOnDemandMetal {
            try setUseMetal(true)
        }
        if enabled {
            terminal.setCursorStyle(SessionAttachRendering.steadyCursorStyle(
                for: terminal.options.cursorStyle))
        }
    }

    override func cursorStyleChanged(
        source: Terminal,
        newStyle: CursorStyle
    ) {
        guard isUsingMetalRenderer else {
            super.cursorStyleChanged(source: source, newStyle: newStyle)
            return
        }
        let steadyStyle = SessionAttachRendering.steadyCursorStyle(for: newStyle)
        if steadyStyle.tagName != newStyle.tagName {
            source.setCursorStyle(steadyStyle)
            return
        }
        super.cursorStyleChanged(source: source, newStyle: steadyStyle)
    }
// quality-coverage:end swiftterm-metal

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

enum SessionAttachRendering {
    /// SwiftTerm's Metal view is paused and redraws only on terminal events.
    /// A renderer failure keeps the default CoreGraphics terminal active.
    @discardableResult
    static func enableOnDemandMetal(
        _ activate: () throws -> Void
    ) -> Bool {
        do {
            try activate()
            return true
        } catch {
            return false
        }
    }

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

    static func isPausedOnDemand(_ view: MTKView) -> Bool {
        view.isPaused
            && view.enableSetNeedsDisplay
            && !view.autoResizeDrawable
    }

// quality-coverage:begin swiftterm-metal
    static func hasEnergyEfficientMetalRenderer(
        in terminalView: LocalProcessTerminalView
    ) -> Bool {
        guard terminalView.isUsingMetalRenderer,
              let metalView = terminalView.subviews.compactMap({
                  $0 as? MTKView
              }).first,
              isPausedOnDemand(metalView) else {
            return false
        }
        let style = terminalView.terminal.options.cursorStyle
        return steadyCursorStyle(for: style).tagName == style.tagName
    }
// quality-coverage:end swiftterm-metal
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

        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) {
                    return
                }
                guard result == 0 else { return }
                usleep(10_000)
            }

            guard waitpid(pid, &status, WNOHANG) == 0 else { return }
            _ = Darwin.kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

// quality-coverage:begin swiftterm-metal
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
// quality-coverage:end swiftterm-metal
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
    var focusRequestID: UUID? = nil
    var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    var onTerminated: (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: SessionAttachController(
                invocation: SessionAttachInvocation(
                    detachPath: detachPath,
                    session: session,
                    baseEnvironment: baseEnvironment)),
            onTerminated: onTerminated)
    }

// quality-coverage:begin swiftterm-host
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = SessionAttachLocalProcessTerminalView(frame: .zero)
        view.onDroppedPaths = { [weak controller = context.coordinator.controller] text in
            controller?.send(text)
        }
        context.coordinator.controller.onTerminated = context.coordinator.onTerminated
        context.coordinator.controller.configure(view, fontPointSize: fontPointSize)
        context.coordinator.installKeyboardMonitor(for: view)
        context.coordinator.controller.start()
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTerminated = onTerminated
        context.coordinator.controller.onTerminated = onTerminated
        context.coordinator.controller.applyFont(pointSize: fontPointSize)
        context.coordinator.focusIfRequested(focusRequestID, in: view)
    }

    static func dismantleNSView(
        _ view: LocalProcessTerminalView,
        coordinator: Coordinator
    ) {
        coordinator.removeKeyboardMonitor()
        (view as? SessionAttachLocalProcessTerminalView)?.onDroppedPaths = nil
        coordinator.controller.terminateClient()
    }
// quality-coverage:end swiftterm-host

    final class Coordinator {
        let controller: SessionAttachController
        var onTerminated: (Int32?) -> Void
        private var keyboardMonitor: Any?
        private var handledFocusRequestID: UUID?

        init(controller: SessionAttachController, onTerminated: @escaping (Int32?) -> Void) {
            self.controller = controller
            self.onTerminated = onTerminated
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

        func focusIfRequested(_ requestID: UUID?, in view: LocalProcessTerminalView) {
            guard shouldHandleFocusRequest(requestID) else { return }
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }

        func shouldHandleFocusRequest(_ requestID: UUID?) -> Bool {
            guard let requestID, requestID != handledFocusRequestID else {
                return false
            }
            handledFocusRequestID = requestID
            return true
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
            removeKeyboardMonitor()
        }
    }
}
