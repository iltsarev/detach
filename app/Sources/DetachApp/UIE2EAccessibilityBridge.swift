import AppKit
import DetachKit
import SwiftUI

/// Test-only accessibility elements for SwiftUI's virtual List rows. AppKit's
/// in-process protocol omits identifiers for those rows even though external
/// assistive clients receive them. This zero-size bridge mirrors the same
/// session state and actions so the hermetic in-process driver can exercise
/// labeled AX press semantics without a TCC-authorized second executable.
@MainActor
struct UIE2EAccessibilityBridge: NSViewRepresentable {
    let store: SessionStore
    @Binding var selectedID: String?
    @ObservedObject var navigation: MainNavigation

    func makeNSView(context: Context) -> UIE2EBridgeView {
        UIE2EBridgeView()
    }

    func updateNSView(_ view: UIE2EBridgeView, context: Context) {
        guard AppSettings.uiE2E != nil else {
            view.elements = []
            return
        }
        let sessions = store.sessions
        let selected = sessions.first { $0.id == selectedID }
        view.rebuild(
            sessions: sessions,
            state: store.state,
            selected: selected,
            select: { selectedID = $0 },
            newSession: { navigation.requestsNewSession = true },
            perform: { action, session in
                Task { _ = await store.perform(action, on: session) }
            })
    }
}

@MainActor
final class UIE2EBridgeView: NSView {
    var elements: [Any] = [] {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { elements }

    func rebuild(
        sessions: [Session],
        state: SessionStore.State,
        selected: Session?,
        select: @escaping (String) -> Void,
        newSession: @escaping () -> Void,
        perform: @escaping (SessionAction, Session) -> Void
    ) {
        guard let window else { return }
        let frame = window.frame
        let sidebarWidth = min(288, frame.width * 0.4)
        let rowWidth = max(1, sidebarWidth - 24)
        var next: [Any] = []

        next.append(UIE2EAXElement(
            parent: self,
            role: .button,
            identifier: "new-session-button",
            label: "New session",
            frame: NSRect(x: frame.minX + sidebarWidth - 80,
                          y: frame.maxY - 52, width: 44, height: 36),
            action: { [weak self] in
                newSession()
                self?.scheduleSheetControls(for: window)
            }))

        for (index, session) in sessions.enumerated() {
            next.append(UIE2EAXElement(
                parent: self,
                role: .button,
                identifier: "session-row-\(session.id)",
                label: session.displayTitle,
                frame: NSRect(x: frame.minX + 12,
                              y: frame.maxY - 100 - CGFloat(index * 64),
                              width: rowWidth, height: 46),
                action: { select(session.id) }))
        }

        if let selected {
            next.append(UIE2EAXElement(
                parent: self,
                role: .group,
                identifier: "session-detail-\(selected.id)",
                label: selected.displayTitle,
                frame: NSRect(x: frame.minX + sidebarWidth,
                              y: frame.minY,
                              width: frame.width - sidebarWidth,
                              height: frame.height)))
            if let action = selected.healthActions?.contains(.stop) == true
                ? SessionAction.stop
                : (selected.healthActions?.contains(.delete) == true ? .delete : nil) {
                next.append(UIE2EAXElement(
                    parent: self,
                    role: .button,
                    identifier: "session-action-\(action.rawValue)",
                    label: action == .stop ? "Stop" : "Delete",
                    frame: NSRect(x: frame.maxX - 100,
                                  y: frame.minY + 16, width: 80, height: 32),
                    action: { perform(action, selected) }))
            }
        }

        if sessions.isEmpty, state == .ok {
            next.append(UIE2EAXElement(
                parent: self,
                role: .group,
                identifier: "empty-sessions-guide",
                label: "No sessions yet",
                frame: NSRect(x: frame.minX + sidebarWidth,
                              y: frame.minY,
                              width: frame.width - sidebarWidth,
                              height: frame.height)))
        }

        elements = next
        if window.attachedSheet != nil { installSheetControls(for: window) }
    }

    private func scheduleSheetControls(for window: NSWindow) {
        Task { @MainActor [weak self, weak window] in
            for _ in 0..<20 {
                guard let self, let window else { return }
                if window.attachedSheet != nil {
                    self.installSheetControls(for: window)
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func installSheetControls(for window: NSWindow) {
        guard let sheet = window.attachedSheet,
              !elements.contains(where: {
                  ($0 as? UIE2EAXElement)?.identifierValue == "new-session-sheet"
              }) else { return }
        let sheetFrame = sheet.frame
        elements.append(contentsOf: [
            UIE2EAXElement(
                parent: self,
                role: .group,
                identifier: "new-session-sheet",
                label: "New session",
                frame: sheetFrame),
            UIE2EAXElement(
                parent: self,
                role: .button,
                identifier: "new-session-launch",
                label: "Launch in Terminal",
                frame: NSRect(x: sheetFrame.maxX - 180,
                              y: sheetFrame.minY + 16, width: 160, height: 32),
                enabled: false),
            UIE2EAXElement(
                parent: self,
                role: .button,
                identifier: "new-session-cancel",
                label: "Cancel",
                frame: NSRect(x: sheetFrame.maxX - 270,
                              y: sheetFrame.minY + 16, width: 80, height: 32),
                action: { [weak self, weak sheet] in
                    guard let sheet else { return }
                    sheet.sheetParent?.endSheet(sheet)
                    self?.elements.removeAll {
                        ($0 as? UIE2EAXElement)?.identifierValue.hasPrefix(
                            "new-session-") == true
                    }
                }),
        ])
    }
}

@MainActor
final class UIE2EAXElement: NSAccessibilityElement {
    private let storedRole: NSAccessibility.Role
    private let storedIdentifier: String
    private let storedLabel: String
    private let storedFrame: NSRect
    private let storedEnabled: Bool
    private let action: (() -> Void)?
    let identifierValue: String

    init(
        parent: Any,
        role: NSAccessibility.Role,
        identifier: String,
        label: String,
        frame: NSRect,
        enabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        storedRole = role
        storedIdentifier = identifier
        identifierValue = identifier
        storedLabel = label
        storedFrame = frame
        storedEnabled = enabled
        self.action = action
        super.init()
        setAccessibilityParent(parent)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { storedRole }
    override func accessibilityIdentifier() -> String? { storedIdentifier }
    override func accessibilityLabel() -> String? { storedLabel }
    override func accessibilityFrame() -> NSRect { storedFrame }
    override func isAccessibilityEnabled() -> Bool { storedEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        action()
        return true
    }
}
