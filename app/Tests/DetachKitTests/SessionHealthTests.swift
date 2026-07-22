import XCTest
@testable import DetachKit

final class SessionHealthTests: XCTestCase {
    func testForeignTmuxCollisionNeverOffersAnAction() {
        let result = evaluate(tmux: .foreign)

        XCTAssertEqual(result.effectiveStatus, .collision)
        XCTAssertEqual(result.reason, .foreignTmux)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertFalse(result.ownershipProven)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testLongProviderTurnRemainsRunningWhenOwnedProcessesAreAlive() {
        let result = evaluate(
            heartbeat: .fresh,
            checkpoint: .stale)

        XCTAssertEqual(result.effectiveStatus, .running)
        XCTAssertEqual(result.reason, .checkpointStale)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
    }

    func testStaleHeartbeatAloneNeverCallsALiveProviderHung() {
        let result = evaluate(heartbeat: .stale)

        XCTAssertEqual(result.effectiveStatus, .running)
        XCTAssertEqual(result.reason, .heartbeatStale)
        XCTAssertFalse(result.heartbeatFresh)
    }

    func testLegacyLiveSessionWithoutRuntimeIdentityRemainsRunning() {
        let result = evaluate(
            runtimeIdentityExpected: false,
            worker: .unknown,
            provider: .unknown,
            heartbeat: .missing)

        XCTAssertEqual(result.effectiveStatus, .running)
        XCTAssertEqual(result.reason, .heartbeatMissing)
        XCTAssertEqual(result.actions, [.attach, .stop])
    }

    func testLegacyLiveSessionPreservesAnActiveMetaStatusAndReportsStaleCheckpoint() {
        let result = evaluate(
            runtimeIdentityExpected: false,
            status: .recovering,
            worker: .unknown,
            provider: .unknown,
            heartbeat: .missing,
            checkpoint: .stale)

        XCTAssertEqual(result.effectiveStatus, .recovering)
        XCTAssertEqual(result.reason, .checkpointStale)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
    }

    func testRetainedDeadPaneBecomesRecoverableAndReconcileable() {
        let result = evaluate(
            tmux: .dead,
            worker: .dead,
            provider: .dead,
            recoverable: true)

        XCTAssertEqual(result.effectiveStatus, .recoverable)
        XCTAssertEqual(result.reason, .recoverableCheckpoint)
        XCTAssertEqual(result.actions, [.recover, .delete])
        XCTAssertEqual(result.reconcileAction, .removeDeadTmuxAndMarkRecoverable)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testTmuxServerLossWithoutCheckpointBecomesOrphaned() {
        let result = evaluate(
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            recoverable: false)

        XCTAssertEqual(result.effectiveStatus, .orphaned)
        XCTAssertEqual(result.reason, .noRecoveryCheckpoint)
        XCTAssertEqual(result.actions, [.delete])
        XCTAssertEqual(result.reconcileAction, .markOrphaned)
        XCTAssertTrue(result.cleanupEligible)
    }

    func testMissingTmuxWithARecoverableCheckpointProducesDeclarativeRepair() {
        let result = evaluate(
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            recoverable: true)

        XCTAssertEqual(result.effectiveStatus, .recoverable)
        XCTAssertEqual(result.reason, .recoverableCheckpoint)
        XCTAssertEqual(result.actions, [.recover, .delete])
        XCTAssertEqual(result.reconcileAction, .markRecoverable)
    }

    func testDeadTmuxWithoutCheckpointProducesRemovalAndOrphanRepair() {
        let result = evaluate(
            tmux: .dead,
            worker: .dead,
            provider: .dead,
            recoverable: false)

        XCTAssertEqual(result.effectiveStatus, .orphaned)
        XCTAssertEqual(result.reason, .noRecoveryCheckpoint)
        XCTAssertEqual(result.actions, [.delete])
        XCTAssertEqual(result.reconcileAction, .removeDeadTmuxAndMarkOrphaned)
        XCTAssertTrue(result.cleanupEligible)
    }

    func testMissingTmuxNeverInterruptsARecordedLiveRuntime() {
        let result = evaluate(
            tmux: .missing,
            worker: .alive,
            provider: .dead)

        XCTAssertEqual(result.effectiveStatus, .hung)
        XCTAssertEqual(result.reason, .runtimeProcessWithoutTmux)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertFalse(result.ownershipProven)
    }

    func testWorkerCrashNeverRecoversWhileAnUnprovenProviderPIDIsStillAlive() {
        let result = evaluate(
            tmux: .dead,
            worker: .dead,
            provider: .mismatch,
            recoverable: true)

        XCTAssertEqual(result.effectiveStatus, .hung)
        XCTAssertEqual(result.reason, .runtimeProcessWithoutTmux)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertFalse(result.cleanupEligible)
        XCTAssertEqual(result.reconcileAction, .none)
    }

    func testStaleRunTokenIsCorruptButManagedPaneCanStillBeAttachedOrStopped() {
        let result = evaluate(token: .mismatch)

        XCTAssertEqual(result.effectiveStatus, .corrupt)
        XCTAssertEqual(result.reason, .runTokenMismatch)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testMalformedMetadataNeverAuthorizesCleanupOfALivePane() {
        let result = evaluate(metadataValid: false)

        XCTAssertEqual(result.effectiveStatus, .corrupt)
        XCTAssertEqual(result.reason, .malformedMetadata)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertFalse(result.cleanupEligible)
    }

    func testMalformedMetadataWithoutALivePaneOnlyOffersDelete() {
        let result = evaluate(metadataValid: false, tmux: .missing)

        XCTAssertEqual(result.effectiveStatus, .corrupt)
        XCTAssertEqual(result.reason, .malformedMetadata)
        XCTAssertEqual(result.actions, [.delete])
        XCTAssertFalse(result.ownershipProven)
    }

    func testMalformedMetadataWithADeadManagedPaneProvesOwnership() {
        let result = evaluate(metadataValid: false, tmux: .dead)

        XCTAssertEqual(result.actions, [.delete])
        XCTAssertTrue(result.ownershipProven)
    }

    func testMissingRunTokenIsCorruptButManagedPaneRemainsControllable() {
        let result = evaluate(token: .missing)

        XCTAssertEqual(result.effectiveStatus, .corrupt)
        XCTAssertEqual(result.reason, .runTokenMissing)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
    }

    func testLostProviderProcessIsHungOnlyWithProvenWorkerIdentity() {
        let result = evaluate(provider: .dead)

        XCTAssertEqual(result.effectiveStatus, .hung)
        XCTAssertEqual(result.reason, .providerProcessLost)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
    }

    func testForeignProviderPIDIsNeverTreatedAsOwned() {
        let result = evaluate(provider: .mismatch)

        XCTAssertEqual(result.effectiveStatus, .hung)
        XCTAssertEqual(result.reason, .providerPIDNotDescendant)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testEveryInvalidWorkerIdentityHasItsOwnReason() {
        let cases: [(ProcessHealthState, SessionHealthReason)] = [
            (.unknown, .workerPIDMissing),
            (.dead, .workerProcessLost),
            (.mismatch, .workerPIDMismatch),
        ]

        for (state, expectedReason) in cases {
            let result = evaluate(worker: state)
            XCTAssertEqual(result.effectiveStatus, .hung, "worker=\(state)")
            XCTAssertEqual(result.reason, expectedReason, "worker=\(state)")
            XCTAssertEqual(result.actions, [.attach, .stop], "worker=\(state)")
            XCTAssertTrue(result.ownershipProven, "worker=\(state)")
        }
    }

    func testMissingProviderPIDIsDiagnosedSeparately() {
        let result = evaluate(provider: .unknown)

        XCTAssertEqual(result.effectiveStatus, .hung)
        XCTAssertEqual(result.reason, .providerPIDMissing)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
    }

    func testFreshOwnedRuntimeReportsHealthy() {
        let result = evaluate()

        XCTAssertEqual(result.effectiveStatus, .running)
        XCTAssertEqual(result.reason, .healthy)
        XCTAssertTrue(result.heartbeatFresh)
        XCTAssertTrue(result.checkpointFresh)
    }

    func testMissingHeartbeatIsDiagnosticForAnOwnedLiveRuntime() {
        let result = evaluate(heartbeat: .missing)

        XCTAssertEqual(result.effectiveStatus, .running)
        XCTAssertEqual(result.reason, .heartbeatMissing)
        XCTAssertFalse(result.heartbeatFresh)
    }

    func testFinishedSessionsUseResumeOnlyWhenAgentIdentityIsKnown() {
        let resumable = evaluate(
            status: .stopped,
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            agentSessionKnown: true)
        let unknown = evaluate(
            status: .failed,
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            agentSessionKnown: false)

        XCTAssertEqual(resumable.effectiveStatus, .stopped)
        XCTAssertEqual(resumable.reason, .finished)
        XCTAssertEqual(resumable.actions, [.resume, .delete])
        XCTAssertTrue(resumable.cleanupEligible)
        XCTAssertEqual(unknown.effectiveStatus, .failed)
        XCTAssertEqual(unknown.actions, [.delete])
        XCTAssertFalse(unknown.cleanupEligible)
    }

    func testFinishedRecoverableSessionKeepsRecoverAction() {
        let result = evaluate(
            status: .recoverable,
            tmux: .missing,
            worker: .dead,
            provider: .dead)

        XCTAssertEqual(result.effectiveStatus, .recoverable)
        XCTAssertEqual(result.actions, [.recover, .delete])
        XCTAssertFalse(result.cleanupEligible)
    }

    func testExitedRetainedPaneIsRemovedButPreservesFinishedStatus() {
        let result = evaluate(
            status: .stopped,
            tmux: .dead,
            worker: .dead,
            provider: .dead)

        XCTAssertEqual(result.effectiveStatus, .stopped)
        XCTAssertEqual(result.reason, .paneExited)
        XCTAssertEqual(result.reconcileAction, .removeDeadTmux)
        XCTAssertEqual(result.actions, [.resume, .delete])
        XCTAssertTrue(result.cleanupEligible)
    }

    func testTypedHealthCommandUsesTheSameStateMachine() throws {
        let data = try DetachStateCommand.run(arguments: [
            "health", "evaluate",
            "--metadata-valid", "true",
            "--runtime-identity-expected", "true",
            "--meta-status", "running",
            "--tmux", "live",
            "--run-token", "match",
            "--worker", "alive",
            "--provider-process", "alive",
            "--heartbeat", "fresh",
            "--checkpoint", "stale",
            "--checkpoint-recoverable", "true",
            "--agent-session-known", "true",
        ])
        let result = try JSONDecoder().decode(SessionHealthAssessment.self, from: data)

        XCTAssertEqual(result.effectiveStatus, .running)
        XCTAssertEqual(result.reason, .checkpointStale)
    }

    private func evaluate(
        metadataValid: Bool = true,
        runtimeIdentityExpected: Bool = true,
        status: EffectiveStatus = .running,
        tmux: TmuxHealthState = .live,
        token: RunTokenHealthState = .match,
        worker: ProcessHealthState = .alive,
        provider: ProcessHealthState = .alive,
        heartbeat: FreshnessState = .fresh,
        checkpoint: FreshnessState = .fresh,
        recoverable: Bool = true,
        agentSessionKnown: Bool = true
    ) -> SessionHealthAssessment {
        SessionHealthEvaluator.evaluate(SessionHealthEvidence(
            metadataValid: metadataValid,
            runtimeIdentityExpected: runtimeIdentityExpected,
            metaStatus: status,
            tmuxState: tmux,
            runTokenState: token,
            workerState: worker,
            providerState: provider,
            heartbeatFreshness: heartbeat,
            checkpointFreshness: checkpoint,
            checkpointRecoverable: recoverable,
            agentSessionKnown: agentSessionKnown))
    }
}
