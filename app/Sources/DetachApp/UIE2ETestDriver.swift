import AppKit
import Darwin
import DetachKit
import Foundation
import SwiftTerm

@MainActor
enum UIE2EControlFault {
    static var stopActionDisconnected = false
    static var stopActionAttempts = 0
}

private final class UIE2EDeferredMouseUp: @unchecked Sendable {
    private let application: NSApplication
    private let event: NSEvent

    init(application: NSApplication, event: NSEvent) {
        self.application = application
        self.event = event
    }

    func post() {
        application.postEvent(event, atStart: false)
    }
}

enum UIE2ECursorPositionResolver {
    static func quartzPoint(
        for appKitPoint: CGPoint,
        screenFrame: CGRect,
        displayBounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + appKitPoint.x - screenFrame.minX,
            y: displayBounds.minY + screenFrame.maxY - appKitPoint.y)
    }
}

@MainActor
enum UIE2EEventWindowResolver {
    static func owner(
        of element: any NSAccessibilityProtocol
    ) -> NSWindow? {
        if let window = element as? NSWindow { return window }
        if let view = element as? NSView, let window = view.window { return window }
        return element.accessibilityWindow() as? NSWindow
    }

    static func resolve(
        owningWindow: NSWindow?,
        at screenPoint: CGPoint,
        candidates: [NSWindow]
    ) -> NSWindow? {
        if let owningWindow {
            if let sheet = candidates.first(where: {
                $0.sheetParent === owningWindow
                    && $0.frame.contains(screenPoint)
            }) {
                return sheet
            }
            return owningWindow.frame.contains(screenPoint) ? owningWindow : nil
        }
        return candidates.first { $0.frame.contains(screenPoint) }
    }

    static func screenFrame(
        _ frame: CGRect,
        in view: NSView
    ) -> CGRect? {
        guard let window = view.window else { return nil }
        let windowFrame = view.convert(frame, to: nil)
        if window.sheetParent != nil {
            return CGRect(
                x: window.frame.minX + windowFrame.minX,
                y: window.frame.minY + windowFrame.minY,
                width: windowFrame.width,
                height: windowFrame.height)
        }
        return window.convertToScreen(windowFrame)
    }

    static func isSafelyVisible(
        _ targetFrame: CGRect,
        from view: NSView
    ) -> Bool {
        guard let scrollView = view.enclosingScrollView,
              let viewport = screenFrame(
                scrollView.contentView.bounds,
                in: scrollView.contentView)
        else { return true }
        let safeViewport = viewport.insetBy(dx: 8, dy: 8)
        return safeViewport.contains(CGPoint(
            x: targetFrame.midX,
            y: targetFrame.midY))
    }

    static func scrollPageFrame(
        toward targetFrame: CGRect,
        from view: NSView
    ) -> CGRect? {
        guard !isSafelyVisible(targetFrame, from: view),
              let scrollView = view.enclosingScrollView,
              let scroller = scrollView.verticalScroller,
              !scroller.isHidden,
              let viewport = screenFrame(
                scrollView.contentView.bounds,
                in: scrollView.contentView)
        else { return nil }
        let pageFrames = [NSScroller.Part.incrementPage, .decrementPage]
            .compactMap { part -> CGRect? in
                let localFrame = scroller.rect(for: part)
                guard localFrame.width > 0, localFrame.height > 0 else {
                    return nil
                }
                return screenFrame(localFrame, in: scroller)
            }
        if targetFrame.midY < viewport.midY {
            return pageFrames.min { $0.midY < $1.midY }
        }
        return pageFrames.max { $0.midY < $1.midY }
    }
}

/// A narrowly gated, same-process accessibility driver for the packaged-app
/// smoke test. Keeping traversal and actions inside the tested process avoids
/// a second automation executable and its independent identity. This path is
/// dormant in production and becomes reachable only in a stripped,
/// background-only app copy whose identity and every data path are validated
/// by `UIE2EConfiguration`.
@MainActor
enum UIE2ETestDriver {
    private struct Report: Codable, Sendable {
        let schema: Int
        let passed: Bool
        let checks: [String]
        let error: String?
        let accessibilityTree: [ElementSnapshot]
    }

    private struct ElementSnapshot: Codable, Sendable {
        let role: String
        let identifier: String?
        let label: String?
        let value: String?
        let frame: String
        let enabled: Bool
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var started = false
    private static var scenarioStartedAt = ProcessInfo.processInfo.systemUptime
    private static var scenarioDeadline = TimeInterval.greatestFiniteMagnitude
    private static var nextMouseEventNumber = Int(
        ProcessInfo.processInfo.systemUptime * 1_000)
    private static var cursorRestorePoint: CGPoint?

    static func runIfRequested(
        installation: InstallationStore,
        store: SessionStore,
        sessionLogSnapshots: SessionLogSnapshotCache,
        shortcuts: SessionShortcutRegistry
    ) async {
        guard let configuration = AppSettings.uiE2E, !started else { return }
        started = true
        Task { @MainActor in
            scenarioStartedAt = ProcessInfo.processInfo.systemUptime
            scenarioDeadline = scenarioStartedAt
                + Double(configuration.driverBudgetSeconds)
            while !store.hasFreshSnapshot {
                guard ProcessInfo.processInfo.systemUptime < scenarioDeadline else {
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return
                }
            }
            let report: Report
            if store.hasFreshSnapshot {
                try? await Task.sleep(nanoseconds: 50_000_000)
                scenarioStartedAt = ProcessInfo.processInfo.systemUptime
                scenarioDeadline = scenarioStartedAt
                    + Double(configuration.driverBudgetSeconds)
                trace(
                    "\(configuration.scenario) driver started "
                        + "(budget \(configuration.driverBudgetSeconds)s)")
                report = await runScenario(
                    configuration: configuration,
                    installation: installation,
                    store: store,
                    sessionLogSnapshots: sessionLogSnapshots,
                    shortcuts: shortcuts)
            } else {
                report = Report(
                    schema: 1,
                    passed: false,
                    checks: [],
                    error: "initial typed session snapshot timed out",
                    accessibilityTree: snapshots())
            }
            trace("\(configuration.scenario) driver finished: \(report.passed)")
            try? write(report, to: configuration.result)
            NSApp.terminate(nil)
            // A SwiftUI sheet can defer normal termination even after it is
            // dismissed. The validated test copy owns no durable state, so keep
            // the harness bounded after the atomic report is safely on disk.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                _exit(EXIT_SUCCESS)
            }
        }
    }

    private static func runScenario(
        configuration: UIE2EConfiguration,
        installation: InstallationStore,
        store: SessionStore,
        sessionLogSnapshots: SessionLogSnapshotCache,
        shortcuts: SessionShortcutRegistry
    ) async -> Report {
        cursorRestorePoint = CGEvent(source: nil)?.location
        defer {
            if let cursorRestorePoint {
                CGWarpMouseCursorPosition(cursorRestorePoint)
            }
            cursorRestorePoint = nil
        }
        switch configuration.scenario {
        case "onboarding-first-run":
            return await runOnboardingFirstRun(
                configuration: configuration,
                installation: installation)
        case "onboarding-provider":
            return await runOnboardingPresentation(
                viewIdentifier: "onboarding-provider",
                evidenceIdentifier: "onboarding-provider-detected",
                check: "onboarding-detects-provider")
        case "onboarding-approval":
            return await runOnboardingPresentation(
                viewIdentifier: "onboarding-approval",
                evidenceIdentifier: "onboarding-open-system-settings",
                check: "onboarding-explains-approval")
        default:
            return await runMainScenario(
                configuration: configuration,
                store: store,
                sessionLogSnapshots: sessionLogSnapshots,
                shortcuts: shortcuts)
        }
    }

    private static func runMainScenario(
        configuration: UIE2EConfiguration,
        store: SessionStore,
        sessionLogSnapshots: SessionLogSnapshotCache,
        shortcuts: SessionShortcutRegistry
    ) async -> Report {
        var checks: [String] = []
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let previousActivationPolicy = NSApp.activationPolicy()
        defer {
            UIE2EControlFault.stopActionDisconnected = false
            UIE2EControlFault.stopActionAttempts = 0
        }
        do {
            trace("driver started")
            guard !NSApp.isActive else {
                throw Failure(message: "background test app stole keyboard focus")
            }
            checks.append("background-app-starts-without-focus")
            guard let mainWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "main"
            }) else {
                throw Failure(message: "main test window is missing")
            }
            guard NSApp.setActivationPolicy(.regular) else {
                throw Failure(message: "cannot enable test app activation")
            }
            try await activate(mainWindow)
            trace("test app activated")

            let dashboard = try await element(role: .splitGroup)
            try requireGeometry(dashboard, name: "dashboard")
            checks.append("dashboard-accessible")
            trace("dashboard accessible")
            let shortcutGuide = try await element(
                identifier: "sidebar-shortcut-guide")
            try requireGeometry(shortcutGuide, name: "sidebar shortcut guide")
            checks.append("sidebar-shortcut-guide-visible")

            let recoverableID = "detach-codex-ui-recoverable"
            let recoverableRow = try await element(
                identifier: "session-row-\(recoverableID)")
            try requireSemanticControl(
                recoverableRow, name: "recoverable session row")
            guard let recoverableSession = store.sessions.first(where: {
                $0.id == recoverableID
            }) else {
                throw Failure(message: "recoverable session is missing")
            }
            try await waitUntil("recoverable log snapshot warm-up") {
                sessionLogSnapshots.poller(for: recoverableSession).hasLoaded
            }
            _ = try await clickUntilElement(
                recoverableRow,
                name: "recoverable session row",
                resultIdentifier: "session-detail-\(recoverableID)")
            // Prove that selection uses the snapshot warmed above. A wall-clock
            // bound here also measures the synthetic click, Accessibility, and
            // runner scheduling, none of which can distinguish a cache miss.
            try await waitUntil("warm recoverable log without a reread", attempts: 5) {
                guard let scrollView = find(identifier: "session-preview-log")
                        as? NSScrollView,
                      let textView = scrollView.documentView as? NSTextView else {
                    return false
                }
                let invocations = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/invocations.log"),
                    encoding: .utf8)
                let logReads = invocations?
                    .split(separator: "\n")
                    .filter { $0 == "codex logs --ansi \(recoverableID)" }
                    .count ?? 0
                return logReads == 1 && textView.string.contains(
                    "UI fixture log for \(recoverableID)")
            }
            checks.append("non-live-session-switch-uses-warm-cache")
            let recoverButton = try await element(
                identifier: "session-action-recover-in-app")
            let recoverFallback = try await element(
                identifier: "session-action-recover-external")
            try requireSemanticControl(
                recoverButton, name: "in-app recover action")
            try requireSemanticControl(
                recoverFallback, name: "external recover fallback")
            try await clickUntil(
                recoverButton,
                name: "in-app recover action",
                outcome: "public detached recover reaches fake CLI") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains(
                    "codex recover --detach \(recoverableID)") == true
            }
            let reconnectButton = try await element(
                identifier: "session-action-attach-in-app")
            let reconnectFallback = try await element(
                identifier: "session-action-attach-external")
            try requireSemanticControl(
                reconnectButton, name: "in-app reconnect action")
            try requireSemanticControl(
                reconnectFallback, name: "external reconnect fallback")
            guard label(reconnectButton) == L10n.string("Reconnect") else {
                throw Failure(message: "exited attach client does not offer Reconnect")
            }
            try await clickUntil(
                reconnectButton,
                name: "in-app reconnect action",
                outcome: "second attach client reaches fake CLI") {
                let invocations = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/invocations.log"),
                    encoding: .utf8)
                let attachCount = invocations?
                    .split(separator: "\n")
                    .filter {
                        $0 == "codex attach --terminal-features sync \(recoverableID)"
                    }
                    .count ?? 0
                return attachCount >= 2
            }
            try await waitUntil("reconnected session terminal", attempts: 80) {
                find(identifier: "session-preview-terminal") != nil
            }
            checks.append(
                "recover-and-reconnect-run-in-app-with-terminal-fallback")

            let completedID = "detach-claude-ui-completed"
            let completedRow = try await element(
                identifier: "session-row-\(completedID)")
            try requireSemanticControl(completedRow, name: "completed session row")
            let completedDetail = try await clickUntilElement(
                completedRow,
                name: "completed session row",
                resultIdentifier: "session-detail-\(completedID)")
            try requireGeometry(completedDetail, name: "completed session detail")
            let completedLogSurface = try await measuredFrame(
                identifier: "session-detail-log-surface",
                name: "completed session log surface")
            let deleteButton = try await element(identifier: "session-action-delete")
            try requireSemanticControl(deleteButton, name: "delete action")
            checks.append("sidebar-selects-completed-session")
            trace("completed session selected")

            let copiedUUID = "a9f58f1d-1234-5678-9abc-def012342ed9"
            let pasteboardSnapshot = captureGeneralPasteboard()
            defer { restoreGeneralPasteboard(pasteboardSnapshot) }
            let pasteboardGeneration = NSPasteboard.general.changeCount
            try await clickMeasuredControl(
                identifier: "session-uuid-chip",
                name: "session UUID chip text",
                offset: CGSize(width: 24, height: 0),
                size: CGSize(width: 36, height: 18))
            try await waitUntil("copied full UUID and confirmation", attempts: 30) {
                find(identifier: "session-uuid-chip").flatMap(label)
                    == L10n.string("Copied")
                    && NSPasteboard.general.changeCount > pasteboardGeneration
                    && NSPasteboard.general.string(forType: .string) == copiedUUID
            }
            try await waitUntil("UUID copy confirmation reset", attempts: 50) {
                find(identifier: "session-uuid-chip").flatMap(label)
                    == L10n.string("Copy session UUID")
            }
            checks.append("session-uuid-copies-from-text-side")
            let resumeButton = try await element(
                identifier: "session-action-resume-in-app")
            let resumeFallback = try await element(
                identifier: "session-action-resume-external")
            try requireSemanticControl(resumeButton, name: "in-app resume action")
            try requireSemanticControl(resumeFallback, name: "external resume fallback")
            try await clickUntil(
                resumeButton,
                name: "in-app resume action",
                outcome: "public detached resume reaches fake CLI") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains(
                    "resume --detach a9f58f1d-1234-5678-9abc-def012342ed9") == true
            }
            try await waitUntil("resumed session attaches in app", attempts: 80) {
                find(identifier: "session-preview-terminal") != nil
            }
            checks.append("resume-runs-in-app-with-terminal-fallback")
            let runningID = "detach-codex-ui-running"
            let runningRow = try await element(
                identifier: "session-row-\(runningID)")
            try requireSemanticControl(runningRow, name: "running session row")
            try await waitUntil("running session Command-1 assignment") {
                shortcuts.slot(for: runningID) == 1
            }
            let shortcutBadge = try await element(
                identifier: "session-shortcut-\(runningID)")
            try requireGeometry(shortcutBadge, name: "running session shortcut")
            guard label(shortcutBadge) == "Command-1" else {
                throw Failure(message: "running session badge is not Command-1")
            }
            try await keyPress("1", keyCode: 18, modifiers: [.command])
            _ = try await element(identifier: "session-detail-\(runningID)")
            checks.append("session-shortcut-selects-assigned-session")
            try await waitUntil("live attach terminal", attempts: 80) {
                find(identifier: "session-preview-terminal") != nil
            }
            checks.append("live-session-hosts-attach-client")
            let runningLogSurface = try await measuredFrame(
                identifier: "session-detail-log-surface",
                name: "running session log surface")
            guard abs(runningLogSurface.minY - completedLogSurface.minY) <= 1,
                  abs(runningLogSurface.height - completedLogSurface.height) <= 1 else {
                throw Failure(message:
                    "session selection changed the terminal frame from "
                    + "\(completedLogSurface) to \(runningLogSurface)")
            }
            checks.append("session-switch-keeps-terminal-layout-stable")
            try await waitUntil("event-driven terminal renderer", attempts: 80) {
                guard let terminal = find(
                    identifier: "session-preview-terminal")
                    as? LocalProcessTerminalView else {
                    return false
                }
                return SessionAttachRendering
                    .hasEnergyEfficientRenderer(in: terminal)
            }
            guard let liveTerminal = find(
                identifier: "session-preview-terminal")
                as? LocalProcessTerminalView else {
                throw Failure(message: "live terminal is not a SwiftTerm view")
            }
            let liveClientPID = liveTerminal.process.shellPid
            guard liveClientPID > 1 else {
                throw Failure(message: "live terminal client PID is missing")
            }
            liveTerminal.terminal.setCursorStyle(.blinkUnderline)
            guard liveTerminal.terminal.options.cursorStyle.tagName
                    == CursorStyle.steadyUnderline.tagName,
                  SessionAttachRendering.hasEnergyEfficientRenderer(
                    in: liveTerminal) else {
                throw Failure(message: "live terminal retained a blinking cursor timer")
            }
            checks.append("live-terminal-renders-on-demand")
            try await waitUntil("live terminal input readiness", attempts: 80) {
                FileManager.default.fileExists(atPath: configuration.root
                    .appendingPathComponent("fake/control-v-ready").path)
            }
            try await keyPress("v", keyCode: 9, modifiers: [.control])
            try await waitUntil("raw control-V reaches attach PTY", attempts: 80) {
                (try? Data(contentsOf: configuration.root
                    .appendingPathComponent("fake/control-v.bin"))) == Data([0x16])
            }
            checks.append("live-terminal-routes-control-v")

            try await waitUntil("running terminal frame") {
                String(decoding: liveTerminal.terminal.getBufferAsData(), as: UTF8.self)
                    .contains(runningID)
            }
            let invocationsURL = configuration.root
                .appendingPathComponent("fake/invocations.log")
            let attachCountBefore = try String(
                contentsOf: invocationsURL,
                encoding: .utf8)
                .split(separator: "\n")
                .filter { $0.contains(" attach --terminal-features sync ") }
                .count

            // Both rows are live. Selection must preserve the exact SwiftTerm
            // object and PTY while the public client-switch command is delayed.
            let resumedRow = try await element(
                identifier: "session-row-\(completedID)")
            let toCompleted = "client switch --pid \(liveClientPID)"
                + " --from \(runningID) --to \(completedID) --provider claude"
            _ = try await clickUntilElement(
                resumedRow,
                name: "resumed session row",
                resultIdentifier: "session-detail-\(completedID)")
            guard let terminalDuringSwitch = find(
                    identifier: "session-preview-terminal")
                    as? LocalProcessTerminalView,
                  terminalDuringSwitch === liveTerminal,
                  terminalDuringSwitch.process.shellPid == liveClientPID,
                  String(decoding: terminalDuringSwitch.terminal.getBufferAsData(), as: UTF8.self)
                    .contains(runningID) else {
                throw Failure(message:
                    "live switch replaced the terminal or cleared its complete frame")
            }
            try await waitUntil("ownership-safe client switch starts", attempts: 20) {
                let invocations = try? String(
                    contentsOf: invocationsURL,
                    encoding: .utf8)
                return invocations?.split(separator: "\n")
                    .contains(Substring(toCompleted)) == true
            }
            try await waitUntil("synchronized completed redraw", attempts: 40) {
                String(decoding: liveTerminal.terminal.getBufferAsData(), as: UTF8.self)
                    .contains(completedID)
            }

            let toRunning = "client switch --pid \(liveClientPID)"
                + " --from \(completedID) --to \(runningID) --provider codex"
            try await keyPress("1", keyCode: 18, modifiers: [.command])
            try await waitUntil("same client switches back", attempts: 40) {
                guard let terminal = find(identifier: "session-preview-terminal")
                        as? LocalProcessTerminalView,
                      terminal === liveTerminal,
                      terminal.process.shellPid == liveClientPID else { return false }
                let invocations = try? String(
                    contentsOf: invocationsURL,
                    encoding: .utf8)
                return invocations?.split(separator: "\n")
                    .contains(Substring(toRunning)) == true
                    && String(decoding: terminal.terminal.getBufferAsData(), as: UTF8.self)
                        .contains(runningID)
            }
            let attachCountAfter = try String(
                contentsOf: invocationsURL,
                encoding: .utf8)
                .split(separator: "\n")
                .filter { $0.contains(" attach --terminal-features sync ") }
                .count
            guard attachCountAfter == attachCountBefore else {
                throw Failure(message:
                    "live switches launched a replacement attach client")
            }
            checks.append("live-session-switch-reuses-synchronized-client")
            let identityMarker = try await measuredFrame(
                identifier: "session-detail-identity-marker",
                name: "session identity marker")
            guard identityMarker.height >= identityMarker.width * 3 else {
                throw Failure(message: "session identity marker reads as a status dot")
            }
            let previewPower = try await measuredFrame(
                identifier: "session-preview-power",
                name: "session preview power")
            guard identityMarker.intersection(previewPower).isNull else {
                throw Failure(message: "session identity and power overlap")
            }
            checks.append("session-signals-stay-distinct")
            let stopButton = try await element(identifier: "session-action-stop")
            try requireSemanticControl(stopButton, name: "stop action")
            UIE2EControlFault.stopActionAttempts = 0
            UIE2EControlFault.stopActionDisconnected = true
            try await clickUntil(
                stopButton,
                name: "disconnected stop action",
                outcome: "disconnected stop action reaches fault boundary") {
                UIE2EControlFault.stopActionAttempts > 0
            }
            let disconnectedActions = try? String(
                contentsOf: configuration.root
                    .appendingPathComponent("fake/actions.log"),
                encoding: .utf8)
            guard disconnectedActions?.contains("codex stop \(runningID)") != true else {
                throw Failure(message: "disconnected stop action reached fake CLI")
            }
            checks.append("disconnected-stop-blocks-action")
            UIE2EControlFault.stopActionDisconnected = false
            try await clickUntil(
                stopButton,
                name: "stop action",
                outcome: "fake CLI records stop action") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains("codex stop \(runningID)") == true
            }
            checks.append("safe-action-reaches-fake-cli")
            trace("stop reached fake CLI")

            let selectionMode = try await element(
                identifier: "finished-selection-mode-button")
            try requireSemanticControl(
                selectionMode, name: "finished selection mode")
            let selectionModeFrame = try await measuredFrame(
                identifier: "finished-selection-mode-button",
                name: "finished selection mode")
            let finishedHeaderFrame = try await measuredFrame(
                identifier: "finished-section-header",
                name: "finished section header")
            guard finishedHeaderFrame.maxX - selectionModeFrame.maxX >= 10 else {
                throw Failure(
                    message: "finished selection mode has no trailing scroll clearance")
            }
            checks.append("finished-selection-clears-scrollbar")
            _ = try await clickUntilElement(
                selectionMode,
                name: "finished selection mode",
                resultIdentifier: "finished-select-all-button")
            let stoppedID = "detach-codex-ui-stopped"
            let stoppedSelectionID = "finished-selection-\(stoppedID)"
            var stoppedSelection = try await element(identifier: stoppedSelectionID)
            try requireSemanticControl(
                stoppedSelection, name: "stopped session selection")
            try await click(stoppedSelection, name: "select stopped session")
            try await waitUntil("selected stopped session") {
                find(identifier: stoppedSelectionID)
                    .flatMap(label)?.hasPrefix("Deselect") == true
            }
            stoppedSelection = try await element(identifier: stoppedSelectionID)
            try await click(stoppedSelection, name: "deselect stopped session")
            try await waitUntil("deselected stopped session") {
                find(identifier: stoppedSelectionID)
                    .flatMap(label)?.hasPrefix("Select") == true
            }

            var selectAll = try await element(identifier: "finished-select-all-button")
            try requireSemanticControl(selectAll, name: "select all finished sessions")
            try await click(selectAll, name: "select all finished sessions")
            try await waitUntil("all finished sessions selected") {
                find(identifier: "finished-select-all-button")
                    .flatMap(label) == "Clear selection"
            }
            selectAll = try await element(identifier: "finished-select-all-button")
            try await click(selectAll, name: "clear finished selection")
            try await waitUntil("finished selection cleared") {
                find(identifier: "finished-select-all-button")
                    .flatMap(label) == "Select all"
            }

            let done = try await element(identifier: "finished-selection-mode-button")
            try await click(done, name: "leave finished selection mode")
            try await waitUntil("finished selection mode closed") {
                find(identifier: "finished-select-all-button") == nil
            }
            let selectAgain = try await element(
                identifier: "finished-selection-mode-button")
            _ = try await clickUntilElement(
                selectAgain,
                name: "reopen finished selection mode",
                resultIdentifier: "finished-select-all-button")
            selectAll = try await element(identifier: "finished-select-all-button")
            try await click(selectAll, name: "select all finished sessions")
            var bulkDeleteButton = try await element(identifier: "finished-delete-button")
            try await waitUntil("enabled bulk delete button") {
                find(identifier: "finished-delete-button")
                    .map(isEnabled) == true
            }
            bulkDeleteButton = try await element(identifier: "finished-delete-button")
            try requireSemanticControl(bulkDeleteButton, name: "bulk delete action")
            let confirmDelete = try await clickUntilSheetButton(
                bulkDeleteButton, name: "bulk delete action", label: "Delete")
            try requireSemanticControl(confirmDelete, name: "delete confirmation")
            try await clickUntil(
                confirmDelete,
                name: "delete confirmation",
                outcome: "fake CLI records stopped-session delete") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains(
                    "codex delete --force \(stoppedID)") == true
            }
            checks.append("bulk-delete-reaches-fake-cli")
            trace("bulk delete reached fake CLI")
            let deleteObservedAt = Date()
            try await waitUntil("post-delete session refresh") {
                store.lastUpdated.map { $0 >= deleteObservedAt } == true
            }
            try await waitUntil("delete confirmation dismissal") {
                NSApp.windows.allSatisfy(\.sheets.isEmpty)
            }
            try await activate(mainWindow)

            let newSession = try await element(identifier: "new-session-button")
            try requireSemanticControl(newSession, name: "new session action")
            try await click(newSession, name: "new session action")
            _ = try await measuredFrame(
                identifier: "new-session-sheet", name: "new session sheet")
            guard UIE2EGeometryRegistry.frame(for: "new-session-prompt") == nil else {
                throw Failure(message: "Advanced prompt is visible while collapsed")
            }
            let launchControl = try await element(identifier: "new-session-launch")
            let expectedLaunch = L10n.string("Start")
            guard label(launchControl) == expectedLaunch else {
                throw Failure(
                    message: "launch button is \(label(launchControl) ?? "nil"), expected \(expectedLaunch)")
            }
            guard !isEnabled(launchControl) else {
                throw Failure(message: "new-session launch is enabled without a project")
            }
            guard let sheet = NSApp.windows.flatMap(\.sheets).first else {
                throw Failure(message: "new-session sheet is missing")
            }
            trace("new-session sheet window \(sheet.frame)")
            let pinnedTop = sheet.frame.maxY
            let collapsedHeight = sheet.frame.height
            let advanced = try await element(identifier: "new-session-advanced")
            try requireSemanticControl(advanced, name: "new session Advanced")
            try await click(advanced, name: "new session Advanced")
            _ = try await measuredFrame(
                identifier: "new-session-prompt", name: "new session prompt")
            guard UIE2EGeometryRegistry.frame(for: "new-session-terminal") == nil else {
                throw Failure(message: "new-session sheet still hosts a terminal picker")
            }
            checks.append("new-session-starts-without-outer-terminal")
            var lastMaxY = pinnedTop
            var lastFrame = sheet.frame
            do {
                try await waitUntil("new-session top edge stays fixed", attempts: 40) {
                    guard let current = NSApp.windows.flatMap(\.sheets).first else {
                        return false
                    }
                    lastFrame = current.frame
                    lastMaxY = current.frame.maxY
                    return lastFrame.height > collapsedHeight + 40
                        && abs(lastMaxY - pinnedTop) < 24
                }
            } catch {
                throw Failure(
                    message: "new-session top edge moved from \(pinnedTop) to \(lastMaxY) frame=\(lastFrame)")
            }
            checks.append("new-session-advanced-keeps-top-edge")
            try await clickMeasuredControl(
                identifier: "new-session-launch",
                name: "disabled new session launch")
            guard NSApp.windows.contains(where: { !$0.sheets.isEmpty }) else {
                throw Failure(message: "new-session launch is active without a project")
            }
            try await clickMeasuredUntil(
                identifier: "new-session-cancel",
                name: "new session cancel",
                outcome: "new-session sheet closes") {
                NSApp.windows.allSatisfy(\.sheets.isEmpty)
            }
            checks.append("new-session-sheet-semantics")
            trace("new-session sheet closed")

            try Data().write(to: configuration.root.appendingPathComponent(
                "fake/enable-new-session-project"), options: .atomic)
            try await activate(mainWindow)
            try await keyPress("n", keyCode: 45, modifiers: [.command])
            _ = try await measuredFrame(
                identifier: "new-session-sheet", name: "new session sheet")
            checks.append("new-session-command-opens-sheet")
            try await waitUntil("enabled new session launch") {
                find(identifier: "new-session-launch").map(isEnabled) == true
            }
            let enabledLaunch = try await element(
                identifier: "new-session-launch")
            try requireSemanticControl(
                enabledLaunch, name: "enabled new session launch")
            try await clickUntil(
                enabledLaunch,
                name: "enabled new session launch",
                outcome: "new session start reaches fake CLI") {
                FileManager.default.fileExists(atPath: configuration.root
                    .appendingPathComponent("fake/new-session-started").path)
            }
            let startedID = "detach-claude-ui-new"
            try await waitUntil("new session selection") {
                find(identifier: "session-detail-\(startedID)") != nil
            }
            try await waitUntil("new session embedded terminal", attempts: 80) {
                find(identifier: "session-preview-terminal") != nil
                    && FileManager.default.fileExists(atPath: configuration.root
                        .appendingPathComponent(
                            "fake/new-session-attach-ready").path)
            }
            checks.append("new-session-start-opens-embedded-terminal")
            trace("new session selected and attached inside Detach")

            try Data("empty\n".utf8).write(
                to: configuration.fixtureState, options: .atomic)
            let emptyGuide = try await element(identifier: "empty-sessions-guide")
            try requireGeometry(emptyGuide, name: "empty sessions guide")
            checks.append("empty-dashboard-state")
            trace("empty dashboard visible")

            try Data("error\n".utf8).write(
                to: configuration.fixtureState, options: .atomic)
            checks.append(try await verifyFailurePresentation(in: mainWindow))
            checks.append(contentsOf: try await verifySettings(in: mainWindow))

            try Data("sessions\n".utf8).write(
                to: configuration.fixtureState, options: .atomic)
            try await activate(mainWindow)
            try await keyPress("t", keyCode: 17, modifiers: [.command])
            try await waitUntil("quick chat reaches fake CLI") {
                FileManager.default.fileExists(atPath: configuration.root
                    .appendingPathComponent("fake/quick-chat-started").path)
            }
            try await waitUntil("quick chat selection") {
                find(identifier: "session-detail-detach-codex-ui-quick") != nil
            }
            checks.append("quick-chat-command-starts-session")

            try await restoreFocus(
                to: previousFrontmost, policy: previousActivationPolicy)
            checks.append("installed-app-focus-restored")
            trace("previous application focus restored")
            return Report(
                schema: 1,
                passed: true,
                checks: checks,
                error: nil,
                accessibilityTree: snapshots())
        } catch {
            try? await restoreFocus(
                to: previousFrontmost, policy: previousActivationPolicy)
            return Report(
                schema: 1,
                passed: false,
                checks: checks,
                error: error.localizedDescription,
                accessibilityTree: snapshots())
        }
    }

    private static func verifyFailurePresentation(
        in mainWindow: NSWindow
    ) async throws -> String {
        try await activate(mainWindow)
        let errorStatus = try await element(identifier: "session-status-error")
        guard label(errorStatus)?.isEmpty == false else {
            throw Failure(message: "actionable session failure has no semantics")
        }
        _ = try await measuredFrame(
            identifier: "session-status-error",
            name: "actionable session failure")
        return "actionable-failure-presentation"
    }

    private static func verifySettings(
        in mainWindow: NSWindow
    ) async throws -> [String] {
        var checks: [String] = []
        try await activate(mainWindow)
        try await keyPress(",", keyCode: 43, modifiers: [.command])
        let tipsToggle = try await element(identifier: "settings-show-tips")
        try requireSemanticControl(tipsToggle, name: "settings tips toggle")
        let priorTips = AppSettings.defaults.bool(
            forKey: AppSettings.tipsEnabledKey)
        try await clickUntil(
            tipsToggle,
            name: "settings tips toggle",
            outcome: "settings value persists") {
                AppSettings.defaults.bool(
                    forKey: AppSettings.tipsEnabledKey) != priorTips
            }
        checks.append("settings-change-persists")
        let defaultProjectFolder = try await element(
            identifier: "settings-default-project-folder")
        let quickChatProvider = try await element(
            identifier: "settings-quick-chat-provider")
        let quickChatFolder = try await element(
            identifier: "settings-quick-chat-folder")
        try requireSemanticControl(
            defaultProjectFolder, name: "default project folder")
        try requireSemanticControl(
            quickChatProvider, name: "quick chat provider")
        try requireSemanticControl(
            quickChatFolder, name: "quick chat folder")
        checks.append("settings-session-defaults-visible")
        let codexProvider = try await buttonLabeled("Codex", attempts: 40)
        try await clickUntil(
            codexProvider,
            name: "Codex quick chat provider",
            outcome: "quick chat provider persists") {
                AppSettings.defaults.string(
                    forKey: AppSettings.quickChatProviderKey)
                    == Provider.codex.rawValue
            }
        checks.append("settings-quick-chat-provider-persists")
        _ = try await clickUntilElement(
            quickChatFolder,
            name: "quick chat folder",
            resultIdentifier: "open-panel")
        let openPanels = (NSApp.windows + NSApp.windows.flatMap(\.sheets))
            .compactMap { $0 as? NSOpenPanel }
        guard let openPanel = openPanels.first else {
            throw Failure(message: "quick chat folder panel is not an open panel")
        }
        openPanel.cancel(nil)
        try await waitUntil("quick chat folder panel closes") {
            find(identifier: "open-panel") == nil
                && NSApp.windows.allSatisfy(\.sheets.isEmpty)
        }
        checks.append("settings-quick-chat-folder-panel")
        guard let settingsWindow = UIE2EEventWindowResolver.owner(of: tipsToggle)
        else {
            throw Failure(message: "Settings window is missing")
        }
        guard let visible = settingsWindow.screen?.visibleFrame else {
            throw Failure(message: "Settings window has no hosting screen")
        }
        let frame = settingsWindow.frame
        guard visible.insetBy(dx: -2, dy: -2).contains(frame) else {
            throw Failure(message: "Settings window is off the hosting screen")
        }
        checks.append("settings-window-stays-on-screen")
        let systemTab = try await buttonLabeled(
            L10n.string("System"), attempts: 40)
        try await click(systemTab, name: "System settings tab")
        try await revealGeometry(identifier: "settings-storage", name: "Storage")
        try await revealGeometry(
            identifier: "settings-installation", name: "Installation")
        checks.append("settings-system-reveals-storage-and-installation")
        return checks
    }

    private static func runOnboardingFirstRun(
        configuration: UIE2EConfiguration,
        installation: InstallationStore
    ) async -> Report {
        var checks: [String] = []
        do {
            guard let mainWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "main"
            }) else {
                throw Failure(message: "main test window is missing")
            }
            guard NSApp.setActivationPolicy(.regular) else {
                throw Failure(message: "cannot enable test app activation")
            }
            try await activate(mainWindow)
            _ = try await element(identifier: "onboarding-ready")
            let openDashboard = try await element(
                identifier: "onboarding-open-dashboard")
            try await waitUntil("onboarding dashboard action enabled") {
                isEnabled(openDashboard)
            }
            try requireSemanticControl(
                openDashboard, name: "onboarding dashboard action")
            try await clickUntil(
                openDashboard,
                name: "onboarding dashboard action",
                outcome: "first-run dashboard") {
                    installation.onboardingStep == .mainApp
                        && elements().contains { roleOf($0) == .splitGroup }
                }
            checks.append("onboarding-first-run-completes")
            return Report(
                schema: 1, passed: true, checks: checks, error: nil,
                accessibilityTree: snapshots())
        } catch {
            return Report(
                schema: 1, passed: false, checks: checks,
                error: error.localizedDescription,
                accessibilityTree: snapshots())
        }
    }

    private static func runOnboardingPresentation(
        viewIdentifier: String,
        evidenceIdentifier: String,
        check: String
    ) async -> Report {
        var checks: [String] = []
        do {
            guard let mainWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "main"
            }) else {
                throw Failure(message: "main test window is missing")
            }
            guard NSApp.setActivationPolicy(.regular) else {
                throw Failure(message: "cannot enable test app activation")
            }
            try await activate(mainWindow)
            let view = try await element(identifier: viewIdentifier)
            let evidence = try await element(identifier: evidenceIdentifier)
            try requireGeometry(view, name: viewIdentifier)
            try requireSemanticControl(evidence, name: evidenceIdentifier)
            checks.append(check)
            return Report(
                schema: 1, passed: true, checks: checks, error: nil,
                accessibilityTree: snapshots())
        } catch {
            return Report(
                schema: 1, passed: false, checks: checks,
                error: error.localizedDescription,
                accessibilityTree: snapshots())
        }
    }

    private static func trace(_ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - scenarioStartedAt
        FileHandle.standardError.write(Data(String(
            format: "UI e2e: +%.3fs %@\n", elapsed, message).utf8))
    }

    private static func captureGeneralPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private static func restoreGeneralPasteboard(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]]
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.map { payload in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func buttonLabeled(
        _ name: String,
        attempts: Int = 200
    ) async throws -> any NSAccessibilityProtocol {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("button \(name)", attempts: attempts) {
            result = elements().first { element in
                label(element) == name
                    && (roleOf(element) == .button
                        || roleOf(element) == .radioButton
                        || roleOf(element) == .checkBox)
            }
            return result != nil
        }
        return result!
    }

    private static func restoreFocus(
        to application: NSRunningApplication?,
        policy: NSApplication.ActivationPolicy
    ) async throws {
        if let application, !application.isTerminated {
            application.activate()
        } else {
            NSApp.hide(nil)
        }
        try await waitUntil("previous application focus restoration") {
            !NSApp.isActive
        }
        guard NSApp.setActivationPolicy(policy) else {
            throw Failure(message: "cannot restore test app activation policy")
        }
    }

    private static func element(identifier: String) async throws
        -> any NSAccessibilityProtocol
    {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("accessibility element \(identifier)") {
            result = find(identifier: identifier)
            return result != nil
        }
        return result!
    }

    private static func element(role: NSAccessibility.Role) async throws
        -> any NSAccessibilityProtocol
    {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("accessibility role \(role.rawValue)") {
            result = elements().first { roleOf($0) == role }
            return result != nil
        }
        return result!
    }

    private static func sheetButton(
        label: String,
        attempts: Int = 200
    ) async throws
        -> any NSAccessibilityProtocol
    {
        var result: (any NSAccessibilityProtocol)?
        try await waitUntil("sheet button \(label)", attempts: attempts) {
            let sheetFrames = NSApp.windows.flatMap(\.sheets).map(\.frame)
            result = elements().first { element in
                roleOf(element) == .button
                    && Self.label(element) == label
                    && sheetFrames.contains(where: { $0.contains(
                        CGPoint(x: frame(element).midX, y: frame(element).midY)) })
            }
            return result != nil
        }
        return result!
    }

    private static func clickUntilSheetButton(
        _ control: any NSAccessibilityProtocol,
        name: String,
        label: String
    ) async throws -> any NSAccessibilityProtocol {
        for _ in 0..<3 {
            try await click(control, name: name)
            do {
                return try await sheetButton(label: label, attempts: 20)
            } catch {
                continue
            }
        }
        throw Failure(message: "\(name) did not present \(label) confirmation")
    }

    private static func waitUntil(
        _ description: String,
        attempts: Int = 200,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            guard ProcessInfo.processInfo.systemUptime < scenarioDeadline else {
                throw Failure(
                    message: "scenario budget expired while waiting for \(description)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure(message: "timed out waiting for \(description)")
    }

    private static func requireGeometry(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) throws {
        let frame = frame(element)
        guard frame.width > 0, frame.height > 0 else {
            throw Failure(message: "\(name) has empty accessibility geometry")
        }
    }

    private static func requireSemanticControl(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) throws {
        try requireGeometry(element, name: name)
        guard isEnabled(element) else {
            throw Failure(message: "\(name) is disabled")
        }
        let label = label(element)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard label?.isEmpty == false else {
            throw Failure(message: "\(name) has no accessibility label")
        }
    }

    private static func click(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) async throws {
        var targetFrame = frame(element)
        let owningWindow = UIE2EEventWindowResolver.owner(of: element)
        if let identifier = identifierOf(element),
           usesMeasuredGeometry(identifier) {
            try await waitUntil("real control geometry for \(name)") {
                elements().compactMap { $0 as? UIE2EGeometryView }.first {
                    $0.identifierValue == identifier
                }?.publishFrame()
                guard let measured = UIE2EGeometryRegistry.frame(for: identifier) else {
                    return false
                }
                targetFrame = measured
                return !measured.isEmpty
            }
            if identifier == "onboarding-open-dashboard" {
                try await revealMeasuredControl(
                    element,
                    identifier: identifier,
                    name: name)
                guard let measured = UIE2EGeometryRegistry.frame(for: identifier)
                else {
                    throw Failure(message: "\(name) lost its measured geometry")
                }
                targetFrame = measured
            }
        }
        try await click(
            frame: targetFrame,
            name: name,
            owningWindow: owningWindow)
    }

    private static func usesMeasuredGeometry(_ identifier: String) -> Bool {
        identifier == "new-session-button"
            || identifier == "settings-show-tips"
            || identifier.hasPrefix("settings-default-project-")
            || identifier.hasPrefix("settings-quick-chat-")
            || identifier.hasPrefix("new-session-")
            || identifier.hasPrefix("onboarding-")
            || identifier.hasPrefix("finished-")
            || identifier.hasPrefix("session-row-")
            || identifier.hasPrefix("session-action-")
    }

    private static func revealMeasuredControl(
        _ element: any NSAccessibilityProtocol,
        identifier: String,
        name: String
    ) async throws {
        let measuredView = (element as? UIE2EGeometryView)
            ?? elements().compactMap { $0 as? UIE2EGeometryView }.first {
                $0.accessibilityIdentifier() == identifier
            }
        guard let measuredView else {
            throw Failure(message: "\(name) has no measured control view")
        }
        for _ in 0..<3 {
            measuredView.publishFrame()
            guard let current = UIE2EGeometryRegistry.frame(for: identifier)
            else {
                throw Failure(message: "\(name) lost its measured geometry")
            }
            if UIE2EEventWindowResolver.isSafelyVisible(
                current,
                from: measuredView) {
                return
            }
            guard let pageFrame = UIE2EEventWindowResolver.scrollPageFrame(
                toward: current,
                from: measuredView)
            else {
                throw Failure(message: "\(name) has no visible scroll target")
            }
            try await click(
                frame: pageFrame,
                name: "scroll toward \(name)",
                owningWindow: measuredView.window)
            do {
                try await waitUntil("visible \(name)", attempts: 4) {
                    measuredView.publishFrame()
                    guard let moved = UIE2EGeometryRegistry.frame(for: identifier)
                    else { return false }
                    return moved != current
                }
            } catch {
                // Overlay scrollers can expose page geometry while ignoring a
                // synthesized click until a physical scroll makes the track
                // visible. Reveal only the measured semantic control, then
                // keep the actual action on the real button below.
                measuredView.scrollToVisible(measuredView.bounds)
                if let scrollView = measuredView.enclosingScrollView {
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
                try await waitUntil("fallback reveal for \(name)", attempts: 20) {
                    measuredView.publishFrame()
                    guard let moved = UIE2EGeometryRegistry.frame(for: identifier)
                    else { return false }
                    return moved != current
                }
            }
        }
        measuredView.publishFrame()
        guard let final = UIE2EGeometryRegistry.frame(for: identifier),
              UIE2EEventWindowResolver.isSafelyVisible(
                final,
                from: measuredView)
        else {
            throw Failure(message: "\(name) remains outside its scroll viewport")
        }
    }

    private static func clickUntilElement(
        _ control: any NSAccessibilityProtocol,
        name: String,
        resultIdentifier: String
    ) async throws -> any NSAccessibilityProtocol {
        var result: (any NSAccessibilityProtocol)?
        for _ in 0..<3 {
            try await click(control, name: name)
            do {
                try await waitUntil(
                    "accessibility element \(resultIdentifier)", attempts: 20
                ) {
                    result = find(identifier: resultIdentifier)
                    return result != nil
                }
                return result!
            } catch {
                continue
            }
        }
        throw Failure(message: "\(name) did not produce \(resultIdentifier)")
    }

    private static func clickUntil(
        _ control: any NSAccessibilityProtocol,
        name: String,
        outcome: String,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<3 {
            try await click(control, name: name)
            do {
                try await waitUntil(outcome, attempts: 20, condition: condition)
                return
            } catch {
                continue
            }
        }
        throw Failure(message: "\(name) did not produce \(outcome)")
    }

    private static func clickMeasuredControl(
        identifier: String,
        name: String,
        offset: CGSize = .zero,
        size: CGSize? = nil
    ) async throws {
        var target: UIE2EGeometryView?
        try await waitUntil("measured control \(name)") {
            target = elements().compactMap { $0 as? UIE2EGeometryView }.first {
                $0.identifierValue == identifier
            }
            target?.publishFrame()
            return target.map { $0.window != nil && !$0.bounds.isEmpty } == true
        }
        guard let view = target, let window = view.window else {
            throw Failure(message: "\(name) has no measured control view")
        }
        view.publishFrame()
        guard var screen = UIE2EGeometryRegistry.frame(for: identifier),
              !screen.isEmpty else {
            throw Failure(message: "\(name) has no published geometry")
        }
        if let size {
            screen = CGRect(
                x: screen.minX + offset.width,
                y: screen.minY + offset.height - (size.height - screen.height) / 2,
                width: size.width,
                height: size.height)
        } else if offset != .zero {
            screen = screen.offsetBy(dx: offset.width, dy: offset.height)
        }
        try await click(frame: screen, name: name, owningWindow: window)
    }

    private static func clickMeasuredUntil(
        identifier: String,
        name: String,
        outcome: String,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<3 {
            try await clickMeasuredControl(identifier: identifier, name: name)
            do {
                try await waitUntil(outcome, attempts: 20, condition: condition)
                return
            } catch {
                continue
            }
        }
        throw Failure(message: "\(name) did not produce \(outcome)")
    }

    private static func revealGeometry(
        identifier: String,
        name: String
    ) async throws {
        var view: UIE2EGeometryView?
        try await waitUntil("\(name) geometry", attempts: 40) {
            view = elements().compactMap { $0 as? UIE2EGeometryView }.first {
                $0.identifierValue == identifier
            }
            view?.publishFrame()
            return view.map { $0.window != nil && !$0.bounds.isEmpty } == true
        }
        try await revealMeasuredControl(view!, identifier: identifier, name: name)
    }

    private static func measuredFrame(
        identifier: String,
        name: String
    ) async throws -> CGRect {
        var result: CGRect?
        try await waitUntil("real control geometry for \(name)") {
            result = UIE2EGeometryRegistry.frame(for: identifier)
            return result?.isEmpty == false
        }
        if identifier.hasPrefix("new-session-"),
           let sheet = NSApp.windows.flatMap(\.sheets).first,
           let localFrame = result,
           !sheet.frame.contains(CGPoint(
               x: localFrame.midX, y: localFrame.midY)) {
            result = CGRect(
                x: sheet.frame.minX + localFrame.minX,
                y: sheet.frame.minY + localFrame.minY,
                width: localFrame.width,
                height: localFrame.height)
        }
        trace("measured \(name): \(result!)")
        return result!
    }

    private static func click(
        frame targetFrame: CGRect,
        name: String,
        owningWindow: NSWindow? = nil
    ) async throws {
        let screenPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let candidateWindows = NSApp.windows.flatMap(\.sheets) + NSApp.windows
        guard let window = UIE2EEventWindowResolver.resolve(
            owningWindow: owningWindow,
            at: screenPoint,
            candidates: candidateWindows)
        else {
            let scope = owningWindow == nil
                ? "every visible test window"
                : "its owning window"
            throw Failure(message: "\(name) is outside \(scope)")
        }
        let windowName = window.identifier?.rawValue ?? window.title
        trace(
            "clicking \(name) at \(screenPoint.x),\(screenPoint.y) "
                + "in window \(windowName)")
        try moveCursor(to: screenPoint, name: name)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if let contentView = window.contentView {
            let contentPoint = contentView.convert(windowPoint, from: nil)
            var view = contentView.hitTest(contentPoint)
            var names: [String] = []
            while let current = view {
                names.append(String(describing: type(of: current)))
                view = current.superview
            }
            trace("hit chain for \(name): \(names.joined(separator: " > "))")
        }
        var events: [NSEvent] = []
        let timestamp = ProcessInfo.processInfo.systemUptime
        let clickInterval: TimeInterval = 0.03
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let eventNumber = nextMouseEventNumber
            nextMouseEventNumber += 1
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: timestamp + Double(events.count) * clickInterval,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            events.append(event)
        }
        guard events.count == 2 else {
            throw Failure(message: "cannot create mouse pair for \(name)")
        }
        // AppKit permits postEvent from a subthread. Delay mouseUp so SwiftUI
        // receives a physical-duration click even inside a tracking loop. Put
        // mouseUp at the queue tail so a busy main thread cannot process it
        // before the mouseDown event at the queue head.
        let mouseUp = UIE2EDeferredMouseUp(application: NSApp, event: events[1])
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + clickInterval
        ) {
            mouseUp.post()
        }
        NSApp.postEvent(events[0], atStart: true)
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    private static func moveCursor(
        to screenPoint: CGPoint,
        name: String
    ) throws {
        guard cursorRestorePoint != nil else {
            throw Failure(message: "cannot preserve pointer position for \(name)")
        }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(screenPoint)
        }),
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
        else {
            throw Failure(message: "cannot resolve the display for \(name)")
        }
        let quartzPoint = UIE2ECursorPositionResolver.quartzPoint(
            for: screenPoint,
            screenFrame: screen.frame,
            displayBounds: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value)))
        guard CGWarpMouseCursorPosition(quartzPoint) == .success else {
            throw Failure(message: "cannot position the pointer for \(name)")
        }
    }

    private static func keyPress(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode)
            else { throw Failure(message: "cannot create settings keyboard event") }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private static func activate(_ mainWindow: NSWindow) async throws {
        try await waitUntil("test app activation") {
            if NSApp.isActive && mainWindow.isKeyWindow { return true }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return false
        }
    }

    private static func find(identifier: String) -> (any NSAccessibilityProtocol)? {
        elements().first { identifierOf($0) == identifier }
    }

    private static func elements() -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var roots: [any NSAccessibilityProtocol] = []
        let mainWindows = NSApp.windows.filter {
            $0.isVisible && $0.level == .normal
        }
        for window in mainWindows {
            roots.append(window)
            if let contentView = window.contentView { roots.append(contentView) }
        }
        roots.append(contentsOf: mainWindows.flatMap(\.sheets).map { $0 })
        var queue = roots.map { ($0, 0) }
        var visited: Set<ObjectIdentifier> = []
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            let identifier = ObjectIdentifier(element as AnyObject)
            guard visited.insert(identifier).inserted else { continue }
            result.append(element)
            guard depth < 20 else { continue }
            var children: [Any] = []
            children.append(contentsOf: element.accessibilityWindows() ?? [])
            children.append(contentsOf: element.accessibilityChildren() ?? [])
            children.append(contentsOf: element.accessibilityVisibleChildren() ?? [])
            children.append(contentsOf: element.accessibilityContents() ?? [])
            children.append(contentsOf: element.accessibilityRows() ?? [])
            children.append(contentsOf: element.accessibilityVisibleRows() ?? [])
            if let view = element as? NSView {
                children.append(contentsOf: view.subviews)
            }
            if let window = element as? NSWindow,
               let contentView = window.contentView {
                children.append(contentView)
            }
            for child in children.compactMap({ $0 as? any NSAccessibilityProtocol }) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    private static func snapshots() -> [ElementSnapshot] {
        elements().map { element in
            let elementFrame = frame(element)
            return ElementSnapshot(
                role: roleOf(element)?.rawValue ?? "",
                identifier: identifierOf(element),
                label: label(element),
                value: value(element)
                    .map { String(describing: $0) },
                frame: "\(elementFrame.origin.x),\(elementFrame.origin.y),\(elementFrame.width),\(elementFrame.height)",
                enabled: isEnabled(element))
        }
    }

    private static func isEnabled(_ element: any NSAccessibilityProtocol) -> Bool {
        element.isAccessibilityEnabled()
    }

    private static func frame(_ element: any NSAccessibilityProtocol) -> CGRect {
        element.accessibilityFrame()
    }

    private static func roleOf(
        _ element: any NSAccessibilityProtocol
    ) -> NSAccessibility.Role? {
        element.accessibilityRole()
    }

    private static func identifierOf(
        _ element: any NSAccessibilityProtocol
    ) -> String? {
        element.accessibilityIdentifier()
    }

    private static func label(
        _ element: any NSAccessibilityProtocol
    ) -> String? {
        element.accessibilityLabel()
    }

    private static func value(
        _ element: any NSAccessibilityProtocol
    ) -> Any? {
        element.accessibilityValue()
    }

    private static func write(_ report: Report, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
