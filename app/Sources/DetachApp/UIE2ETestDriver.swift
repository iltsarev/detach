import AppKit
import Darwin
import Foundation

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

    static func runIfRequested() async {
        guard let configuration = AppSettings.uiE2E, !started else { return }
        started = true
        let report = await runScenario(configuration: configuration)
        try? write(report, to: configuration.result)
        NSApp.terminate(nil)
        // A SwiftUI sheet can defer normal termination even after it is
        // dismissed. The validated test copy owns no durable state, so keep
        // the harness bounded after the atomic report is safely on disk.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            _exit(EXIT_SUCCESS)
        }
    }

    private static func runScenario(
        configuration: UIE2EConfiguration
    ) async -> Report {
        var checks: [String] = []
        do {
            guard !NSApp.isActive else {
                throw Failure(message: "background test app stole keyboard focus")
            }

            let dashboard = try await element(role: .splitGroup)
            try requireGeometry(dashboard, name: "dashboard")
            checks.append("dashboard-accessible")

            let completedID = "detach-claude-ui-completed"
            let completedRow = try await element(
                identifier: "session-row-\(completedID)")
            try requireSemanticControl(completedRow, name: "completed session row")
            try press(completedRow, name: "completed session row")
            let completedDetail = try await element(
                identifier: "session-detail-\(completedID)")
            try requireGeometry(completedDetail, name: "completed session detail")
            let deleteButton = try await element(identifier: "session-action-delete")
            try requireSemanticControl(deleteButton, name: "delete action")
            checks.append("sidebar-selects-completed-session")

            try press(deleteButton, name: "delete action")
            try await waitUntil("fake CLI records delete action") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains(
                    "claude delete --force \(completedID)") == true
            }
            checks.append("safe-delete-reaches-fake-cli")

            let runningID = "detach-codex-ui-running"
            let runningRow = try await element(
                identifier: "session-row-\(runningID)")
            try requireSemanticControl(runningRow, name: "running session row")
            try press(runningRow, name: "running session row")
            _ = try await element(identifier: "session-detail-\(runningID)")
            let stopButton = try await element(identifier: "session-action-stop")
            try requireSemanticControl(stopButton, name: "stop action")
            try press(stopButton, name: "stop action")
            try await waitUntil("fake CLI records stop action") {
                let actions = try? String(
                    contentsOf: configuration.root
                        .appendingPathComponent("fake/actions.log"),
                    encoding: .utf8)
                return actions?.contains("codex stop \(runningID)") == true
            }
            checks.append("safe-action-reaches-fake-cli")

            let newSession = try await element(identifier: "new-session-button")
            try requireSemanticControl(newSession, name: "new session action")
            try press(newSession, name: "new session action")
            let sheet = try await element(identifier: "new-session-sheet")
            try requireGeometry(sheet, name: "new session sheet")
            let launch = try await element(identifier: "new-session-launch")
            guard !isEnabled(launch) else {
                throw Failure(message: "new-session launch enabled without a project")
            }
            let cancel = try await element(identifier: "new-session-cancel")
            try requireSemanticControl(cancel, name: "new session cancel")
            try press(cancel, name: "new session cancel")
            try await waitUntil("new-session sheet closes") {
                find(identifier: "new-session-sheet") == nil
            }
            checks.append("new-session-sheet-semantics")

            try Data("empty\n".utf8).write(
                to: configuration.fixtureState, options: .atomic)
            let emptyGuide = try await element(identifier: "empty-sessions-guide")
            try requireGeometry(emptyGuide, name: "empty sessions guide")
            checks.append("empty-dashboard-state")

            guard !NSApp.isActive else {
                throw Failure(message: "accessibility actions stole keyboard focus")
            }
            checks.append("installed-app-focus-undisturbed")
            return Report(
                schema: 1,
                passed: true,
                checks: checks,
                error: nil,
                accessibilityTree: snapshots())
        } catch {
            return Report(
                schema: 1,
                passed: false,
                checks: checks,
                error: error.localizedDescription,
                accessibilityTree: snapshots())
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

    private static func waitUntil(
        _ description: String,
        attempts: Int = 100,
        condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
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

    private static func press(
        _ element: any NSAccessibilityProtocol,
        name: String
    ) throws {
        guard element.accessibilityPerformPress() else {
            throw Failure(message: "\(name) has no working accessibility press action")
        }
    }

    private static func find(identifier: String) -> (any NSAccessibilityProtocol)? {
        elements().first { identifierOf($0) == identifier }
    }

    private static func elements() -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var roots: [any NSAccessibilityProtocol] = []
        let mainWindows = NSApp.windows.filter {
            $0.identifier?.rawValue == "main" || $0.title == "Detach"
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
            var children = (element.accessibilityWindows() ?? [])
                + (element.accessibilityChildren() ?? [])
                + (element.accessibilityVisibleChildren() ?? [])
                + (element.accessibilityContents() ?? [])
                + (element.accessibilityRows() ?? [])
                + (element.accessibilityVisibleRows() ?? [])
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
