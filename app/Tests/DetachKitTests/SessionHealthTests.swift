import XCTest
@testable import DetachKit

final class SessionHealthTests: XCTestCase {
    func testRuntimeLifecyclePhaseAllowsOnlyTheDeclaredGraph() {
        let allowed: [(RuntimeLifecyclePhase, [RuntimeLifecyclePhase])] = [
            (.initializing, [.initializing, .starting, .terminal]),
            (.starting, [.starting, .running, .stopping, .finalizing, .terminal]),
            (.running, [.running, .stopping, .finalizing, .terminal]),
            (.stopping, [.stopping, .running, .terminal]),
            (.finalizing, [.finalizing, .terminal]),
            (.terminal, [.terminal]),
        ]
        let phases = allowed.map(\.0)

        for (source, targets) in allowed {
            for target in phases {
                XCTAssertEqual(
                    source.allows(target),
                    targets.contains { $0 == target },
                    "\(source) -> \(target)")
            }
        }
    }

    func testInitializingPhaseIsActionlessUntilIdentityAppearsOrDies() {
        let starting = evaluate(
            status: .starting,
            provider: .unknown,
            lifecyclePhase: .initializing)
        XCTAssertEqual(starting.effectiveStatus, .starting)
        XCTAssertEqual(starting.reason, .healthy)
        XCTAssertTrue(starting.actions.isEmpty)

        let replacement = evaluate(
            status: .starting,
            token: .mismatch,
            provider: .unknown,
            lifecyclePhase: .initializing)
        XCTAssertEqual(replacement.effectiveStatus, .corrupt)
        XCTAssertEqual(replacement.reason, .runTokenMismatch)

        let dead = evaluate(
            status: .starting,
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            lifecyclePhase: .initializing)
        XCTAssertEqual(dead.effectiveStatus, .recoverable)
        XCTAssertEqual(dead.actions, [.recover, .delete])
    }

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

    func testTerminalFailureWithLiveRecordedProcessBlocksUncommittedRecovery() {
        let result = evaluate(
            status: .failed,
            tmux: .missing,
            worker: .alive,
            provider: .dead,
            recoverable: true,
            uncommittedReplacement: true,
            runtimeQuiescent: true,
            lifecyclePhase: .terminal)

        XCTAssertEqual(result.effectiveStatus, .hung)
        XCTAssertEqual(result.reason, .runtimeProcessWithoutTmux)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.reconcileAction, .none)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testQuiescentUncommittedReplacementUsesCheckpointWithoutStateRewrite() {
        for (tmux, reconcile) in [
            (TmuxHealthState.missing, SessionReconcileAction.none),
            (.dead, .removeDeadTmux),
        ] {
            let result = evaluate(
                status: .failed,
                tmux: tmux,
                worker: .dead,
                provider: .dead,
                recoverable: true,
                uncommittedReplacement: true,
                runtimeQuiescent: true,
                lifecyclePhase: .terminal)

            XCTAssertEqual(result.effectiveStatus, .recoverable, "tmux=\(tmux)")
            XCTAssertEqual(result.reason, .recoverableCheckpoint, "tmux=\(tmux)")
            XCTAssertEqual(result.actions, [.recover, .delete], "tmux=\(tmux)")
            XCTAssertEqual(result.reconcileAction, reconcile, "tmux=\(tmux)")
            XCTAssertFalse(result.cleanupEligible, "tmux=\(tmux)")
        }
    }

    func testUncommittedReplacementSeparatesUnknownRuntimeFromInvalidCheckpoint() {
        let unknown = evaluate(
            status: .failed,
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            recoverable: true,
            uncommittedReplacement: true,
            runtimeQuiescent: false,
            lifecyclePhase: .terminal)
        XCTAssertEqual(unknown.effectiveStatus, .hung)
        XCTAssertEqual(unknown.reason, .runtimeQuiescenceUnproven)
        XCTAssertTrue(unknown.actions.isEmpty)

        let invalidCheckpoint = evaluate(
            status: .failed,
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            recoverable: false,
            uncommittedReplacement: true,
            runtimeQuiescent: true,
            lifecyclePhase: .terminal)
        XCTAssertEqual(invalidCheckpoint.effectiveStatus, .orphaned)
        XCTAssertEqual(invalidCheckpoint.reason, .noRecoveryCheckpoint)
        XCTAssertEqual(invalidCheckpoint.actions, [.delete])
        XCTAssertEqual(invalidCheckpoint.reconcileAction, .markOrphaned)
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

    func testDeadTmuxRunTokenConflictCannotExposePreservedRecovery() {
        for (token, reason) in [
            (RunTokenHealthState.missing, SessionHealthReason.runTokenMissing),
            (.mismatch, .runTokenMismatch),
        ] {
            let result = evaluate(
                status: .failed,
                tmux: .dead,
                token: token,
                worker: .dead,
                provider: .dead,
                recoverable: true,
                uncommittedReplacement: true,
                runtimeQuiescent: true,
                lifecyclePhase: .terminal)

            XCTAssertEqual(result.effectiveStatus, .corrupt, "token=\(token)")
            XCTAssertEqual(result.reason, reason, "token=\(token)")
            XCTAssertTrue(result.actions.isEmpty, "token=\(token)")
            XCTAssertEqual(result.reconcileAction, .none, "token=\(token)")
            XCTAssertFalse(result.ownershipProven, "token=\(token)")
            XCTAssertFalse(result.cleanupEligible, "token=\(token)")
        }
    }

    func testMalformedMetadataNeverAuthorizesCleanupOfALivePane() {
        let result = evaluate(metadataValid: false)

        XCTAssertEqual(result.effectiveStatus, .corrupt)
        XCTAssertEqual(result.reason, .malformedMetadata)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertFalse(result.cleanupEligible)
    }

    func testMalformedMetadataWithoutALivePaneOffersNoMutation() {
        let result = evaluate(
            metadataValid: false,
            tmux: .missing,
            worker: .dead,
            provider: .dead)

        XCTAssertEqual(result.effectiveStatus, .corrupt)
        XCTAssertEqual(result.reason, .malformedMetadata)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertFalse(result.ownershipProven)
    }

    func testMalformedMetadataWithADeadManagedPaneCannotAuthorizeMutation() {
        let result = evaluate(
            metadataValid: false,
            tmux: .dead,
            worker: .dead,
            provider: .dead)

        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertFalse(result.ownershipProven)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testMalformedMetadataCannotAuthorizeActionsWhileARecordedRuntimeLives() {
        for tmux in [TmuxHealthState.missing, .dead] {
            let result = evaluate(
                metadataValid: false,
                tmux: tmux,
                worker: .alive,
                provider: .dead)

            XCTAssertEqual(result.effectiveStatus, .hung, "tmux=\(tmux)")
            XCTAssertEqual(result.reason, .runtimeProcessWithoutTmux, "tmux=\(tmux)")
            XCTAssertTrue(result.actions.isEmpty, "tmux=\(tmux)")
            XCTAssertEqual(result.reconcileAction, .none, "tmux=\(tmux)")
            XCTAssertFalse(result.cleanupEligible, "tmux=\(tmux)")
        }
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

    func testStopIntentKeepsFinishingWorkerStopped() {
        let result = evaluate(provider: .dead, stopRequested: true)

        XCTAssertEqual(result.effectiveStatus, .stopped)
        XCTAssertEqual(result.reason, .finished)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.ownershipProven)
        XCTAssertFalse(result.cleanupEligible)
    }

    func testStoppingPhaseStaysActionlessWhileRuntimeTeardownRemains() {
        let managed = evaluate(
            status: .stopped,
            tmux: .live,
            worker: .dead,
            provider: .dead,
            stopRequested: true,
            lifecyclePhase: .stopping)
        XCTAssertEqual(managed.effectiveStatus, .stopped)
        XCTAssertEqual(managed.reason, .finished)
        XCTAssertTrue(managed.actions.isEmpty)
        XCTAssertEqual(managed.reconcileAction, .none)
        XCTAssertFalse(managed.cleanupEligible)

        for tmux in [TmuxHealthState.dead, .missing] {
            let result = evaluate(
                status: .stopped,
                tmux: tmux,
                worker: .alive,
                provider: .dead,
                stopRequested: true,
                lifecyclePhase: .stopping)

            XCTAssertEqual(result.effectiveStatus, .hung, "tmux=\(tmux)")
            XCTAssertEqual(result.reason, .runtimeProcessWithoutTmux, "tmux=\(tmux)")
            XCTAssertTrue(result.actions.isEmpty, "tmux=\(tmux)")
            XCTAssertEqual(result.reconcileAction, .none, "tmux=\(tmux)")
            XCTAssertFalse(result.cleanupEligible, "tmux=\(tmux)")
        }

        let replacement = evaluate(
            token: .mismatch,
            stopRequested: true,
            lifecyclePhase: .stopping)
        XCTAssertEqual(replacement.effectiveStatus, .corrupt)
        XCTAssertEqual(replacement.reason, .runTokenMismatch)
    }

    func testCrashedStoppingPhaseConvergesAfterRuntimeIsGone() {
        for (tmux, reconcile) in [
            (TmuxHealthState.dead, SessionReconcileAction.removeDeadTmux),
            (.missing, .none),
        ] {
            let result = evaluate(
                status: .stopped,
                tmux: tmux,
                worker: .dead,
                provider: .dead,
                stopRequested: true,
                lifecyclePhase: .stopping)

            XCTAssertEqual(result.effectiveStatus, .stopped, "tmux=\(tmux)")
            XCTAssertEqual(result.reason, tmux == .dead ? .paneExited : .finished)
            XCTAssertEqual(result.actions, [.resume, .delete], "tmux=\(tmux)")
            XCTAssertEqual(result.reconcileAction, reconcile, "tmux=\(tmux)")
            XCTAssertTrue(result.cleanupEligible, "tmux=\(tmux)")
        }
    }

    func testFinalizingPhaseNeverReportsADeadProviderAsHung() {
        for (status, expected) in [
            (EffectiveStatus.completed, EffectiveStatus.completed),
            (.failed, .failed),
            (.interrupted, .interrupted),
            (.running, .interrupted),
        ] {
            let result = evaluate(
                status: status,
                tmux: .live,
                worker: .alive,
                provider: .dead,
                lifecyclePhase: .finalizing)

            XCTAssertEqual(result.effectiveStatus, expected, "status=\(status)")
            XCTAssertEqual(result.reason, .finished, "status=\(status)")
            XCTAssertTrue(result.actions.isEmpty, "status=\(status)")
            XCTAssertFalse(result.cleanupEligible, "status=\(status)")
        }
    }

    func testCrashedFinalizingPhaseOpensTerminalActions() {
        let result = evaluate(
            status: .completed,
            tmux: .missing,
            worker: .dead,
            provider: .dead,
            lifecyclePhase: .finalizing)

        XCTAssertEqual(result.effectiveStatus, .completed)
        XCTAssertEqual(result.reason, .finished)
        XCTAssertEqual(result.actions, [.resume, .delete])
        XCTAssertFalse(result.cleanupEligible)
    }

    func testStopIntentKeepsStoppedOutcomeAfterTerminalMetadata() {
        for status in [
            EffectiveStatus.interrupted,
            .stopped,
            .completed,
        ] {
            let result = evaluate(
                status: status,
                provider: .dead,
                stopRequested: true)

            XCTAssertEqual(result.effectiveStatus, .stopped)
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

    func testOwnedStartingWorkerDoesNotEnterProblemsBeforeProviderLaunch() {
        let result = evaluate(status: .starting, provider: .unknown)

        XCTAssertEqual(result.effectiveStatus, .starting)
        XCTAssertEqual(result.reason, .healthy)
        XCTAssertEqual(result.actions, [.attach, .stop])
        XCTAssertTrue(result.ownershipProven)
        XCTAssertFalse(result.cleanupEligible)

        let missingWorker = evaluate(
            status: .starting,
            worker: .unknown,
            provider: .unknown)
        XCTAssertEqual(missingWorker.effectiveStatus, .hung)
        XCTAssertEqual(missingWorker.reason, .workerPIDMissing)
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

    func testExactProcessProbeRequiresPositiveDeathEvidence() {
        let owned = SessionProcessIdentity(parentPID: 1, userID: 501)
        let foreign = SessionProcessIdentity(parentPID: 1, userID: 502)

        XCTAssertEqual(
            ExactProcessStateProbe.state(
                pid: 20,
                userID: 501,
                existence: { _ in .missing },
                identity: { _ in XCTFail("missing PID must not be inspected"); return nil }),
            .dead)
        XCTAssertEqual(
            ExactProcessStateProbe.state(
                pid: 20,
                userID: 501,
                existence: { _ in .exists },
                identity: { _ in owned }),
            .alive)
        XCTAssertEqual(
            ExactProcessStateProbe.state(
                pid: 20,
                userID: 501,
                existence: { _ in .exists },
                identity: { _ in foreign }),
            .dead)

        var confirmedExitReads = 0
        XCTAssertEqual(
            ExactProcessStateProbe.state(
                pid: 20,
                existence: { _ in
                    confirmedExitReads += 1
                    return confirmedExitReads == 1 ? .exists : .missing
                },
                identity: { _ in nil }),
            .dead)
        var unknownReads = 0
        XCTAssertEqual(
            ExactProcessStateProbe.state(
                pid: 20,
                existence: { _ in
                    unknownReads += 1
                    return unknownReads == 1 ? .exists : .unknown
                },
                identity: { _ in nil }),
            .unknown)
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
        uncommittedReplacement: Bool = false,
        runtimeQuiescent: Bool = false,
        stopRequested: Bool = false,
        lifecyclePhase: RuntimeLifecyclePhase? = nil
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
            uncommittedReplacement: uncommittedReplacement,
            runtimeQuiescent: runtimeQuiescent,
            stopRequested: stopRequested,
            lifecyclePhase: lifecyclePhase))
    }
}
