import AppKit
import SwiftUI
import XCTest
import DetachKit
@testable import DetachApp

private struct SidebarNoopCLI: DetachCLIRunning {
    func run(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CLIResult {
        CLIResult(exitCode: 0, stdout: "", stderr: "", timedOut: false)
    }
}

@MainActor
final class SidebarViewTests: XCTestCase {
    func testBuildsWithFreshFinishedSelectionState() {
        let view = SidebarView(
            store: SessionStore(cli: SidebarNoopCLI()),
            selectedID: .constant(nil),
            navigation: MainNavigation(),
            shortcutAssignments: [],
            groups: SidebarGroupStore(defaults: UserDefaults(
                suiteName: "SidebarViewTests.\(UUID().uuidString)")!))

        _ = view.body
    }

    func testWorkingRowsHaveNeutralSelectionAndNoIdleFill() throws {
        let working = try rowSession(state: "working")
        XCTAssertNil(SessionRowPresentation.background(for: working, selected: false, isFresh: true))
        XCTAssertEqual(SessionRowPresentation.background(for: working, selected: true, isFresh: true),
                       Color.primary.opacity(0.10))
        for (reason, color) in [("input_required", SessionPalette.attention), ("answer_ready", SessionPalette.ready)] {
            let waiting = try rowSession(state: "waiting", reason: reason)
            XCTAssertEqual(SessionIdentity.statusColor(for: waiting), color)
            XCTAssertNotNil(SessionRowPresentation.background(for: waiting, selected: false, isFresh: true))
            XCTAssertNil(SessionRowPresentation.background(for: waiting, selected: false, isFresh: false))
            XCTAssertEqual(SessionRowPresentation.background(for: waiting, selected: true, isFresh: false),
                           Color.primary.opacity(0.10))
        }
    }

    func testWorkingAnimationRequiresFreshVisibleActiveStateAndMotionPermission() {
        for fresh in [false, true] {
            for visible in [false, true] {
                for active in [false, true] {
                    for reduced in [false, true] {
                        XCTAssertEqual(SessionRowPresentation.shouldAnimate(signal: .working,
                            isFresh: fresh, isVisible: visible, isActive: active, reduceMotion: reduced),
                            fresh && visible && active && !reduced)
                    }
                }
            }
        }
        for signal in [SessionStatusSignal.ready, .inputRequired, .error, .stopped, .waiting, .unknown, .new] {
            XCTAssertFalse(SessionRowPresentation.shouldAnimate(signal: signal,
                isFresh: true, isVisible: true, isActive: true, reduceMotion: false))
        }
    }

    func testEveryLifecycleAndTurnHasAnAvailableExplicitSymbol() throws {
        var row = try rowSession(state: "working")
        let lifecycles: [EffectiveStatus] = [.starting, .running, .recovering, .hung,
            .completed, .failed, .interrupted, .stopped, .recoverable, .orphaned,
            .corrupt, .collision, .unknown]
        for lifecycle in lifecycles {
            row.effectiveStatus = lifecycle
            try assertSymbol(row)
        }
        row.effectiveStatus = .running
        for turn in [AgentTurnState.working, .waiting, .interrupted, .unknown, nil] {
            row.agentTurnState = turn
            for reason in [AgentWaitingReason.answerReady, .inputRequired, .unknown, nil] {
                row.agentWaitingReason = reason
                try assertSymbol(row)
            }
        }
        row.agentTurnState = .waiting
        row.agentWaitingReason = .inputRequired
        XCTAssertEqual(SessionRowPresentation.symbol(for: row), "exclamationmark.circle")
        row.agentTurnState = nil
        XCTAssertEqual(SessionRowPresentation.status(for: row), L10n.string("new session"))
        XCTAssertEqual(SessionRowPresentation.symbol(for: row), "circle")
        XCTAssertEqual(SessionIdentity.statusColor(for: row), SessionPalette.secondary)
        XCTAssertNil(SessionRowPresentation.background(for: row, selected: false, isFresh: true))
        row.agentTurnID = "turn"
        XCTAssertEqual(SessionRowPresentation.status(for: row), L10n.string("status unavailable"))
        XCTAssertEqual(SessionRowPresentation.symbol(for: row), "minus.circle")
        let staleSymbol = SessionRowPresentation.symbol(for: row, isFresh: false)
        XCTAssertEqual(staleSymbol, "clock.arrow.circlepath")
        XCTAssertNotNil(NSImage(systemSymbolName: staleSymbol, accessibilityDescription: nil))

        let errorSymbols = [EffectiveStatus.failed, .hung, .orphaned, .corrupt, .collision].map { status in
            row.effectiveStatus = status
            return SessionRowPresentation.symbol(for: row)
        }
        XCTAssertEqual(Set(errorSymbols).count, 5, "Error causes keep distinct icons")
    }

    func testWorkingRingSpinsInCoreAnimationOnlyWhileAllowed() throws {
        let view = WorkingRingView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.lineWidth = 2
        view.layout()
        XCTAssertTrue(view.ring.superlayer === view.layer)
        XCTAssertEqual(view.ring.frame, view.bounds)
        XCTAssertEqual(view.ring.path?.boundingBox, CGRect(x: 1, y: 1, width: 14, height: 14))
        XCTAssertEqual(view.ring.lineWidth, 2)
        XCTAssertEqual(view.ring.strokeEnd, 0.72)
        XCTAssertEqual(view.ring.lineCap, .round)
        XCTAssertNil(view.ring.fillColor)
        XCTAssertNil(view.hitTest(NSPoint(x: 8, y: 8)))
        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertNil(view.ring.animation(forKey: WorkingRingView.rotationKey))

        view.isRotating = true
        let rotation = try XCTUnwrap(
            view.ring.animation(forKey: WorkingRingView.rotationKey) as? CABasicAnimation)
        XCTAssertEqual(rotation.keyPath, "transform.rotation.z")
        XCTAssertEqual(rotation.fromValue as? Int, 0)
        XCTAssertEqual(rotation.toValue as? Double, -2 * Double.pi)
        XCTAssertEqual(rotation.duration, WorkingRingView.period)
        XCTAssertEqual(rotation.repeatCount, .infinity)
        XCTAssertFalse(rotation.isRemovedOnCompletion)
        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: WorkingRingView.period)
        let drift = abs(rotation.timeOffset - phase)
        XCTAssertLessThan(min(drift, WorkingRingView.period - drift), 0.5,
                          "Rings share one clock phase")
        view.isRotating = true
        XCTAssertEqual(view.ring.animationKeys(), [WorkingRingView.rotationKey])

        view.isRotating = false
        XCTAssertNil(view.ring.animation(forKey: WorkingRingView.rotationKey))

        view.setFrameSize(NSSize(width: 20, height: 20))
        XCTAssertTrue(view.needsLayout, "A SwiftUI size change re-lays out the ring")
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.ring.path?.boundingBox, CGRect(x: 1, y: 1, width: 18, height: 18))
    }

    func testWorkingRingResolvesTheAttentionColorForItsAppearance() throws {
        let view = WorkingRingView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        for (name, hex) in [(NSAppearance.Name.aqua, 0x986700), (.darkAqua, 0xE8BE58)] {
            view.appearance = NSAppearance(named: name)
            let color = try XCTUnwrap(view.ring.strokeColor.flatMap(NSColor.init(cgColor:))?
                .usingColorSpace(.sRGB))
            XCTAssertEqual(Int((color.redComponent * 255).rounded()), (hex >> 16) & 255)
            XCTAssertEqual(Int((color.greenComponent * 255).rounded()), (hex >> 8) & 255)
            XCTAssertEqual(Int((color.blueComponent * 255).rounded()), hex & 255)
        }
    }

    private func assertSymbol(_ session: Session) throws {
        let name = SessionRowPresentation.symbol(for: session)
        XCTAssertFalse(name.contains("questionmark"))
        XCTAssertFalse(name.contains("ellipsis"))
        XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                        "Missing system symbol for \(session.effectiveStatus): \(name)")
    }

    private func rowSession(state: String, reason: String? = nil) throws -> Session {
        let reasonField = reason.map { ",\"agent_waiting_reason\":\"\($0)\"" } ?? ""
        return try XCTUnwrap(SessionListParser.parse("""
            {"schema":1,"provider":"codex","session_name":"work","name":"work",            "effective_status":"running","agent_turn_state":"\(state)"\(reasonField)}
            """).sessions.first)
    }

    func testFormatsEveryFinishedDeletionFailure() {
        let failures = [
            SessionDeletionFailure(
                sessionName: "first",
                displayTitle: "First task",
                message: "still busy"),
            SessionDeletionFailure(
                sessionName: "second",
                displayTitle: "Second task",
                message: "permission denied"),
        ]

        XCTAssertEqual(
            FinishedDeletionPresentation.errorMessage(for: failures),
            "First task: still busy\nSecond task: permission denied")
    }

    func testUsesOneTypedPresentationForSidebarFailures() {
        let deletion = SidebarFailurePresentation(
            kind: .finishedDeletion,
            message: "delete failed")
        let quickChat = SidebarFailurePresentation(
            kind: .quickChat,
            message: "start failed")

        XCTAssertEqual(
            deletion.title,
            L10n.string("Could not delete some sessions"))
        XCTAssertEqual(
            quickChat.title,
            L10n.string("Could not start quick chat"))
        XCTAssertNotEqual(deletion.id, quickChat.id)
        XCTAssertEqual(deletion.message, "delete failed")
        XCTAssertEqual(quickChat.message, "start failed")
    }

    func testFinishedSelectionReconciliationRemovesStaleIDs() {
        XCTAssertEqual(
            FinishedSelectionReconciliation.resolve(
                selectedIDs: ["kept", "removed"],
                currentIDs: ["kept", "new"],
                isSelecting: true,
                isDeleting: false),
            FinishedSelectionReconciliation(
                selectedIDs: ["kept"],
                isSelecting: true))
    }

    func testFinishedSelectionReconciliationClosesEmptyIdleSelection() {
        XCTAssertEqual(
            FinishedSelectionReconciliation.resolve(
                selectedIDs: ["removed"],
                currentIDs: [],
                isSelecting: true,
                isDeleting: false),
            FinishedSelectionReconciliation(
                selectedIDs: [],
                isSelecting: false))
    }

    func testFinishedSelectionReconciliationPreservesInFlightDeletion() {
        XCTAssertEqual(
            FinishedSelectionReconciliation.resolve(
                selectedIDs: ["removed"],
                currentIDs: [],
                isSelecting: true,
                isDeleting: true),
            FinishedSelectionReconciliation(
                selectedIDs: [],
                isSelecting: true))
    }
}
