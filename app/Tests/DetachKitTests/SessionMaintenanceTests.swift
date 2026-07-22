import XCTest
@testable import DetachKit

final class SessionMaintenanceTests: XCTestCase {
    func testReconcilePlanIncludesOnlySafeDeclarativeRepairs() throws {
        let sessions = [
            makeSession(
                name: "detach-codex-dead",
                status: .recoverable,
                reason: .recoverableCheckpoint,
                action: .removeDeadTmuxAndMarkRecoverable),
            makeSession(
                name: "detach-codex-live",
                status: .running,
                reason: .healthy,
                action: .none),
        ]
        let inventory = try sessions.map { session in
            String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        }.joined(separator: "\n")

        let data = try DetachStateCommand.run(
            arguments: ["maintenance", "reconcile", "-"],
            standardInput: Data(inventory.utf8))
        let plan = try JSONDecoder().decode(SessionMaintenancePlan.self, from: data)

        XCTAssertTrue(plan.dryRun)
        XCTAssertEqual(plan.items.map(\.sessionName), ["detach-codex-dead"])
        XCTAssertEqual(plan.items.first?.action, .removeDeadTmuxAndMarkRecoverable)
    }

    func testPlannerRejectsAnyMalformedInventoryLine() {
        XCTAssertThrowsError(try SessionMaintenancePlanner.reconcile(
            inventory: Data("not-json\n".utf8)
        )) { error in
            XCTAssertEqual(error as? StorageInspectionError, .invalidInventory)
        }
    }

    func testPlannerDropsIncompleteEvidenceAndSortsRepairsDeterministically() throws {
        var missingReason = makeSession(
            name: "detach-codex-missing-reason",
            status: .orphaned,
            reason: .noRecoveryCheckpoint,
            action: .markOrphaned)
        missingReason.healthReason = nil
        let sessions = [
            makeSession(
                provider: .codex,
                name: "detach-codex-zeta",
                status: .recoverable,
                reason: .recoverableCheckpoint,
                action: .markRecoverable),
            makeSession(
                provider: .claude,
                name: "detach-claude-alpha",
                status: .orphaned,
                reason: .noRecoveryCheckpoint,
                action: .markOrphaned),
            makeSession(
                provider: .codex,
                name: "detach-codex-alpha",
                status: .recoverable,
                reason: .recoverableCheckpoint,
                action: .removeDeadTmuxAndMarkRecoverable),
            missingReason,
        ]
        let inventory = try sessions.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")

        let plan = try SessionMaintenancePlanner.reconcile(inventory: Data(inventory.utf8))

        XCTAssertEqual(plan.items.map(\.provider), [.claude, .codex, .codex])
        XCTAssertEqual(plan.items.map(\.sessionName), [
            "detach-claude-alpha", "detach-codex-alpha", "detach-codex-zeta",
        ])
    }

    private func makeSession(
        provider: Provider = .codex,
        name: String,
        status: EffectiveStatus,
        reason: SessionHealthReason,
        action: SessionReconcileAction
    ) -> Session {
        Session(
            schema: 1,
            provider: provider,
            sessionName: name,
            name: name,
            effectiveStatus: status,
            metaStatus: "running",
            agentSessionId: nil,
            projectDir: "/tmp/project",
            createdAt: nil,
            lastCheckpointAt: nil,
            exitStatus: nil,
            finishedAt: nil,
            model: nil,
            contextUsedTokens: nil,
            contextWindow: nil,
            agentTurnState: nil,
            agentTurnID: nil,
            sessionColor: nil,
            powerProtectionState: nil,
            healthReason: reason,
            healthActions: [.recover, .delete],
            reconcileAction: action,
            ownershipProven: true,
            cleanupEligible: false,
            workerPID: nil,
            providerPID: nil,
            workerHeartbeatAt: nil,
            heartbeatFresh: false,
            checkpointFresh: true)
    }
}
