import Darwin
import XCTest
@testable import DetachKit

final class StorageInspectorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCategoriesAndCleanupPlanUseSaturatingAccounting() throws {
        let categories = StorageCategories(
            sessionDataBytes: .max,
            checkpointBytes: 1,
            logBytes: 2,
            otherStateBytes: 3)
        XCTAssertEqual(categories.totalBytes, .max)

        let first = session(name: "detach-codex-first", allocated: .max, logical: .max)
        let second = session(name: "detach-codex-second", allocated: 4_096, logical: 8_192)
        let report = StorageReport(
            stateRoot: temporaryDirectory.path,
            complete: true,
            allocatedBytes: .max,
            logicalBytes: .max,
            categories: categories,
            sessions: [second, first],
            issues: [])
        let data = try JSONEncoder().encode(report)

        let plan = try StorageInspector.cleanupPlan(
            reportData: data,
            selectAll: false,
            sessionNames: [first.sessionName, second.sessionName])

        XCTAssertEqual(plan.allocatedBytes, .max)
        XCTAssertEqual(plan.logicalBytes, .max)
        XCTAssertEqual(plan.sessions.map(\.sessionName), [first.sessionName, second.sessionName])
        XCTAssertThrowsError(try StorageInspector.cleanupPlan(
            reportData: data,
            selectAll: false,
            sessionNames: ["detach-codex-missing"]
        )) { error in
            XCTAssertEqual(
                error as? StorageInspectionError,
                .unsafeSelection("detach-codex-missing"))
        }
    }

    func testScannerBlocksUnownedUnsafeAndInvalidSessionEntries() throws {
        let roots = try makeProviderRoots()
        let sessionsRoot = roots[.codex]!.appendingPathComponent("sessions", isDirectory: true)
        let unsafeName = "detach-codex-unsafe"
        let invalidName = "detach-codex-invalid"
        let unownedName = "detach-codex-unowned"
        let external = temporaryDirectory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sessionsRoot.appendingPathComponent(unsafeName),
            withDestinationURL: external)
        try FileManager.default.createDirectory(
            at: sessionsRoot.appendingPathComponent(invalidName),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sessionsRoot.appendingPathComponent(unownedName),
            withIntermediateDirectories: true)

        let report = try StorageInspector.report(
            stateRoot: temporaryDirectory.path,
            providerRoots: roots.mapValues(\.path),
            excludedRoots: [],
            inventory: inventory([
                (.codex, unsafeName, .stopped),
                (.codex, invalidName, .orphaned),
            ]))

        XCTAssertFalse(report.complete)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: report.sessions.map {
                ($0.sessionName, $0.blockedReason)
            }),
            [unsafeName: "unsafe_directory", invalidName: "invalid_metadata"])
        XCTAssertTrue(report.issues.contains { $0.code == "unowned_session_entry" })
        XCTAssertTrue(report.issues.contains { $0.code == "session_directory_unsafe" })
        XCTAssertTrue(report.issues.contains { $0.code == "session_metadata_invalid" })
    }

    func testScannerClassifiesSpecialEntriesAndCheckpointMetadataFallback() throws {
        let roots = try makeProviderRoots()
        let name = "detach-codex-special"
        let sessionRoot = roots[.codex]!
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let checkpoint = sessionRoot.appendingPathComponent("checkpoint", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data(#"{"schema":1,"provider":"codex","session_name":"detach-codex-special"}"#.utf8)
            .write(to: checkpoint.appendingPathComponent("meta.json"))
        XCTAssertEqual(mkfifo(sessionRoot.appendingPathComponent("special.pipe").path, 0o600), 0)

        try Data("other state".utf8).write(
            to: temporaryDirectory.appendingPathComponent("other-state.txt"))
        XCTAssertEqual(mkfifo(
            temporaryDirectory.appendingPathComponent("state.pipe").path, 0o600), 0)

        let report = try StorageInspector.report(
            stateRoot: temporaryDirectory.path,
            providerRoots: roots.mapValues(\.path),
            excludedRoots: [],
            inventory: inventory([(.codex, name, .stopped)]))

        let measured = try XCTUnwrap(report.sessions.first)
        XCTAssertFalse(measured.scanComplete)
        XCTAssertFalse(measured.deletable)
        XCTAssertEqual(measured.blockedReason, "incomplete_scan")
        XCTAssertTrue(report.issues.contains { $0.code == "special_session_entry" })
        XCTAssertTrue(report.issues.contains { $0.code == "special_entry" })
        XCTAssertGreaterThan(report.categories.otherStateBytes, 0)
    }

    func testScannerRejectsARegularFileAsStateRoot() throws {
        let stateFile = temporaryDirectory.appendingPathComponent("state-file")
        try Data("not a directory".utf8).write(to: stateFile)

        let report = try StorageInspector.report(
            stateRoot: stateFile.path,
            providerRoots: [
                .codex: temporaryDirectory.appendingPathComponent("missing-codex").path,
                .claude: temporaryDirectory.appendingPathComponent("missing-claude").path,
            ],
            excludedRoots: [],
            inventory: Data())

        XCTAssertFalse(report.complete)
        XCTAssertTrue(report.issues.contains { $0.code == "state_root_unsafe" })
    }

    func testStateRootCannotAlsoBeAProviderSessionsRoot() throws {
        let sharedProviderRoot = temporaryDirectory.appendingPathComponent(
            "shared-provider", isDirectory: true)
        let sessionsRoot = sharedProviderRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionsRoot, withIntermediateDirectories: true)

        let report = try StorageInspector.report(
            stateRoot: sessionsRoot.path,
            providerRoots: [
                .codex: sharedProviderRoot.path,
                .claude: sharedProviderRoot.path,
            ],
            excludedRoots: [],
            inventory: Data())

        XCTAssertFalse(report.complete)
        XCTAssertTrue(report.issues.contains {
            $0.code == "state_root_overlaps_excluded_storage"
                && $0.path == sessionsRoot.path
        })
    }

    private func makeProviderRoots() throws -> [Provider: URL] {
        var roots: [Provider: URL] = [:]
        for provider in Provider.allCases {
            let root = temporaryDirectory.appendingPathComponent(provider.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sessions", isDirectory: true),
                withIntermediateDirectories: true)
            roots[provider] = root
        }
        return roots
    }

    private func inventory(
        _ sessions: [(Provider, String, EffectiveStatus)]
    ) throws -> Data {
        let lines = try sessions.map { provider, name, status in
            String(decoding: try JSONSerialization.data(withJSONObject: [
                "schema": 1,
                "provider": provider.rawValue,
                "session_name": name,
                "name": name,
                "effective_status": status.rawValue,
                "cleanup_eligible": true,
            ], options: [.sortedKeys]), as: UTF8.self)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func session(
        name: String,
        allocated: UInt64,
        logical: UInt64
    ) -> StorageSession {
        StorageSession(
            provider: .codex,
            sessionName: name,
            effectiveStatus: .stopped,
            path: "/tmp/\(name)",
            allocatedBytes: allocated,
            logicalBytes: logical,
            categories: StorageCategories(sessionDataBytes: allocated),
            scanComplete: true,
            symlinkCount: 0,
            hardLinkCount: 0,
            deletable: true,
            blockedReason: nil)
    }
}
