import AppKit
import DetachKit
import SwiftUI

private enum PetWindowConstants {
    static let identifier = NSUserInterfaceItemIdentifier("detach-pet")
    static let size = NSSize(width: 156, height: 168)
    static let positionXKey = "petWindowX"
    static let positionYKey = "petWindowY"
}

struct PetPointerIntent {
    static let dragThreshold: CGFloat = 4

    private var beganAt: NSPoint?
    private(set) var didDrag = false

    mutating func begin(at point: NSPoint) {
        beganAt = point
        didDrag = false
    }

    mutating func update(to point: NSPoint) {
        guard let beganAt else { return }
        let dx = point.x - beganAt.x
        let dy = point.y - beganAt.y
        if hypot(dx, dy) >= Self.dragThreshold {
            didDrag = true
        }
    }

    var shouldActivate: Bool { beganAt != nil && !didDrag }

    mutating func end() {
        beganAt = nil
        didDrag = false
    }
}

private final class PetPanel: NSPanel {
    private var pointerIntent = PetPointerIntent()
    private(set) var shouldActivateControl = true

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pointerIntent.begin(at: NSEvent.mouseLocation)
            shouldActivateControl = true
            super.sendEvent(event)
        case .leftMouseDragged:
            pointerIntent.update(to: NSEvent.mouseLocation)
            shouldActivateControl = pointerIntent.shouldActivate
            super.sendEvent(event)
        case .leftMouseUp:
            pointerIntent.update(to: NSEvent.mouseLocation)
            shouldActivateControl = pointerIntent.shouldActivate
            // SwiftUI dispatches the Button action synchronously from this
            // mouse-up. Keep the decision available until it has run.
            super.sendEvent(event)
            pointerIntent.end()
        default:
            super.sendEvent(event)
        }
    }
}

@MainActor
final class PetWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private var panel: NSPanel?
    private weak var coordinator: PetCoordinator?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func configure(
        coordinator: PetCoordinator,
        navigation: MainNavigation,
        onVisibilityChange: @escaping (Bool) -> Void,
        openMainWindow: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        coordinator.onVisibilityChange = { [weak self, weak coordinator] in
            self?.synchronizeVisibility()
            onVisibilityChange(coordinator?.shouldShow == true)
        }
        if panel == nil {
            panel = makePanel(
                coordinator: coordinator,
                onOpen: { [weak coordinator, weak navigation] activity in
                    guard let coordinator, let navigation else {
                        openMainWindow()
                        return
                    }
                    PetSessionNavigator.open(
                        activity,
                        coordinator: coordinator,
                        navigation: navigation,
                        openMainWindow: openMainWindow)
                })
        }
        synchronizeVisibility()
        onVisibilityChange(coordinator.shouldShow)
    }

    func synchronizeVisibility() {
        guard let panel, let coordinator else { return }
        if coordinator.shouldShow {
            if !panel.isVisible {
                restorePosition(of: panel)
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              panel.identifier == PetWindowConstants.identifier else { return }
        defaults.set(Double(panel.frame.origin.x), forKey: PetWindowConstants.positionXKey)
        defaults.set(Double(panel.frame.origin.y), forKey: PetWindowConstants.positionYKey)
    }

    private func makePanel(
        coordinator: PetCoordinator,
        onOpen: @escaping (PetActivity?) -> Void
    ) -> NSPanel {
        let panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: PetWindowConstants.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.identifier = PetWindowConstants.identifier
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PetFloatingView(
            coordinator: coordinator,
            shouldActivateControl: { [weak panel] in
                panel?.shouldActivateControl ?? true
            },
            onOpen: onOpen))
        return panel
    }

    private func restorePosition(of panel: NSPanel) {
        let savedX = defaults.object(forKey: PetWindowConstants.positionXKey) as? Double
        let savedY = defaults.object(forKey: PetWindowConstants.positionYKey) as? Double
        if let savedX, let savedY {
            let candidate = NSRect(
                x: savedX, y: savedY,
                width: PetWindowConstants.size.width,
                height: PetWindowConstants.size.height)
            if NSScreen.screens.contains(where: {
                $0.visibleFrame.intersection(candidate).width >= 48
                    && $0.visibleFrame.intersection(candidate).height >= 48
            }) {
                panel.setFrameOrigin(candidate.origin)
                return
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(
            x: 0, y: 0, width: 1_440, height: 900)
        panel.setFrameOrigin(NSPoint(
            x: screen.maxX - PetWindowConstants.size.width - 24,
            y: screen.minY + 64))
    }
}

@MainActor
enum PetSessionNavigator {
    static func open(
        _ activity: PetActivity?,
        coordinator: PetCoordinator,
        navigation: MainNavigation,
        openMainWindow: () -> Void
    ) {
        if let activity { coordinator.acknowledge(activity) }
        if let activity {
            navigation.requestSession(
                activity.sessionID,
                focusTerminal: activity.state == .needsInput
                    || activity.state == .running)
        } else {
            navigation.requestedSessionID = nil
            navigation.terminalFocusRequest = nil
        }
        openMainWindow()
    }
}

enum PetPrimaryAction: Equatable {
    case open(PetActivity?)
    case choose
}

enum PetPrimaryActionResolver {
    static func resolve(_ activities: [PetActivity]) -> PetPrimaryAction {
        guard let topPriority = activities.map(\.state.priority).min() else {
            return .open(nil)
        }
        let top = activities.filter { $0.state.priority == topPriority }
        guard top.count == 1 else { return .choose }
        return .open(top[0])
    }
}

private struct PetFloatingView: View {
    @ObservedObject var coordinator: PetCoordinator
    let shouldActivateControl: () -> Bool
    let onOpen: (PetActivity?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsActivityTray = false
    @State private var animationStartedAt = Date()

    var body: some View {
        VStack(spacing: 2) {
            PetWindowDragHandle()
                .frame(width: 44, height: 12)

            ZStack(alignment: .topTrailing) {
                Button {
                    guard shouldActivateControl() else { return }
                    activatePrimary()
                } label: {
                    petImage
                }
                .buttonStyle(.plain)
                .help(primaryHelp)
                .accessibilityLabel(primaryHelp)

                if coordinator.activities.count > 1 {
                    Button {
                        guard shouldActivateControl() else { return }
                        showsActivityTray.toggle()
                    } label: {
                        Text(verbatim: "\(coordinator.activities.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Circle().fill(activityColor))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Open pet activity"))
                    .popover(isPresented: $showsActivityTray, arrowEdge: .trailing) {
                        activityTray
                    }
                }
            }
            .frame(width: 116, height: 116)

            if let activity = coordinator.currentActivity {
                Text(activityLabel(activity.state))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            }
        }
        .frame(width: PetWindowConstants.size.width,
               height: PetWindowConstants.size.height)
        .contentShape(Rectangle())
        .onChange(of: animationIdentity, initial: true) { _, _ in
            // Every state/session transition starts with the semantic first
            // frame instead of inheriting an arbitrary phase from another job.
            animationStartedAt = Date()
        }
    }

    @ViewBuilder
    private var petImage: some View {
        if let atlas = coordinator.atlas {
            TimelineView(.animation(
                minimumInterval: reduceMotion ? nil : 1.0 / 12.0,
                paused: reduceMotion
            )) { context in
                let frame = PetAnimationFrameResolver.frame(
                    activity: coordinator.currentActivity?.state,
                    elapsed: max(
                        0,
                        context.date.timeIntervalSince(animationStartedAt)),
                    reduceMotion: reduceMotion,
                    pointerVector: pointerVector,
                    supportsLookDirections: atlas.package.spriteVersionNumber == 2)
                if let image = atlas.frame(frame) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 106, height: 114)
                }
            }
            .id(animationIdentity)
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
        }
    }

    private var pointerVector: CGVector? {
        guard let frame = NSApp.windows.first(where: {
            $0.identifier == PetWindowConstants.identifier
        })?.frame else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGVector(dx: mouse.x - frame.midX, dy: mouse.y - frame.midY)
    }

    private var animationIdentity: String {
        guard let activity = coordinator.currentActivity else { return "idle" }
        return "\(activity.sessionID):\(activity.state.rawValue)"
    }

    private var primaryHelp: String {
        guard let activity = coordinator.currentActivity else {
            return L10n.string("Open Detach")
        }
        return L10n.format("Open %@ in Detach", activity.title)
    }

    private var activityColor: Color {
        switch coordinator.currentActivity?.state {
        case .needsInput: .orange
        case .blocked: .red
        case .ready: Brand.indigo
        case .running: Brand.teal
        case nil: .secondary
        }
    }

    private var activityTray: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("Pet activity"))
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(coordinator.activities) { activity in
                        Button {
                            showsActivityTray = false
                            onOpen(activity)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(color(for: activity.state))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(activity.title).lineLimit(1)
                                    Text("\(providerName(activity.provider)) · \(activityLabel(activity.state))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(10)
        .frame(width: 260)
    }

    private func color(for state: PetActivityState) -> Color {
        switch state {
        case .needsInput: .orange
        case .blocked: .red
        case .ready: Brand.indigo
        case .running: Brand.teal
        }
    }

    private func activityLabel(_ state: PetActivityState) -> String {
        switch state {
        case .needsInput: L10n.string("Needs input")
        case .blocked: L10n.string("Blocked")
        case .ready: L10n.string("Answer ready")
        case .running: L10n.string("Running")
        }
    }

    private func providerName(_ provider: Provider) -> String {
        provider == .claude ? "Claude Code" : "Codex"
    }

    private func activatePrimary() {
        switch PetPrimaryActionResolver.resolve(coordinator.activities) {
        case let .open(activity):
            onOpen(activity)
        case .choose:
            showsActivityTray = true
        }
    }
}

private struct PetWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PetWindowDragNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PetWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 8, dy: 4),
            xRadius: 2,
            yRadius: 2).fill()
    }
}
