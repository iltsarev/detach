import SwiftUI
import AppKit
import DetachKit

enum SessionDetailLogRefresh {
    /// A visible live session without its embedded terminal follows pane
    /// output, which produces no file event. Keep that one surface on a
    /// bounded cadence while it is on screen; every other surface is
    /// event-driven and immutable.
    static let liveFallbackIntervalNanoseconds: UInt64 = 2_000_000_000

    static func taskID(
        session: Session,
        showsEmbeddedTerminal: Bool,
        cachedLogIdentity: ObjectIdentifier?
    ) -> String {
        if showsEmbeddedTerminal || !session.isLive {
            // A replaced cache entry (typed revision changed or evicted) must
            // restart the load; the session id alone would not change.
            let identity = cachedLogIdentity.map { "\($0.hashValue)" } ?? "local"
            return "\(session.id)-\(showsEmbeddedTerminal)-\(identity)"
        }
        return "\(session.id)-logs"
    }
}

enum SessionDetailRetainedFrame {
    case text(NSAttributedString)
}

/// Keeps one visible terminal host while selection moves between live sessions.
private struct LiveSessionTerminalPanel: View {
    let detachPath: String
    let session: Session
    let fontPointSize: CGFloat
    let screenCache: SessionTerminalScreenCache
    let onTerminated: (Int32?) -> Void
    let onSwitchFailed: (String) -> Void
    var onPresentationReady: () -> Void = {}

    @State private var frameReady = false
    @State private var didReportPresentationReady = false

    var body: some View {
        ZStack {
            SessionAttachTerminalView(
                detachPath: detachPath,
                session: session,
                fontPointSize: fontPointSize,
                screenCache: screenCache,
                onTerminated: onTerminated,
                onFirstVisibleFrame: {
                    frameReady = true
                    reportPresentationReady()
                },
                onSwitchFailed: onSwitchFailed)
                .frame(maxHeight: .infinity)
                .accessibilityLabel(L10n.string("Live session terminal"))

            if !frameReady, hasRetainedContent {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        // SessionAttachTerminalView installed the passive
                        // SwiftTerm text frame synchronously in makeNSView.
                        reportPresentationReady()
                    }
            }
        }
        .onChange(of: session.id) { _, _ in
            didReportPresentationReady = false
            // The existing terminal stays drawable while tmux switches it.
            // Complete the SwiftUI selection without waiting for a new PTY.
            DispatchQueue.main.async { reportPresentationReady() }
        }
    }

    private func reportPresentationReady() {
        guard !didReportPresentationReady else { return }
        didReportPresentationReady = true
        // Defer transition completion until AppKit installs the target hierarchy.
        DispatchQueue.main.async { onPresentationReady() }
    }

    private var hasRetainedContent: Bool {
        screenCache.screen(for: session) != nil
    }
}

struct SessionDetailView: View {
    let session: Session
    let store: SessionStore
    let detachPath: String
    let terminalScreens: SessionTerminalScreenCache
    /// Supplied before the first body pass so a warm non-live log cannot flash
    /// an empty placeholder while `.task` starts its background refresh.
    let cachedLog: LogPoller?
    /// Passive text from the previous selection. It covers a cold target log
    /// surface, so the new header and actions determine layout at once.
    var retainedFrame: SessionDetailRetainedFrame? = nil
    var onPresentationReady: () -> Void = {}
    @AppStorage(AppSettings.terminalBundleIdentifierKey, store: AppSettings.defaults)
    private var terminalBundleIdentifier =
        TerminalCatalog.defaultBundleIdentifier
    @Environment(\.appFontPointSize) private var fontPointSize

    @State private var logPoller: LogPoller?
    @State private var logPollerSessionID: String?
    @State private var actionError: String?
    @State private var terminalFailure: TerminalLaunchFailure?
    @State private var isLaunchingTerminal = false
    @State private var confirmDelete = false
    @State private var attachClientActive = true
    @State private var attachRequested = false
    @State private var preparingAction: SessionAction?
    @State private var interactionGeneration = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerCard
            logView.layoutPriority(1)
            actionBar
        }
        .padding(16)
        .onChange(of: session.id) { _, _ in
            interactionGeneration = UUID()
            logPoller = nil
            logPollerSessionID = nil
            actionError = nil
            terminalFailure = nil
            isLaunchingTerminal = false
            confirmDelete = false
            attachClientActive = true
            attachRequested = false
            preparingAction = nil
        }
        .task(id: logTaskID) {
            guard !showsEmbeddedTerminal else {
                logPoller = nil
                logPollerSessionID = nil
                return
            }
            let poller = cachedLog
                ?? (logPollerSessionID == session.id ? logPoller : nil)
                ?? LogPoller(
                    cli: ProcessDetachCLI(executable: URL(fileURLWithPath: detachPath)),
                    provider: session.provider,
                    sessionName: session.sessionName)
            if cachedLog == nil, logPoller !== poller {
                logPoller = poller
                logPollerSessionID = session.id
            }
            // The cache follows typed lifecycle revisions. An unchanged
            // non-live tail is immutable, so revisiting it needs no process.
            if cachedLog?.hasLoaded == true { return }
            await poller.fetchOnce()
            guard session.isLive else { return }
            // Pane output of a disconnected live session has no event source.
            // Follow it only while this surface is visible; selection changes
            // and the embedded terminal cancel this task.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: SessionDetailLogRefresh.liveFallbackIntervalNanoseconds)
                } catch {
                    return
                }
                await poller.fetchOnce()
            }
        }
        .alert(L10n.string("Something went wrong"), isPresented: .init(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .alert(L10n.string("Could not open Terminal"), isPresented: .init(
            get: { terminalFailure != nil },
            set: { if !$0 { terminalFailure = nil } })) {
            if terminalFailure?.requiresTerminalSelection == true {
                SettingsLink {
                    Text(L10n.string("Choose another terminal"))
                }
            }
            Button(L10n.string("Close"), role: .cancel) {}
        } message: {
            Text(terminalFailure?.message ?? "")
        }
        .confirmationDialog(L10n.format("Delete session “%@”?", session.displayTitle),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.string("Delete"), role: .destructive) { run(.delete) }
        } message: {
            Text(L10n.string("The Detach state directory and checkpoints will be permanently deleted. The provider transcript in ~/.claude or ~/.codex will not be affected."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-detail-\(session.id)")
    }

    private var providerTint: Color {
        Brand.tint(for: session.provider)
    }

    private var identityColor: Color {
        guard let sessionColor = session.sessionColor else {
            return Color.secondary.opacity(0.5)
        }
        return SessionIdentity.color(sessionColor)
            .opacity(SessionIdentity.emphasis(for: session.effectiveStatus))
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Capsule(style: .continuous)
                    .fill(identityColor)
                    .frame(
                        width: SessionDetailSignalPresentation.identityMarkerWidth,
                        height: SessionDetailSignalPresentation.identityMarkerHeight)
                    .help(session.sessionColor.map {
                        L10n.format("Session base color: %@", $0.hex)
                    } ?? "")
                    .accessibilityHidden(true)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "session-detail-identity-marker")
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
                Text(session.displayTitle)
                    .appFont(.title2, weight: .bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.displayTitle)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "session-detail-title")
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
                statusPill
                Spacer()
            }
            metadataRail
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
    }

    private var statusPill: some View {
        let color = SessionIdentity.statusColor(for: session)
        return Text(session.displayStatus)
            .appFont(.caption, weight: .semibold)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
            .layoutPriority(1)
    }

    private func metaChip(
        icon: String? = nil,
        _ text: String,
        mono: Bool = false,
        help: String? = nil
    ) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .appFont(.caption, design: mono ? .monospaced : .default)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .help(help ?? text)
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func abbreviatePath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Metadata never wraps. A wrap would change the terminal frame when the
    /// selection changes. The rail keeps every value available by scrolling.
    private var metadataRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let model = session.model {
                    Text(model)
                        .appFont(.caption, weight: .semibold)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(providerTint.opacity(0.16)))
                        .foregroundStyle(providerTint)
                }
                if session.contextSummary != nil {
                    ContextGauge(session: session)
                }
                if let reason = session.healthReasonLabel {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.orange.opacity(0.12)))
                        .help(reason)
                }
                if let projectDir = session.projectDir {
                    metaChip(icon: "folder", abbreviatePath(projectDir), mono: true,
                             help: projectDir)
                }
                if let uuid = session.agentSessionId {
                    SessionUUIDChip(uuid: uuid)
                }
                if let created = session.createdAt {
                    metaChip(L10n.format(
                        "created %@", created.formatted(.relative(presentation: .named))))
                }
                if let checkpoint = session.lastCheckpointAt {
                    metaChip(L10n.format(
                        "checkpoint %@", checkpoint.formatted(.relative(presentation: .named))))
                }
                if let exit = session.exitStatus {
                    metaChip(L10n.format("exit %d", exit))
                }
                if showsEmbeddedTerminal {
                    embeddedTerminalPowerChip
                }
                // Some legacy rows have no metadata. Keep the rail at the
                // same font-scaled height without adding visible content.
                Text("M")
                    .appFont(.caption)
                    .padding(.vertical, 3)
                    .hidden()
                    .frame(width: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Log

    private static let placeholderAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(white: 0.85, alpha: 1),
    ]

    private var logContent: NSAttributedString {
        let sessionPoller = logPollerSessionID == session.id ? logPoller : nil
        let visiblePoller = cachedLog ?? sessionPoller
        if let error = visiblePoller?.errorText {
            var attributes = Self.placeholderAttributes
            attributes[.foregroundColor] = NSColor.systemOrange
            return NSAttributedString(string: "⚠︎ \(error)", attributes: attributes)
        }
        if let attributed = visiblePoller?.attributed, attributed.length > 0 {
            return attributed
        }
        return NSAttributedString(string: "…", attributes: Self.placeholderAttributes)
    }

    private var showsEmbeddedTerminal: Bool {
        attachRequested || (
            preparingAction == nil
                && SessionAttachInvocation.shouldEmbed(
                    session,
                    clientActive: attachClientActive))
    }

    private var logTaskID: String {
        SessionDetailLogRefresh.taskID(
            session: session,
            showsEmbeddedTerminal: showsEmbeddedTerminal,
            cachedLogIdentity: cachedLog.map(ObjectIdentifier.init))
    }

    private var logView: some View {
        ZStack {
            VStack(spacing: 0) {
                if showsEmbeddedTerminal {
                    let generation = interactionGeneration
                    LiveSessionTerminalPanel(
                        detachPath: detachPath,
                        session: session,
                        fontPointSize: fontPointSize,
                        screenCache: terminalScreens,
                        onTerminated: { _ in
                            handleTerminalExit(generation: generation)
                        },
                        onSwitchFailed: { message in
                            guard interactionGeneration == generation else { return }
                            actionError = message
                            attachClientActive = false
                        },
                        onPresentationReady: onPresentationReady)
                        // One target creates one panel and one PTY host. A late
                        // callback belongs to the removed panel and cannot reveal
                        // a later attach attempt for the same session.
                } else {
                    LogTextView(text: logContent)
                        .frame(maxHeight: .infinity)
                        .onAppear {
                            // makeNSView applies and lays out cached text before
                            // it returns. Keep the passive outgoing frame for one
                            // main turn so the handoff reaches AppKit's display
                            // boundary before that frame leaves.
                            DispatchQueue.main.async { onPresentationReady() }
                        }
                }
                if !showsEmbeddedTerminal {
                    sessionColorStrip
                }
            }

            if let retainedFrame {
                Group {
                    switch retainedFrame {
                    case let .text(text):
                        LogTextView(text: text)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .accessibilityIdentifier("session-preview-transition-frame")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .background {
            if AppSettings.uiE2E != nil {
                uiE2EGeometryProbe(identifier: "session-detail-log-surface")
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    private var embeddedTerminalPowerChip: some View {
        Label(
            session.powerProtectionLabel,
            systemImage: session.powerProtectionSystemImage)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
            .foregroundStyle(SessionDetailSignalPresentation.powerColor(
                for: session.powerProtectionState))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(session.powerProtectionLabel))
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                uiE2EGeometryProbe(identifier: "session-preview-power")
            }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    /// A discreet echo of the tmux status line under a retained log, in the
    /// session's stable identity color. A live terminal already shows tmux's
    /// status line, so its typed power signal stays in the metadata row.
    @ViewBuilder
    private var sessionColorStrip: some View {
        if let sessionColor = session.sessionColor {
            let tint = sessionColor.tmuxStatusTint(percent:
                SessionDetailSignalPresentation.identityTintPercent(
                    for: session.effectiveStatus))
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(session.displayTitle)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 18)
                .background(SessionIdentity.color(tint))
                .foregroundStyle(Color.white.opacity(0.92))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("Session identity color"))
                .accessibilityValue(sessionColor.hex)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    uiE2EGeometryProbe(identifier: "session-preview-identity")
                }
#endif
// quality-coverage:end ui-e2e-instrumentation

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
                    .accessibilityHidden(true)

                Label(
                    session.powerProtectionLabel,
                    systemImage: session.powerProtectionSystemImage)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 18)
                    .background(Color(nsColor: ANSIParser.terminalBackground))
                    .foregroundStyle(SessionDetailSignalPresentation.powerColor(
                        for: session.powerProtectionState))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(session.powerProtectionLabel))
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                    .background {
                        uiE2EGeometryProbe(identifier: "session-preview-power")
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
            .frame(height: 18)
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            ForEach(session.availableActions, id: \.self) { action in
                actionButton(action)
            }
            if session.effectiveStatus == .collision {
                Label(L10n.string("The name is used by another tmux session"), systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(minHeight: 28)
    }

    private var selectedTerminalDisplayName: String {
        TerminalCatalog.application(bundleIdentifier: terminalBundleIdentifier)?.displayName
            ?? "Terminal"
    }

    @ViewBuilder
    private func actionButton(_ action: SessionAction) -> some View {
        switch action {
        case .attach, .resume, .recover:
            interactiveActionButtons(action)
        case .stop:
            Button(L10n.string("Stop"), role: .destructive) { run(.stop) }
                .accessibilityIdentifier("session-action-stop")
                .disabled(preparingAction != nil)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    uiE2EGeometryProbe(identifier: "session-action-stop")
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
        case .delete:
            Button(L10n.string("Delete"), role: .destructive) { confirmDelete = true }
                .accessibilityIdentifier("session-action-delete")
                .disabled(preparingAction != nil)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    uiE2EGeometryProbe(identifier: "session-action-delete")
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
        }
    }

    @ViewBuilder
    private func interactiveActionButtons(_ action: SessionAction) -> some View {
        if shouldShowInAppButton(action) {
            let title = SessionActionPresentation.inAppTitle(for: action)
            let identifier = "session-action-\(action.rawValue)-in-app"
            let enabled = preparingAction == nil && !isLaunchingTerminal
            Button {
                startInsideDetach(action)
            } label: {
                HStack(spacing: 6) {
                    if preparingAction == action {
                        ProgressView().controlSize(.small)
                    }
                    Text(title)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Brand.indigo)
            .disabled(!enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
#if !DEBUG
            .background {
                uiE2EGeometryProbe(
                    identifier: identifier,
                    semanticLabel: title,
                    semanticRole: .button,
                    semanticEnabled: enabled)
            }
#endif
        }

        if shouldShowExternalFallback(action),
           let command = externalTerminalCommand(for: action) {
            let title = SessionActionPresentation.terminalTitle(
                for: action,
                terminalDisplayName: selectedTerminalDisplayName)
            let identifier = "session-action-\(action.rawValue)-external"
            let enabled = preparingAction == nil && !isLaunchingTerminal
            Button(title) {
                openInTerminal(command)
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(identifier)
#if !DEBUG
            .background {
                uiE2EGeometryProbe(
                    identifier: identifier,
                    semanticLabel: title,
                    semanticRole: .button,
                    semanticEnabled: enabled)
            }
#endif
        }
    }

    private func shouldShowInAppButton(_ action: SessionAction) -> Bool {
        if preparingAction == action { return true }
        return preparingAction == nil && !showsEmbeddedTerminal
    }

    private func shouldShowExternalFallback(_ action: SessionAction) -> Bool {
        guard preparingAction == nil else { return false }
        return action == .attach || !showsEmbeddedTerminal
    }

    private func externalTerminalCommand(for action: SessionAction) -> String? {
        switch action {
        case .attach:
            TerminalCommand.attach(detachPath: detachPath, session: session)
        case .resume:
            TerminalCommand.resume(detachPath: detachPath, session: session)
        case .recover:
            TerminalCommand.recover(detachPath: detachPath, session: session)
        case .stop, .delete:
            nil
        }
    }

    private func startInsideDetach(_ action: SessionAction) {
        let generation = UUID()
        interactionGeneration = generation
        attachRequested = false

        if action == .attach {
            attachClientActive = true
            attachRequested = true
            return
        }

        guard preparingAction == nil,
              action == .resume || action == .recover else { return }
        let sessionID = session.id
        attachClientActive = false
        preparingAction = action
        Task {
            let message = await store.prepareInteractive(action, on: session)
            guard interactionGeneration == generation,
                  session.id == sessionID else { return }
            preparingAction = nil
            if let message {
                actionError = message
                return
            }
            attachClientActive = true
            attachRequested = true
        }
    }

    private func handleTerminalExit(generation: UUID) {
        guard generation == interactionGeneration else { return }
        attachRequested = false
        attachClientActive = false
        Task { await store.refresh() }
    }

// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
    @ViewBuilder
    private func uiE2EGeometryProbe(
        identifier: String,
        semanticLabel: String? = nil,
        semanticRole: NSAccessibility.Role? = nil,
        semanticEnabled: Bool = true
    ) -> some View {
        if AppSettings.uiE2E != nil {
            UIE2EGeometryProbe(
                identifier: identifier,
                semanticLabel: semanticLabel,
                semanticRole: semanticRole,
                semanticEnabled: semanticEnabled)
        }
    }
#endif
// quality-coverage:end ui-e2e-instrumentation

    @MainActor
    private func openInTerminal(_ command: String) {
        let generation = interactionGeneration
        Task {
            guard !isLaunchingTerminal else { return }
            isLaunchingTerminal = true
            defer { isLaunchingTerminal = false }
            let failure = await TerminalLauncher.open(
                command: command,
                terminalBundleIdentifier: terminalBundleIdentifier)
            guard interactionGeneration == generation else { return }
            if let failure {
                terminalFailure = failure
            }
        }
    }

    private func run(_ action: SessionAction) {
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        if action == .stop, AppSettings.uiE2E != nil {
            UIE2EControlFault.stopActionAttempts += 1
            if UIE2EControlFault.stopActionDisconnected {
                return
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
        let generation = interactionGeneration
        let selectedSessionID = session.id
        let selectedSession = session
        Task {
            let message = await store.perform(action, on: selectedSession)
            guard interactionGeneration == generation,
                  session.id == selectedSessionID else { return }
            if let message {
                actionError = message
            }
        }
    }
}

enum SessionUUIDPresentation {
    static func shortDisplay(_ uuid: String) -> String {
        guard uuid.count > 13 else { return uuid }
        return "\(uuid.prefix(8))…\(uuid.suffix(4))"
    }

    @discardableResult
    static func copy(
        _ uuid: String,
        to pasteboard: any SessionUUIDPasteboardWriting = NSPasteboard.general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(uuid, forType: .string)
    }
}

protocol SessionUUIDPasteboardWriting: AnyObject {
    @discardableResult
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: SessionUUIDPasteboardWriting {}

/// The whole metadata chip is the control. A nested icon-only button can miss
/// clicks while its horizontal rail scrolls on macOS.
struct SessionUUIDChip: View {
    let uuid: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copyUUID) {
            HStack(spacing: 4) {
                Text(SessionUUIDPresentation.shortDisplay(uuid))
                    .appFont(.caption, design: .monospaced)
                    .lineLimit(1)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .appFont(.caption2)
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(copied ? Brand.teal : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(
                    copied
                        ? AnyShapeStyle(Brand.teal.opacity(0.20))
                        : AnyShapeStyle(.quaternary.opacity(0.6)))
            }
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.18), value: copied)
        }
        .buttonStyle(ChipPressStyle())
        .help(copied ? L10n.string("Copied") : uuid)
        .accessibilityLabel(
            copied ? L10n.string("Copied") : L10n.string("Copy session UUID"))
        .accessibilityValue(uuid)
        .accessibilityIdentifier("session-uuid-chip")
        .accessibilityAddTraits(.isButton)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .overlay {
            if AppSettings.uiE2E != nil {
                UIE2EGeometryProbe(
                    identifier: "session-uuid-chip",
                    semanticLabel: copied
                        ? L10n.string("Copied") : L10n.string("Copy session UUID"),
                    semanticRole: .button)
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
        .onDisappear {
            resetTask?.cancel()
        }
    }

    private func copyUUID() {
        guard SessionUUIDPresentation.copy(uuid) else { return }
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            let feedbackDuration: UInt64 = AppSettings.uiE2E == nil
                ? 1_500_000_000
                : 400_000_000
            try? await Task.sleep(nanoseconds: feedbackDuration)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum SessionActionPresentation {
    static func inAppTitle(for action: SessionAction) -> String {
        switch action {
        case .attach: L10n.string("Reconnect")
        case .resume: L10n.string("Resume")
        case .recover: L10n.string("Recover")
        case .stop, .delete:
            preconditionFailure("A non-terminal action has no in-app title")
        }
    }

    static func terminalTitle(
        for action: SessionAction,
        terminalDisplayName: String
    ) -> String {
        switch action {
        case .attach:
            L10n.format("Open in %@", terminalDisplayName)
        case .resume:
            L10n.format("Resume in %@", terminalDisplayName)
        case .recover:
            L10n.format("Recover in %@", terminalDisplayName)
        case .stop, .delete:
            preconditionFailure("A non-terminal action has no terminal title")
        }
    }
}

struct ContextGauge: View {
    let session: Session

    private var gaugeColor: Color {
        guard let fraction = session.contextFraction else { return .secondary }
        if fraction < 0.7 { return Brand.teal }
        if fraction < 0.9 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = session.contextFraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 56, height: 6)
                    Capsule().fill(gaugeColor).frame(width: max(4, 56 * fraction), height: 6)
                }
            }
            if let summary = session.contextSummary {
                Text(summary).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(L10n.string("Model context used"))
    }
}
