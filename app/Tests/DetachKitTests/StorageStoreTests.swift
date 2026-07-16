import XCTest
@testable import DetachKit

@MainActor
final class StorageStoreTests: XCTestCase {
    func testRefreshDecodesStorageReport() async throws {
        let cli = FakeCLI()
        let report = makeReport([makeSession(name: "detach-codex-one", bytes: 4_096)])
        cli.responses["storage --json"] = ok(try encode(report))
        let store = StorageStore(cli: cli)

        await store.refresh()

        XCTAssertEqual(store.state, .ok)
        XCTAssertEqual(store.report, report)
        XCTAssertNotNil(store.lastUpdated)
    }

    func testCleanupRefusesChangedPreviewBeforeDeletingAnything() async throws {
        let cli = FakeCLI()
        let expected = makeSession(name: "detach-codex-one", bytes: 4_096)
        cli.responses["storage --json"] = ok(try encode(makeReport([expected])))
        let store = StorageStore(cli: cli)
        await store.refresh()

        let changed = makeSession(name: expected.sessionName, bytes: 8_192)
        cli.responses["storage --json"] = ok(try encode(makeReport([changed])))
        let failures = await store.cleanup(expected: [expected])

        XCTAssertEqual(failures, [L10n.string("Storage changed before cleanup; review it again.")])
        XCTAssertFalse(cli.calls.contains([
            "codex", "delete", "--force", expected.sessionName,
        ]))
    }

    func testCleanupRefusesAnyChangedPreviewFieldBeforeDeletingAnything() async throws {
        let cli = FakeCLI()
        let expected = makeSession(name: "detach-codex-one", bytes: 4_096)
        cli.responses["storage --json"] = ok(try encode(makeReport([expected])))
        let store = StorageStore(cli: cli)
        await store.refresh()

        var changed = expected
        changed.symlinkCount = 1
        cli.responses["storage --json"] = ok(try encode(makeReport([changed])))
        let failures = await store.cleanup(expected: [expected])

        XCTAssertEqual(failures, [L10n.string("Storage changed before cleanup; review it again.")])
        XCTAssertFalse(cli.calls.contains([
            "codex", "delete", "--force", expected.sessionName,
        ]))
    }

    func testCleanupContinuesAfterPartialDeletionFailure() async throws {
        let cli = FakeCLI()
        let first = makeSession(name: "detach-codex-first", bytes: 4_096)
        let second = makeSession(
            provider: .claude, name: "detach-claude-second", bytes: 8_192)
        let report = makeReport([first, second])
        cli.responses["storage --json"] = ok(try encode(report))
        cli.responses["codex delete --force detach-codex-first"] = .success(CLIResult(
            exitCode: 1, stdout: "", stderr: "checkpoint lock busy", timedOut: false))
        cli.responses["claude delete --force detach-claude-second"] = ok("")
        let store = StorageStore(cli: cli)
        await store.refresh()

        let failures = await store.cleanup(expected: [first, second])

        XCTAssertEqual(failures, ["detach-codex-first: checkpoint lock busy"])
        XCTAssertTrue(cli.calls.contains([
            "codex", "delete", "--force", "detach-codex-first",
        ]))
        XCTAssertTrue(cli.calls.contains([
            "claude", "delete", "--force", "detach-claude-second",
        ]))
    }

    func testInvalidStorageJSONDoesNotReplaceLastGoodReport() async throws {
        let cli = FakeCLI()
        let report = makeReport([makeSession(name: "detach-codex-one", bytes: 4_096)])
        cli.responses["storage --json"] = ok(try encode(report))
        let store = StorageStore(cli: cli)
        await store.refresh()
        cli.responses["storage --json"] = ok("not-json")

        await store.refresh()

        XCTAssertEqual(store.state, .incompatible)
        XCTAssertEqual(store.report, report)
    }

    private func ok(_ stdout: String) -> Result<CLIResult, Error> {
        .success(CLIResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false))
    }

    private func encode(_ report: StorageReport) throws -> String {
        String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    }

    private func makeReport(_ sessions: [StorageSession]) -> StorageReport {
        StorageReport(
            stateRoot: "/tmp/detach-state",
            complete: true,
            allocatedBytes: sessions.reduce(0) { $0 + $1.allocatedBytes },
            logicalBytes: sessions.reduce(0) { $0 + $1.logicalBytes },
            categories: StorageCategories(
                sessionDataBytes: sessions.reduce(0) { $0 + $1.allocatedBytes }),
            sessions: sessions,
            issues: [])
    }

    private func makeSession(
        provider: Provider = .codex,
        name: String,
        bytes: UInt64
    ) -> StorageSession {
        StorageSession(
            provider: provider,
            sessionName: name,
            effectiveStatus: .stopped,
            path: "/tmp/detach-state/\(provider.rawValue)/sessions/\(name)",
            allocatedBytes: bytes,
            logicalBytes: bytes,
            categories: StorageCategories(sessionDataBytes: bytes),
            scanComplete: true,
            symlinkCount: 0,
            hardLinkCount: 0,
            deletable: true,
            blockedReason: nil)
    }
}
