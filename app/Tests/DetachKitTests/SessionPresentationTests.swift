import XCTest
@testable import DetachKit

final class SessionPresentationTests: XCTestCase {
    func make(
        _ status: EffectiveStatus,
        uuid: String? = "u",
        project: String? = "/tmp/proj",
        displayName: String? = nil,
        turnState: AgentTurnState? = nil,
        powerState: PowerProtectionState? = nil
    ) -> Session {
        let turnStateJSON = turnState.map { "\"\($0.rawValue)\"" } ?? "null"
        let powerStateJSON = powerState.map { "\"\($0.rawValue)\"" } ?? "null"
        let displayNameJSON = displayName.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"provider":"claude","session_name":"detach-claude-proj-abcd1234","name":"proj-abcd1234","display_name":\(displayNameJSON),"effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":\(uuid.map { "\"\($0)\"" } ?? "null"),"project_dir":\(project.map { "\"\($0)\"" } ?? "null"),"created_at":null,"last_checkpoint_at":null,"exit_status":null,"finished_at":null,"agent_turn_state":\(turnStateJSON),"agent_turn_id":"turn","power_protection_state":\(powerStateJSON)}
        """
        return SessionListParser.parse(json).sessions[0]
    }

    func testSections() {
        XCTAssertEqual(
            SessionSection.allCases,
            [.answerReady, .active, .finished, .problems])
        XCTAssertEqual(make(.running).section, .active)
        XCTAssertEqual(make(.starting).section, .active)
        XCTAssertEqual(make(.recovering).section, .active)
        XCTAssertEqual(make(.completed).section, .finished)
        XCTAssertEqual(make(.stopped).section, .finished)
        XCTAssertEqual(make(.failed).section, .finished)
        XCTAssertEqual(make(.recoverable).section, .problems)
        XCTAssertEqual(make(.collision).section, .problems)
    }

    func testSectionDisplayNamesAreStableAndLocalized() {
        XCTAssertEqual(SessionSection.answerReady.displayName, L10n.string("Answer ready"))
        XCTAssertEqual(SessionSection.active.displayName, L10n.string("Working"))
        XCTAssertEqual(SessionSection.finished.displayName, L10n.string("Finished"))
        XCTAssertEqual(SessionSection.problems.displayName, L10n.string("Problems"))
    }

    func testEveryEffectiveStatusHasConsistentLifecyclePresentation() {
        let cases: [(
            EffectiveStatus, String, Bool, SessionSection
        )] = [
            (.starting, "starting", true, .active),
            (.running, "running", true, .active),
            (.recovering, "recovering", true, .active),
            (.hung, "hung", true, .problems),
            (.completed, "completed", false, .finished),
            (.failed, "failed", false, .finished),
            (.interrupted, "interrupted", false, .finished),
            (.stopped, "stopped", false, .finished),
            (.recoverable, "recoverable", false, .problems),
            (.orphaned, "orphaned", false, .problems),
            (.corrupt, "corrupt", false, .problems),
            (.collision, "name collision", false, .problems),
            (.unknown, "unknown", false, .problems),
        ]

        for (status, displayStatus, isLive, section) in cases {
            let session = make(status)
            XCTAssertEqual(session.displayStatus, L10n.string(displayStatus), "status=\(status)")
            XCTAssertEqual(session.isLive, isLive, "status=\(status)")
            XCTAssertEqual(session.section, section, "status=\(status)")
            XCTAssertEqual(session.availableActions, [], "status=\(status)")
            XCTAssertNil(session.healthActions, "status=\(status)")
        }
    }

    func testOmittedAndNullHealthActionsOfferNoMutations() {
        XCTAssertNil(make(.running).healthActions)
        XCTAssertEqual(make(.running).availableActions, [])
        XCTAssertEqual(make(.completed).availableActions, [])
        XCTAssertEqual(make(.recoverable).availableActions, [])
        XCTAssertFalse(make(.completed).canDeleteFromFinishedList)

        let nullActions = #"{"schema":1,"provider":"codex","session_name":"detach-codex-null","name":"null","effective_status":"running","health_actions":null}"#
        let session = SessionListParser.parse(nullActions).sessions[0]
        XCTAssertNil(session.healthActions)
        XCTAssertEqual(session.availableActions, [])
    }

    func testTypedHealthActionsAreTheOnlyMutations() {
        var session = make(.running)
        session.healthActions = [.attach, .stop]
        XCTAssertEqual(session.availableActions, [.attach, .stop])
        session.healthActions = [.resume, .delete]
        XCTAssertEqual(session.availableActions, [.resume, .delete])
        session.healthActions = []
        XCTAssertEqual(session.availableActions, [])
    }

    func testFinishedBulkDeleteUsesTypedDeletePermission() {
        var completed = make(.completed)
        completed.healthActions = [.resume, .delete]
        var failed = make(.failed)
        failed.healthActions = [.resume, .delete]
        var interrupted = make(.interrupted)
        interrupted.healthActions = [.resume, .delete]
        var stopped = make(.stopped)
        stopped.healthActions = [.resume, .delete]
        var running = make(.running)
        running.healthActions = [.attach, .stop]
        var recoverable = make(.recoverable)
        recoverable.healthActions = [.recover, .delete]

        XCTAssertTrue(completed.canDeleteFromFinishedList)
        XCTAssertTrue(failed.canDeleteFromFinishedList)
        XCTAssertTrue(interrupted.canDeleteFromFinishedList)
        XCTAssertTrue(stopped.canDeleteFromFinishedList)
        XCTAssertFalse(running.canDeleteFromFinishedList)
        XCTAssertFalse(recoverable.canDeleteFromFinishedList)

        var blocked = make(.completed)
        blocked.healthActions = []
        XCTAssertFalse(blocked.canDeleteFromFinishedList)
        XCTAssertFalse(make(.completed).canDeleteFromFinishedList)
    }

    func testTypedHealthActionsOverrideLegacyStatusHeuristics() throws {
        let line = #"{"schema":1,"provider":"codex","session_name":"detach-codex-orphan","name":"orphan","effective_status":"hung","health_reason":"runtime_process_without_tmux","health_actions":[],"reconcile_action":"none","ownership_proven":false,"cleanup_eligible":false}"#
        let session = try XCTUnwrap(SessionListParser.parse(line).sessions.first)

        XCTAssertTrue(session.isLive)
        XCTAssertEqual(session.section, .problems)
        XCTAssertEqual(session.availableActions, [])
        XCTAssertEqual(session.healthReason, .runtimeProcessWithoutTmux)
        XCTAssertNotNil(session.healthReasonLabel)
    }

    func testEveryHealthReasonHasAnExplicitDiagnosticLabelPolicy() {
        let reasons: [SessionHealthReason] = [
            .healthy, .finished, .checkpointStale, .heartbeatStale, .heartbeatMissing,
            .tmuxServerMissing, .paneExited, .foreignTmux, .malformedMetadata,
            .runTokenMissing, .runTokenMismatch, .workerPIDMissing, .workerProcessLost,
            .workerPIDMismatch, .providerPIDMissing, .providerProcessLost,
            .providerPIDNotDescendant, .runtimeProcessWithoutTmux,
            .runtimeQuiescenceUnproven, .recoverableCheckpoint, .noRecoveryCheckpoint,
        ]

        for reason in reasons {
            var session = make(.running)
            session.healthReason = reason
            if reason == .healthy || reason == .finished {
                XCTAssertNil(session.healthReasonLabel, "reason=\(reason)")
            } else {
                XCTAssertFalse(session.healthReasonLabel?.isEmpty ?? true, "reason=\(reason)")
            }
        }
        XCTAssertNil(make(.running).healthReasonLabel)
    }

    func testUnprovenRuntimeQuiescenceHasAnAccurateDiagnosticLabel() {
        var session = make(.hung)
        session.healthReason = .runtimeQuiescenceUnproven

        XCTAssertEqual(
            session.healthReasonLabel,
            L10n.string("Detach could not confirm that the replacement runtime stopped."))
    }

    func testContextUsageHandlesMissingInvalidAndSaturatedWindows() {
        var session = make(.running)
        XCTAssertNil(session.contextFraction)
        XCTAssertNil(session.contextSummary)

        session.contextUsedTokens = 12_400
        XCTAssertNil(session.contextFraction)
        XCTAssertEqual(session.contextSummary, L10n.format("%@ tokens", "12k"))

        session.contextWindow = 100_000
        XCTAssertEqual(session.contextFraction ?? -1, 0.124, accuracy: 0.000_001)
        XCTAssertEqual(
            session.contextSummary,
            L10n.format("%@ · %@%% available", "12k", "88"))

        session.contextUsedTokens = 150_000
        XCTAssertEqual(session.contextFraction, 1)
        XCTAssertEqual(
            session.contextSummary,
            L10n.format("%@ · %@%% available", "150k", "0"))

        session.contextWindow = 0
        XCTAssertNil(session.contextFraction)
        XCTAssertEqual(session.contextSummary, L10n.format("%@ tokens", "150k"))
    }

    func testDisplayTitle() {
        XCTAssertEqual(
            make(.running, project: "/Users/me/dev/harness", displayName: "Rev (ai)").displayTitle,
            "Rev (ai)")
        XCTAssertEqual(make(.running, project: "/Users/me/dev/harness").displayTitle, "harness")
        XCTAssertEqual(make(.corrupt, project: nil).displayTitle, "proj-abcd1234")
    }

    func testWaitingTurnHasAttentionStatusWhileRemainingActive() {
        var waiting = make(.running, turnState: .waiting)
        XCTAssertTrue(waiting.isWaitingForUser)
        XCTAssertTrue(waiting.isLive)
        XCTAssertEqual(waiting.displayStatus, L10n.string("answer ready"))
        XCTAssertEqual(waiting.section, .answerReady)
        XCTAssertEqual(waiting.availableActions, [])
        waiting.healthActions = [.attach, .stop]
        XCTAssertEqual(waiting.availableActions, [.attach, .stop])
    }

    func testAnswerReadySectionDoesNotChangeSessionLifecycle() {
        XCTAssertEqual(make(.running, turnState: .working).section, .active)
        XCTAssertTrue(make(.starting, turnState: .waiting).isLive)
        XCTAssertEqual(make(.starting, turnState: .waiting).section, .active)
        XCTAssertFalse(make(.completed, turnState: .waiting).isLive)
        XCTAssertEqual(make(.completed, turnState: .waiting).section, .finished)
    }

    func testPowerStatusUsesExplicitReadableLabels() {
        XCTAssertEqual(
            make(.running, powerState: .protected).powerProtectionLabel,
            L10n.string("Mac stays awake"))
        XCTAssertEqual(
            make(.running, powerState: .allowed).powerProtectionLabel,
            L10n.string("Mac can sleep"))
        XCTAssertEqual(
            make(.running, powerState: .lowBattery).powerProtectionLabel,
            L10n.string("Mac can sleep: low battery"))
        XCTAssertEqual(
            make(.running, powerState: .temperature).powerProtectionLabel,
            L10n.string("Mac can sleep: temperature"))
        XCTAssertEqual(
            make(.running, powerState: .unavailable).powerProtectionLabel,
            L10n.string("Sleep protection unavailable"))
        XCTAssertEqual(
            make(.running).powerProtectionLabel,
            L10n.string("Sleep status unknown"))
    }

    func testSessionPowerChipFollowsHeartbeatNotListRow() {
        let session = make(.running, powerState: .protected)
        XCTAssertEqual(session.powerProtectionState, .protected)
        XCTAssertEqual(session.powerProtectionLabel, L10n.string("Mac stays awake"))

        let displayed = SessionPowerPresentation.displayedState(heartbeat: .allowed)
        XCTAssertEqual(displayed, .allowed)
        XCTAssertEqual(
            SessionPowerPresentation.label(for: displayed),
            L10n.string("Mac can sleep"))
        XCTAssertEqual(
            SessionPowerPresentation.systemImage(for: displayed),
            "moon.zzz")
        XCTAssertNotEqual(
            SessionPowerPresentation.label(for: displayed),
            session.powerProtectionLabel)
    }

    func testPowerStatusCoversTransitionsAndEverySystemImage() {
        XCTAssertEqual(
            make(.running, powerState: .transitioning).powerProtectionLabel,
            L10n.string("Enabling sleep protection"))

        let images: [(PowerProtectionState?, String)] = [
            (.protected, "shield.fill"),
            (.allowed, "moon.zzz"),
            (.transitioning, "arrow.triangle.2.circlepath"),
            (.lowBattery, "battery.25"),
            (.temperature, "thermometer.high"),
            (.unavailable, "exclamationmark.triangle"),
            (.unknown, "questionmark.circle"),
            (nil, "questionmark.circle"),
        ]
        for (state, expected) in images {
            XCTAssertEqual(
                make(.running, powerState: state).powerProtectionSystemImage,
                expected)
        }
    }
}
