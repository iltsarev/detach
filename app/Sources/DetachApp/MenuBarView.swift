import AppKit
import DetachKit
import SwiftUI

/// The status-item label: the Detach template glyph. Shape encodes the state
/// (solid mark + filled dot = the Mac is held awake, dimmed = it can sleep,
/// "!" badge = needs attention, outline = unknown); the optional count shows
/// active sessions.
struct MenuBarLabel: View {
    let installation: InstallationStore
    let sessionStore: SessionStore
    let showsSessionCount: Bool

    var body: some View {
        let icon = MenuBarPresentation(
            heartbeat: installation.watchdogHeartbeat,
            sessions: sessionStore.sessions,
            helperStatus: installation.powerHelperStatus,
            watchdogStatus: installation.watchdogStatus,
            distributionMatchesBundle: installation.distributionMatchesBundle,
            showsSessionCount: showsSessionCount).icon
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGlyph.image(for: icon))
            if let text = countBadge(for: icon) {
                Text(text)
            }
        }
        .accessibilityLabel(accessibilityText(for: icon))
    }

    private func countBadge(for icon: MenuBarPresentation.Icon) -> String? {
        if case let .active(sessionCount) = icon, let sessionCount, sessionCount > 0 {
            return "\(sessionCount)"
        }
        return nil
    }

    private func accessibilityText(for icon: MenuBarPresentation.Icon) -> String {
        switch icon {
        case .active: L10n.string("Mac stays awake")
        case .canSleep: L10n.string("Mac can sleep")
        case .lowBattery: L10n.string("Mac can sleep: low battery")
        case .attention: L10n.string("Sleep protection unavailable")
        case .unknown: L10n.string("Sleep status unknown")
        }
    }
}

/// Native menu content. The header answers the main question in words; the
/// icon is secondary by contract.
struct MenuBarMenu: View {
    let installation: InstallationStore
    let sessionStore: SessionStore
    let showsSessionCount: Bool
    @ObservedObject var navigation: MainNavigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var presentation: MenuBarPresentation {
        MenuBarPresentation(
            heartbeat: installation.watchdogHeartbeat,
            sessions: sessionStore.sessions,
            helperStatus: installation.powerHelperStatus,
            watchdogStatus: installation.watchdogStatus,
            distributionMatchesBundle: installation.distributionMatchesBundle,
            showsSessionCount: showsSessionCount)
    }

    var body: some View {
        let presentation = presentation

        Text(presentation.headerText)
        if let problem = presentation.problem {
            Button(problemTitle(problem)) { handle(problem) }
        }
        Divider()
        ForEach(presentation.sessions) { entry in
            Button(sessionLine(entry)) {
                openDashboard(selecting: entry.id)
            }
        }
        if presentation.hiddenSessionCount > 0 {
            Button(L10n.format(
                "Show %d more in Detach…", presentation.hiddenSessionCount)) {
                openDashboard(selecting: nil)
            }
        }
        if !presentation.sessions.isEmpty { Divider() }
        Button(L10n.string("Open Detach")) { openDashboard(selecting: nil) }
        Button(L10n.string("New Session…")) {
            navigation.requestsNewSession = true
            openDashboard(selecting: nil)
        }
        Divider()
        Button(L10n.string("Settings…")) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        // An honest Quit: the icon disappears; the tmux server, provider,
        // checkpoints, and sleep protection continue without the app.
        Button(L10n.string("Quit Detach")) {
            NSApp.terminate(nil)
        }
    }

    private func sessionLine(_ entry: MenuBarPresentation.SessionEntry) -> String {
        let state = entry.answerReady
            ? L10n.string("answer ready")
            : L10n.string("working")
        return "\(entry.title) — \(state)"
    }

    private func problemTitle(
        _ problem: MenuBarPresentation.ProblemAction
    ) -> String {
        switch problem {
        case .openSystemSettings: L10n.string("Open System Settings")
        case .openDetach: L10n.string("Open Detach to Repair Protection")
        }
    }

    private func handle(_ problem: MenuBarPresentation.ProblemAction) {
        switch problem {
        case .openSystemSettings:
            installation.openPowerHelperApprovalSettings()
        case .openDetach:
            openDashboard(selecting: nil)
        }
    }

    private func openDashboard(selecting id: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let id { navigation.requestedSessionID = id }
        openWindow(id: "main")
    }
}
