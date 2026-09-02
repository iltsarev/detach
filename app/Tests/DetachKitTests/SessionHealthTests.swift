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

    func testFinishingWorkerWithTerminalMetadataIsNotHung() {
        // After Ctrl+C the worker writes `interrupted`, publishes the hint,
        // and only then exits. The list that follows sees a live owned pane
        // with a dead provider; that is a finished run, not a hung one.
        for status in [EffectiveStatus.interrupted, .completed, .failed, .stopped] {
            let result = evaluate(status: status, provider: .dead)

            XCTAssertEqual(result.effectiveStatus, status, "\(status)")
            XCTAssertEqual(result.reason, .finished)
            XCTAssertTrue(result.ownershipProven)
            XCTAssertFalse(result.actions.contains(.attach))
            XCTAssertEqual(result.reconcileAction, .none)
        }
        // An active record with a dead provider still needs the hung signal.
        XCTAssertEqual(evaluate(status: .running, provider: .dead).effectiveStatus, .hung)
        // Only a live worker proves a finishing run; a lost or mismatched
        // worker with a live pane keeps the established hung verdict and
        // grants no cleanup on that pane.
        XCTAssertEqual(
            evaluate(status: .stopped, worker: .dead, provider: .dead).effectiveStatus, .hung)
        XCTAssertEqual(
            evaluate(status: .stopped, worker: .mismatch, provider: .dead).effectiveStatus,
            .hung)
        XCTAssertFalse(evaluate(status: .stopped, provider: .dead).cleanupEligible)
        // A provider that is merely unproven keeps the established rules.
        XCTAssertEqual(
            evaluate(status: .interrupted, provider: .mismatch).effectiveStatus, .hung)
        // Legacy metadata without runtime identity keeps its own branch.
        XCTAssertEqual(
            evaluate(
                runtimeIdentityExpected: false,
                status: .stopped,
                worker: .unknown,
                provider: .unknown,
                heartbeat: .missing).effectiveStatus,
            .running)
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

    func testStopIntentKeepsFinishingWorkerOutOfProblems() {
        let result = evaluate(provider: .dead, stopRequested: true)

        XCTAssertEqual(result.effectiveStatus, .interrupted)
        XCTAssertEqual(result.reason, .finished)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.ownershipProven)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testStopIntentKeepsActionsClosedAfterTerminalMetadata() {
        for status in [
            EffectiveStatus.interrupted,
            .stopped,
            .completed,
        ] {
            let result = evaluate(
                status: status,
                provider: .dead,
                stopRequested: true)

            XCTAssertEqual(result.effectiveStatus, .interrupted)
            XCTAssertEqual(result.reason, .finished)
            XCTAssertTrue(result.actions.isEmpty)
            XCTAssertTrue(result.ownershipProven)
            XCTAssertFalse(result.cleanupEligible)
        }
    }

    func testStopIntentNeverMasksUnprovenRuntimeIdentity() {
        XCTAssertEqual(evaluate(stopRequested: true).effectiveStatus, .running)
        XCTAssertEqual(
            evaluate(worker: .dead, provider: .dead, stopRequested: true).reason,
            .workerProcessLost)
        XCTAssertEqual(
            evaluate(worker: .mismatch, provider: .dead, stopRequested: true).reason,
            .workerPIDMismatch)
        XCTAssertEqual(
            evaluate(provider: .mismatch, stopRequested: true).reason,
            .providerPIDNotDescendant)
        XCTAssertEqual(
            evaluate(token: .mismatch, provider: .dead, stopRequested: true).reason,
            .runTokenMismatch)
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

    func testProcessInspectorFollowsOnlyTheBoundedOwnedParentChain() {
        let identities: [Int32: SessionProcessIdentity] = [
            30: SessionProcessIdentity(parentPID: 20, userID: 501),
            20: SessionProcessIdentity(parentPID: 10, userID: 501),
            10: SessionProcessIdentity(parentPID: 1, userID: 501),
        ]
        var reads: [Int32] = []

        let result = SessionProcessHealthInspector.inspect(
            tmuxState: .live,
            workerPID: "10",
            providerPID: "30",
            panePID: "10",
            userID: 501,
            lookup: { pid in
                reads.append(pid)
                return identities[pid]
            })

        XCTAssertEqual(result, SessionProcessHealth(worker: .alive, provider: .alive))
        XCTAssertEqual(Set(reads), Set([10, 20, 30]))
        XCTAssertEqual(reads.count, 3, "one record must read each PID at most once")
    }

    func testProcessInspectorRejectsWrongPaneAndForeignOwnership() {
        let owned: [Int32: SessionProcessIdentity] = [
            10: SessionProcessIdentity(parentPID: 1, userID: 501),
            30: SessionProcessIdentity(parentPID: 10, userID: 501),
        ]
        let paneMismatch = SessionProcessHealthInspector.inspect(
            tmuxState: .live,
            workerPID: "10",
            providerPID: "30",
            panePID: "99",
            userID: 501,
            lookup: { owned[$0] })
        let foreign = SessionProcessHealthInspector.inspect(
            tmuxState: .missing,
            workerPID: "10",
            providerPID: "30",
            panePID: "-",
            userID: 502,
            lookup: { owned[$0] })

        XCTAssertEqual(
            paneMismatch,
            SessionProcessHealth(worker: .mismatch, provider: .mismatch))
        XCTAssertEqual(foreign, SessionProcessHealth(worker: .dead, provider: .dead))
    }

    func testProcessInspectorKeepsInvalidPIDsUnknownAndBoundsCycles() {
        var reads = 0
        let invalid = SessionProcessHealthInspector.inspect(
            tmuxState: .missing,
            workerPID: "-",
            providerPID: "0",
            panePID: "not-a-pid",
            userID: 501,
            lookup: { _ in reads += 1; return nil })
        let cyclic = SessionProcessHealthInspector.inspect(
            tmuxState: .missing,
            workerPID: "10",
            providerPID: "20",
            panePID: "-",
            userID: 501,
            lookup: { pid in
                reads += 1
                return SessionProcessIdentity(
                    parentPID: pid == 20 ? 21 : 20,
                    userID: 501)
            })

        XCTAssertEqual(invalid, SessionProcessHealth(worker: .unknown, provider: .unknown))
        XCTAssertEqual(cyclic, SessionProcessHealth(worker: .alive, provider: .mismatch))
        XCTAssertLessThanOrEqual(reads, 3, "cycle identities must stay cached")
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
        agentSessionKnown: Bool = true,
        stopRequested: Bool = false
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
            agentSessionKnown: agentSessionKnown,
            stopRequested: stopRequested))
    }
}
