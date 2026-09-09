import SwiftUI
import DetachKit

enum FinishedDeletionPresentation {
    static func errorMessage(for failures: [SessionDeletionFailure]) -> String {
        failures
            .map { "\($0.displayTitle): \($0.message)" }
            .joined(separator: "\n")
    }
}

struct SidebarFailurePresentation: Equatable, Identifiable {
    enum Kind: Hashable {
        case finishedDeletion
        case quickChat
    }

    let kind: Kind
    let message: String

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .finishedDeletion:
            L10n.string("Could not delete some sessions")
        case .quickChat:
            L10n.string("Could not start quick chat")
        }
    }
}

struct FinishedSelectionReconciliation: Equatable {
    let selectedIDs: Set<String>
    let isSelecting: Bool

    static func resolve(
        selectedIDs: Set<String>,
        currentIDs: [String],
        isSelecting: Bool,
        isDeleting: Bool
    ) -> Self {
        Self(
            selectedIDs: selectedIDs.intersection(currentIDs),
            isSelecting: currentIDs.isEmpty && !isDeleting ? false : isSelecting)
    }
}

struct SidebarView: View {
    @Environment(\.appFontPointSize) private var fontPointSize
    let store: SessionStore
    @Binding var selectedID: String?
    @ObservedObject var navigation: MainNavigation
    let shortcutAssignments: [SessionShortcutAssignment]
    @AppStorage(AppSettings.defaultProjectsDirectoryKey, store: AppSettings.defaults)
    private var defaultProjectsDirectoryPath =
        AppSettings.defaultProjectsDirectoryPath
    @AppStorage(AppSettings.quickChatDirectoryKey, store: AppSettings.defaults)
    private var quickChatDirectoryPath = AppSettings.defaultQuickChatDirectoryPath
    @AppStorage(AppSettings.quickChatProviderKey, store: AppSettings.defaults)
    private var quickChatProvider = AppSettings.defaultQuickChatProvider
    @State private var showNewSession = false
    @State private var isStartingQuickChat = false
    @State private var failurePresentation: SidebarFailurePresentation?
    @State private var isSelectingFinished = false
    @State private var selectedFinishedIDs: Set<String> = []
    @State private var confirmFinishedDelete = false
    @State private var isDeletingFinished = false

    private func sessions(in section: SessionSection) -> [Session] {
        store.sessions.filter { $0.section == section }
    }

    private var deletableFinishedSessions: [Session] {
        sessions(in: .finished).filter(\.canDeleteFromFinishedList)
    }

    private var selectedFinishedSessions: [Session] {
        deletableFinishedSessions.filter { selectedFinishedIDs.contains($0.id) }
    }

// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
    private var uiE2EInitialProjectDirectory: URL? {
        guard let configuration = AppSettings.uiE2E,
              FileManager.default.fileExists(atPath: configuration.root
                .appendingPathComponent(
                    "fake/enable-new-session-project").path)
        else { return nil }
        return configuration.root.appendingPathComponent(
            "project", isDirectory: true)
    }
#else
    private var uiE2EInitialProjectDirectory: URL? { nil }
#endif
// quality-coverage:end ui-e2e-instrumentation

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(SessionSection.allCases, id: \.self) { section in
                    let items = sessions(in: section)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { session in
                                sessionRow(session)
                            }
                        } header: {
                            sectionHeader(section, count: items.count)
                        }
                    }
                }
            }
            .overlay {
                if store.sessions.isEmpty && store.state == .ok {
                    ContentUnavailableView {
                        Label {
                            Text(L10n.string("No sessions yet"))
                        } icon: {
                            Image(systemName: "terminal")
                                .foregroundStyle(Brand.gradient)
                        }
                    } description: {
                        Text(L10n.string("Start Codex or Claude in Detach"))
                    }
                }
            }
            if store.state != .cliMissing {
                Divider()
                shortcutGuide
            }
            if isSelectingFinished {
                finishedSelectionBar
                Divider()
            }
            StatusBar(store: store)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewSession = true
                } label: {
                    Label(L10n.string("New session"), systemImage: "plus")
                        .foregroundStyle(Brand.indigo)
                }
                .accessibilityIdentifier("new-session-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(identifier: "new-session-button")
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(
                store: store,
                selectedID: $selectedID,
                initialProjectDir: uiE2EInitialProjectDirectory,
                projectPickerRoot: DirectoryPreference.configuredOrFallback(
                    path: defaultProjectsDirectoryPath,
                    fallback: FileManager.default.homeDirectoryForCurrentUser)
            )
        }
        .confirmationDialog(
            L10n.format(
                "Delete selected sessions (%d)?",
                selectedFinishedSessions.count),
            isPresented: $confirmFinishedDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Delete"), role: .destructive) {
                deleteSelectedFinishedSessions()
            }
        } message: {
            Text(L10n.string(
                "The selected Detach state directories and checkpoints will be permanently deleted. Provider transcripts in ~/.claude and ~/.codex will not be affected."))
        }
        .alert(item: $failurePresentation) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                dismissButton: .cancel(Text(L10n.string("OK"))))
        }
        // The menu can request a sheet before reopening the main window, so
        // consume an already-pending request on the sidebar's first render.
        .onChange(of: navigation.requestsNewSession, initial: true) { _, requested in
            guard requested else { return }
            showNewSession = true
            navigation.requestsNewSession = false
        }
        .onChange(of: navigation.quickChatRequestID, initial: true) { _, requestID in
            guard requestID != nil else { return }
            navigation.quickChatRequestID = nil
            startQuickChat()
        }
        .onChange(of: deletableFinishedSessions.map(\.id)) { _, currentIDs in
            let state = FinishedSelectionReconciliation.resolve(
                selectedIDs: selectedFinishedIDs,
                currentIDs: currentIDs,
                isSelecting: isSelectingFinished,
                isDeleting: isDeletingFinished)
            selectedFinishedIDs = state.selectedIDs
            isSelectingFinished = state.isSelecting
        }
        .navigationSplitViewColumnWidth(
            min: max(230, fontPointSize * 18),
            ideal: max(260, fontPointSize * 20))
    }

    private var shortcutGuide: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(SidebarShortcutPresentation.hints) { hint in
                HStack(spacing: 6) {
                    Text(hint.shortcut)
                        .appFont(.caption, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Brand.indigo)
                    Text(isStartingQuickChat && hint.shortcut == "⌘T"
                         ? L10n.string("Starting…") : hint.title)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Keyboard shortcuts"))
        .accessibilityIdentifier("sidebar-shortcut-guide")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .background {
            if AppSettings.uiE2E != nil {
                UIE2EGeometryProbe(
                    identifier: "sidebar-shortcut-guide",
                    semanticLabel: L10n.string("Keyboard shortcuts"),
                    semanticRole: .group)
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    @ViewBuilder
    private func sectionHeader(_ section: SessionSection, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(L10n.format("%@ · %d", section.displayName, count))
                .foregroundStyle(
                    section == .answerReady ? Color.orange : Color.secondary)
            Spacer(minLength: 0)
            if section == .finished && !deletableFinishedSessions.isEmpty {
                Button(L10n.string(isSelectingFinished ? "Done" : "Select")) {
                    if isSelectingFinished {
                        selectedFinishedIDs.removeAll()
                    }
                    isSelectingFinished.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.indigo)
                .disabled(isDeletingFinished)
                .accessibilityIdentifier("finished-selection-mode-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(
                            identifier: "finished-selection-mode-button",
                            semanticLabel: isSelectingFinished ? "Done" : "Select",
                            semanticRole: .button,
                            semanticEnabled: !isDeletingFinished)
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
                .padding(.trailing, 12)
            }
        }
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .background {
            if AppSettings.uiE2E != nil && section == .finished {
                UIE2EGeometryProbe(identifier: "finished-section-header")
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let shortcutSlot = shortcutAssignments.first {
            $0.sessionID == session.id
        }?.slot
        if isSelectingFinished && session.canDeleteFromFinishedList {
            HStack(spacing: 8) {
                Button {
                    if selectedFinishedIDs.contains(session.id) {
                        selectedFinishedIDs.remove(session.id)
                    } else {
                        selectedFinishedIDs.insert(session.id)
                    }
                } label: {
                    Image(systemName: selectedFinishedIDs.contains(session.id)
                          ? "checkmark.square.fill" : "square")
                        .foregroundStyle(
                            selectedFinishedIDs.contains(session.id)
                                ? Brand.indigo : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDeletingFinished)
                .accessibilityLabel(L10n.format(
                    selectedFinishedIDs.contains(session.id)
                        ? "Deselect %@ from deletion" : "Select %@ for deletion",
                    session.displayTitle))
                .accessibilityIdentifier("finished-selection-\(session.id)")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                .background {
                    if AppSettings.uiE2E != nil {
                        UIE2EGeometryProbe(
                            identifier: "finished-selection-\(session.id)",
                            semanticLabel: selectedFinishedIDs.contains(session.id)
                                ? "Deselect \(session.displayTitle) from deletion"
                                : "Select \(session.displayTitle) for deletion",
                            semanticRole: .button,
                            semanticEnabled: !isDeletingFinished)
                    }
                }
#endif
// quality-coverage:end ui-e2e-instrumentation
                SessionRow(session: session, shortcutSlot: shortcutSlot)
            }
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background { uiE2EGeometryProbe(for: session) }
#endif
// quality-coverage:end ui-e2e-instrumentation
            .tag(session.id)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(SessionShortcutPresentation.accessibilityLabel(
                title: session.displayTitle,
                slot: shortcutSlot))
            .accessibilityIdentifier("session-row-\(session.id)")
            .listRowBackground(
                session.isWaitingForUser ? Color.orange.opacity(0.10) : nil)
        } else {
            Button {
                selectedID = session.id
            } label: {
                SessionRow(session: session, shortcutSlot: shortcutSlot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background { uiE2EGeometryProbe(for: session) }
#endif
// quality-coverage:end ui-e2e-instrumentation
            .tag(session.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(SessionShortcutPresentation.accessibilityLabel(
                title: session.displayTitle,
                slot: shortcutSlot))
            .accessibilityIdentifier("session-row-\(session.id)")
            .listRowBackground(
                session.isWaitingForUser ? Color.orange.opacity(0.10) : nil)
        }
    }

    private var finishedSelectionBar: some View {
        HStack(spacing: 8) {
            Button(L10n.string(
                selectedFinishedIDs.count == deletableFinishedSessions.count
                    ? "Clear selection" : "Select all")) {
                if selectedFinishedIDs.count == deletableFinishedSessions.count {
                    selectedFinishedIDs.removeAll()
                } else {
                    selectedFinishedIDs = Set(deletableFinishedSessions.map(\.id))
                }
            }
            .buttonStyle(.borderless)
            .disabled(isDeletingFinished || deletableFinishedSessions.isEmpty)
            .accessibilityIdentifier("finished-select-all-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                if AppSettings.uiE2E != nil {
                    UIE2EGeometryProbe(
                        identifier: "finished-select-all-button",
                        semanticLabel: selectedFinishedIDs.count
                            == deletableFinishedSessions.count
                            ? "Clear selection" : "Select all",
                        semanticRole: .button,
                        semanticEnabled: !isDeletingFinished
                            && !deletableFinishedSessions.isEmpty)
                }
            }
#endif
// quality-coverage:end ui-e2e-instrumentation

            Spacer()

            if isDeletingFinished {
                ProgressView().controlSize(.small)
            }
            Button(role: .destructive) {
                confirmFinishedDelete = true
            } label: {
                Label(
                    L10n.format("Delete %d", selectedFinishedSessions.count),
                    systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeletingFinished || selectedFinishedSessions.isEmpty)
            .accessibilityIdentifier("finished-delete-button")
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
            .background {
                if AppSettings.uiE2E != nil {
                    UIE2EGeometryProbe(
                        identifier: "finished-delete-button",
                        semanticLabel: "Delete \(selectedFinishedSessions.count)",
                        semanticRole: .button,
                        semanticEnabled: !isDeletingFinished
                            && !selectedFinishedSessions.isEmpty)
                }
            }
#endif
// quality-coverage:end ui-e2e-instrumentation
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func deleteSelectedFinishedSessions() {
        let selected = selectedFinishedSessions
        guard !selected.isEmpty else { return }
        isDeletingFinished = true
        Task { @MainActor in
            let failures = await store.deleteFinished(selected)
            selectedFinishedIDs = Set(failures.map(\.sessionName))
            isDeletingFinished = false
            if failures.isEmpty {
                isSelectingFinished = false
            } else {
                failurePresentation = SidebarFailurePresentation(
                    kind: .finishedDeletion,
                    message: FinishedDeletionPresentation.errorMessage(
                        for: failures))
            }
        }
    }

    private func startQuickChat() {
        guard !isStartingQuickChat else { return }
        isStartingQuickChat = true
        failurePresentation = nil
        Task { @MainActor in
            let result = await QuickChatLaunch.start(
                store: store,
                providerRawValue: quickChatProvider,
                directoryPath: quickChatDirectoryPath,
                onSessionAvailable: { sessionID in
                    selectedID = sessionID
                })
            isStartingQuickChat = false
            if let message = result.message {
                failurePresentation = SidebarFailurePresentation(
                    kind: .quickChat,
                    message: message)
            } else if let sessionID = result.sessionID {
                selectedID = sessionID
            }
        }
    }

// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
    @ViewBuilder
    private func uiE2EGeometryProbe(for session: Session) -> some View {
        if AppSettings.uiE2E != nil {
            UIE2EGeometryProbe(identifier: "session-row-\(session.id)")
        }
    }
#endif
// quality-coverage:end ui-e2e-instrumentation
}

struct SessionRow: View {
    let session: Session
    let shortcutSlot: Int?

    private var dotColor: Color {
        SessionIdentity.statusColor(for: session)
    }

    private var isCustomName: Bool {
        guard session.displayName == nil else { return false }
        // Default names end with the 8-hex project-dir digest; custom ones don't.
        return session.name.range(
            of: "-[0-9a-f]{8}$",
            options: .regularExpression) == nil
    }

    private var subtitle: String {
        var parts: [String] = []
        if isCustomName { parts.append(session.name) }
        parts.append(session.displayStatus)
        if let exit = session.exitStatus { parts.append(L10n.format("exit %d", exit)) }
        if let created = session.createdAt {
            parts.append(created.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            if session.isWaitingForUser {
                Capsule(style: .continuous)
                    .fill(Color.orange)
                    .frame(width: 3, height: 30)
                    .accessibilityHidden(true)
            }
            if let sessionColor = session.sessionColor {
                Capsule(style: .continuous)
                    .fill(SessionIdentity.color(sessionColor).opacity(
                        SessionIdentity.emphasis(for: session.effectiveStatus)))
                    .frame(width: 4, height: 34)
                    .help(L10n.format("Session color: %@", sessionColor.hex))
                    .accessibilityHidden(true)
            }
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).appFont(.body, weight: .semibold).lineLimit(1)
                    if let shortcutSlot {
                        Text(SessionShortcutPresentation.badge(slot: shortcutSlot))
                            .appFont(.caption2, weight: .semibold, design: .monospaced)
                            .foregroundStyle(Brand.indigo)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Brand.indigo.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .help(L10n.format(
                                "Switch to %@ with Command-%d",
                                session.displayTitle,
                                shortcutSlot))
                            .accessibilityHidden(true)
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
                            .background {
                                if AppSettings.uiE2E != nil {
                                    UIE2EGeometryProbe(
                                        identifier: "session-shortcut-\(session.id)",
                                        semanticLabel: "Command-\(shortcutSlot)",
                                        semanticRole: .staticText)
                                }
                            }
#endif
// quality-coverage:end ui-e2e-instrumentation
                    }
                    Text(session.provider.rawValue)
                        .appFont(.caption2)
                        .foregroundStyle(Brand.tint(for: session.provider))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Brand.tint(for: session.provider).opacity(0.35)))
                }
                Text(subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBar: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 6) {
            switch store.state {
            case .ok:
                if let updated = store.lastUpdated {
                    Text(L10n.format(
                        "Updated %@",
                        updated.formatted(date: .omitted, time: .standard)))
                }
            case .incompatible:
                Label(L10n.string("Incompatible CLI version—update detach"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .cliMissing:
                Label(L10n.string("detach is unavailable"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
// quality-coverage:begin ui-e2e-instrumentation
                    .accessibilityIdentifier("session-status-error")
#if !DEBUG
                    .background {
                        if AppSettings.uiE2E != nil {
                            UIE2EGeometryProbe(
                                identifier: "session-status-error",
                                semanticLabel: message,
                                semanticRole: .staticText,
                                semanticEnabled: false)
                        }
                    }
#endif
// quality-coverage:end ui-e2e-instrumentation
            }
            Spacer()
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // No backing material: the sidebar List already ends above this bar,
        // and an opaque bar reads as a stray strip over the sidebar glass.
    }
}
