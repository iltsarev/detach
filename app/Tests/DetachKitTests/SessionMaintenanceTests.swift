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

    private func makeSession(
        name: String,
        status: EffectiveStatus,
        reason: SessionHealthReason,
        action: SessionReconcileAction
    ) -> Session {
        Session(
            schema: 1,
            provider: .codex,
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
