import AppKit
import SwiftUI
import DetachKit

enum SessionRowPresentation {
    static func symbol(for session: Session, isFresh: Bool = true) -> String {
        guard isFresh else { return "clock.arrow.circlepath" }
        return switch session.effectiveStatus {
        case .starting, .recovering: "circle.dotted"
        case .hung: "hourglass"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .interrupted: "pause.circle"
        case .stopped: "stop.circle"
        case .recoverable: "arrow.counterclockwise"
        case .orphaned: "link"
        case .corrupt: "exclamationmark.triangle"
        case .collision: "square.on.square"
        case .unknown: "minus.circle"
        case .running:
            switch session.agentTurnState {
            case .working: "circle.dotted"
            case .interrupted: "pause.circle"
            case nil where !session.hasTranscriptEvidence: "circle"
            case .unknown, nil: "minus.circle"
            case .waiting:
                switch session.agentWaitingReason {
                case .answerReady: "checkmark.circle"
                case .inputRequired: "exclamationmark.circle"
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

    /// Live rows name their provider. A stopped row shows when it stopped; its
    /// provider stays in the row help.
    static func trailingDetail(for session: Session, now: Date = Date(),
                               calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard SidebarSection.containing(session) == .stopped,
              let finished = session.finishedAt else { return session.provider.rawValue }
        return stoppedDate(finished, now: now, calendar: calendar, locale: locale)
    }

    /// A time today, "yesterday" with a time, a short date this year, and the
    /// year before.
    static func stoppedDate(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale,
            calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.format("yesterday, %@", time)
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    static func help(for session: Session, isFresh: Bool = true) -> String {
        var parts = [session.displayTitle, session.provider.rawValue,
                     isFresh ? status(for: session) : L10n.string("last known status")]
        if session.name != session.displayTitle { parts.append(session.name) }
        if let exit = session.exitStatus { parts.append(L10n.format("exit %d", exit)) }
        if let created = session.createdAt {
            parts.append(L10n.format("Started %@", created.formatted(date: .abbreviated, time: .shortened)))
        }
        if SidebarSection.containing(session) == .stopped, let finished = session.finishedAt {
            parts.append(L10n.format("Stopped %@", finished.formatted(date: .abbreviated, time: .shortened)))
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
                    // A minute timeline keeps "today" and "yesterday" true
                    // after midnight without a new session snapshot.
                    TimelineView(.everyMinute) { context in
                        Text(SessionRowPresentation.trailingDetail(for: session, now: context.date))
                            .fixedSize()
                    }
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

    private var markSize: CGFloat { max(14, fontPointSize * 8 / 7) }

    private var shouldAnimate: Bool {
        SessionRowPresentation.shouldAnimate(signal: session.statusSignal, isFresh: isFresh,
            isVisible: isVisible, isActive: scenePhase == .active, reduceMotion: reduceMotion)
    }

    var body: some View {
        Group {
            if isFresh && session.statusSignal == .working {
                WorkingRing(lineWidth: max(1.5, markSize / 10), isRotating: shouldAnimate)
            } else {
                Image(systemName: SessionRowPresentation.symbol(for: session, isFresh: isFresh))
                    .resizable()
                    .scaledToFit()
                    .font(.system(size: markSize, weight: .medium))
                    .foregroundStyle(isFresh ? SessionIdentity.statusColor(for: session) : SessionPalette.secondary)
            }
        }
        .frame(width: markSize, height: markSize)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Core Animation spins the working ring in the render server. SwiftUI only
/// starts or stops it, so list refreshes, row reuse, layout passes, and
/// main-thread work cannot restart, move, or stall the rotation.
private struct WorkingRing: NSViewRepresentable {
    let lineWidth: CGFloat
    let isRotating: Bool

    func makeNSView(context: Context) -> WorkingRingView { WorkingRingView() }

    func updateNSView(_ view: WorkingRingView, context: Context) {
        view.lineWidth = lineWidth
        view.isRotating = isRotating
    }
}

final class WorkingRingView: NSView {
    static let period: CFTimeInterval = 1.8
    static let rotationKey = "detach.working-ring.rotation"
    let ring = CAShapeLayer()

    var lineWidth: CGFloat = 1.5 {
        didSet { if lineWidth != oldValue { needsLayout = true } }
    }

    var isRotating = false {
        didSet { if isRotating != oldValue { updateRotation() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineCap = .round
        ring.strokeEnd = 0.72
        // Geometry and color follow SwiftUI layout and appearance at once.
        ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(),
                        "lineWidth": NSNull(), "strokeColor": NSNull(), "contentsScale": NSNull()]
        attachRing()
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        attachRing()
        ring.frame = bounds
        let inset = lineWidth / 2
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        ring.lineWidth = lineWidth
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachRing()
        ring.contentsScale = window?.backingScaleFactor ?? ring.contentsScale
        updateColor()
        updateRotation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ring.contentsScale = window?.backingScaleFactor ?? ring.contentsScale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func attachRing() {
        guard let layer, ring.superlayer !== layer else { return }
        layer.addSublayer(ring)
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = SessionPalette.attentionNSColor.cgColor
        }
    }

    private func updateRotation() {
        guard isRotating else {
            ring.removeAnimation(forKey: Self.rotationKey)
            return
        }
        guard ring.animation(forKey: Self.rotationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        // Layer space has a bottom-left origin, so a negative turn is clockwise.
        rotation.toValue = -2 * Double.pi
        rotation.duration = Self.period
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        // One shared phase keeps rings in step and lets a recreated row
        // continue where the previous one was.
        rotation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
        ring.add(rotation, forKey: Self.rotationKey)
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
