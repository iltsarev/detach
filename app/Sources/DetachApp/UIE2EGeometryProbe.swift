import AppKit
import SwiftUI

/// Captures the screen frame of a real SwiftUI control for the hermetic UI
/// driver. The probe receives no actions and is dormant outside UI e2e.
@MainActor
enum UIE2EGeometryRegistry {
    private static var frames: [String: CGRect] = [:]

    static func set(_ frame: CGRect, for identifier: String) {
        frames[identifier] = frame
    }

    static func frame(for identifier: String) -> CGRect? {
        frames[identifier]
    }
}

@MainActor
struct UIE2EGeometryProbe: NSViewRepresentable {
    let identifier: String
    let semanticLabel: String?
    let semanticRole: NSAccessibility.Role?
    let semanticEnabled: Bool

    init(
        identifier: String,
        semanticLabel: String? = nil,
        semanticRole: NSAccessibility.Role? = nil,
        semanticEnabled: Bool = true
    ) {
        self.identifier = identifier
        self.semanticLabel = semanticLabel
        self.semanticRole = semanticRole
        self.semanticEnabled = semanticEnabled
    }

    func makeNSView(context: Context) -> UIE2EGeometryView {
        UIE2EGeometryView(
            identifier: identifier,
            semanticLabel: semanticLabel,
            semanticRole: semanticRole,
            semanticEnabled: semanticEnabled)
    }

    func updateNSView(_ view: UIE2EGeometryView, context: Context) {
        view.identifierValue = identifier
        view.semanticLabel = semanticLabel
        view.semanticRole = semanticRole
        view.semanticEnabled = semanticEnabled
        view.publishFrame()
    }
}

@MainActor
final class UIE2EGeometryView: NSView {
    var identifierValue: String
    var semanticLabel: String?
    var semanticRole: NSAccessibility.Role?
    var semanticEnabled: Bool

    init(
        identifier: String,
        semanticLabel: String?,
        semanticRole: NSAccessibility.Role?,
        semanticEnabled: Bool
    ) {
        identifierValue = identifier
        self.semanticLabel = semanticLabel
        self.semanticRole = semanticRole
        self.semanticEnabled = semanticEnabled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { semanticRole != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { semanticRole }
    override func accessibilityIdentifier() -> String {
        semanticRole == nil ? "" : identifierValue
    }
    override func accessibilityLabel() -> String? { semanticLabel }
    override func accessibilityFrame() -> NSRect {
        publishFrame()
        return UIE2EGeometryRegistry.frame(for: identifierValue) ?? .zero
    }
    override func isAccessibilityEnabled() -> Bool { semanticEnabled }

    override func layout() {
        super.layout()
        publishFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishFrame()
    }

    func publishFrame() {
        guard AppSettings.uiE2E != nil, let window, !bounds.isEmpty else { return }
        let windowFrame = convert(bounds, to: nil)
        let screenFrame: CGRect
        if window.sheetParent != nil {
            screenFrame = CGRect(
                x: window.frame.minX + windowFrame.minX,
                y: window.frame.minY + windowFrame.minY,
                width: windowFrame.width,
                height: windowFrame.height)
        } else {
            screenFrame = window.convertToScreen(windowFrame)
        }
        UIE2EGeometryRegistry.set(
            screenFrame, for: identifierValue)
    }
}
