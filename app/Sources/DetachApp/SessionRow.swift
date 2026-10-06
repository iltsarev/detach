import AppKit
import SwiftUI
import DetachKit

enum SessionRowPresentation {
    static func symbol(for session: Session) -> String {
        switch session.effectiveStatus {
        case .starting: "arrow.up.circle"
        case .recovering: "arrow.clockwise"
        case .hung: "hourglass"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .interrupted: "pause.fill"
        case .stopped: "stop.fill"
        case .recoverable: "arrow.counterclockwise.circle"
        case .orphaned: "link"
        case .corrupt: "exclamationmark.triangle"
        case .collision: "square.on.square"
        case .unknown: "ellipsis.circle"
        case .running:
            switch session.agentTurnState {
            case .working: "circle.dotted"
            case .interrupted: "pause.fill"
            case .unknown, nil: "ellipsis.circle"
            case .waiting:
                switch session.agentWaitingReason {
                case .answerReady: "checkmark"
                case .inputRequired: "text.bubble"
                case .unknown, nil: "clock"
                }
            }
        }
    }

    static func status(for session: Session) -> String {
        session.statusSignal == .unknown ? L10n.string("status unavailable") : session.displayStatus
    }

    static func background(for session: Session, selected: Bool, isFresh: Bool) -> Color? {
        guard isFresh else { return selected ? .primary.opacity(0.10) : nil }
        switch session.statusSignal {
        case .ready where session.effectiveStatus != .completed:
            return SessionPalette.ready.opacity(selected ? 0.16 : 0.06)
        case .inputRequired:
            return SessionPalette.attention.opacity(selected ? 0.18 : 0.07)
        case .error:
            return SessionPalette.error.opacity(selected ? 0.16 : 0.06)
        default:
            return selected ? .primary.opacity(0.10) : nil
        }
    }

    static func shouldAnimate(signal: SessionStatusSignal, isFresh: Bool,
                              isVisible: Bool, isActive: Bool, reduceMotion: Bool) -> Bool {
        signal == .working && isFresh && isVisible && isActive && !reduceMotion
    }

    static func help(for session: Session, isFresh: Bool = true) -> String {
        var parts = [session.displayTitle, session.provider.rawValue,
                     isFresh ? status(for: session) : L10n.string("last known status")]
        if session.name != session.displayTitle { parts.append(session.name) }
        if let exit = session.exitStatus { parts.append(L10n.format("exit %d", exit)) }
        if let created = session.createdAt {
            parts.append(L10n.format("Started %@", created.formatted(date: .abbreviated, time: .shortened)))
        }
        return parts.joined(separator: " · ")
    }
}

struct SessionRow: View {
    let session: Session
    let shortcutSlot: Int?
    var isFresh = true

    var body: some View {
        HStack(spacing: 10) {
            SessionStatusMark(session: session, isFresh: isFresh)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.displayTitle)
                        .appFont(.body, weight: .medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcutSlot {
                        Text(SessionShortcutPresentation.badge(slot: shortcutSlot))
                            .appFont(.caption, weight: .medium, design: .monospaced)
                            .foregroundStyle(SessionPalette.secondary)
                            .fixedSize()
                            .accessibilityHidden(true)
                            .help(L10n.format("Switch to %@ with Command-%d", session.displayTitle, shortcutSlot))
                            .uiE2EGeometryProbe(
                                "session-shortcut-\(session.id)",
                                label: "Command-\(shortcutSlot)",
                                role: .staticText)
                    }
                }
                HStack(spacing: 8) {
                    Text(isFresh ? SessionRowPresentation.status(for: session) : L10n.string("last known status"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(session.provider.rawValue).fixedSize()
                }
                .appFont(.caption)
                .foregroundStyle(SessionPalette.secondary)
            }
            .foregroundStyle(SidebarSection.containing(session) == .stopped
                ? SessionPalette.secondary : Color.primary)
        }
        .padding(.vertical, SidebarSection.containing(session) == .stopped ? 1 : 3)
        .background(SidebarSelectionStyle())
        .help(SessionRowPresentation.help(for: session, isFresh: isFresh))
        .accessibilityValue(SessionRowPresentation.help(for: session, isFresh: isFresh))
    }
}

private struct SessionStatusMark: View {
    let session: Session
    let isFresh: Bool
    @Environment(\.appFontPointSize) private var fontPointSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var rotating = false

    private var shouldAnimate: Bool {
        session.effectiveStatus == .running && SessionRowPresentation.shouldAnimate(signal: session.statusSignal, isFresh: isFresh,
            isVisible: isVisible, isActive: scenePhase == .active, reduceMotion: reduceMotion)
    }

    var body: some View {
        Group {
            if isFresh && session.effectiveStatus == .running && session.statusSignal == .working {
                Circle().trim(from: 0, to: 0.72)
                    .stroke(SessionPalette.attention, style: StrokeStyle(lineWidth: max(1.5, fontPointSize / 9), lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(shouldAnimate ? .linear(duration: 1.8).repeatForever(autoreverses: false) : nil,
                               value: rotating)
            } else {
                Image(systemName: isFresh ? SessionRowPresentation.symbol(for: session) : "ellipsis.circle")
                    .appFont(.caption, weight: .medium)
                    .foregroundStyle(isFresh ? SessionIdentity.statusColor(for: session) : SessionPalette.secondary)
                    .scaleEffect(session.statusSignal == .stopped ? 0.6 : 1)
            }
        }
        .frame(width: max(12, fontPointSize * 0.9), height: max(12, fontPointSize * 0.9))
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: shouldAnimate, initial: true) { _, value in rotating = value }
    }
}

/// Keep native List selection and keyboard navigation, but draw its visual
/// state once in the row background instead of mixing a gray native overlay.
private struct SidebarSelectionStyle: NSViewRepresentable {
    final class Marker: NSView {
        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                ancestor = view.superview
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.apply() }
}

struct SessionRowBackground: View {
    let session: Session
    let selected: Bool
    let isFresh: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(SessionRowPresentation.background(for: session, selected: selected, isFresh: isFresh) ?? .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SessionPalette.secondary.opacity(selected ? 0.3 : 0), lineWidth: 1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
    }
}
