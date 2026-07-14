import Foundation
import XCTest
@testable import DetachApp

@MainActor
final class WatchdogServiceTests: XCTestCase {
    func testInitialRegistrationIsAutomatic() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(backend.unregisterCalls, 0)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "watchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    func testChangedDefinitionRetriesTransientRegisterFailure() async throws {
        let transient = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let backend = FakeWatchdogBackend(
            status: .enabled,
            registrations: [.failure(transient), .success(.enabled)])
        var delays: [UInt64] = []
        let fixture = makeFixture(
            backend: backend,
            sleep: { delays.append($0) })
        defer { fixture.cleanup() }
        fixture.defaults.set("digest-previous", forKey: "watchdogDefinitionDigest")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(backend.registerCalls, 2)
        XCTAssertEqual(delays, [250_000_000])
        XCTAssertEqual(
            fixture.defaults.string(forKey: "watchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    func testPendingUnavailableStateRecoversInsteadOfDeadEnding() async throws {
        let backend = FakeWatchdogBackend(
            status: .unavailable,
            registrations: [.success(.enabled)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }
        fixture.defaults.set(true, forKey: "watchdogDefinitionReconcilePending")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .enabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    func testApprovalStateCompletesRegistrationWithoutRetryLoop() async throws {
        let denied = NSError(
            domain: "SMAppServiceErrorDomain", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Approval required"])
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.approvalRequired(denied)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(backend.registerCalls, 1)
        XCTAssertEqual(fixture.service.status, .requiresApproval)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "watchdogDefinitionDigest"),
            "digest-current")
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    func testEnabledSignedServiceRetiresPortableWatchdog() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }
        let definition = try fixture.installPortableWatchdog()

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertFalse(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertEqual(
            launchctlCalls,
            [["bootout", "gui/\(getuid())/dev.tsarev.detach.cli-watchdog"]])
    }

    func testEnabledSignedServiceRetiresLegacyBundledAndUserWatchdog() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            legacyBackend: legacy,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }
        let definition = try fixture.installPortableWatchdog(
            plistName: "dev.tsarev.codex-detached-watchdog.plist",
            label: "dev.tsarev.codex-detached-watchdog",
            directCommand: true)

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertEqual(
            launchctlCalls,
            [["bootout", "gui/\(getuid())/dev.tsarev.codex-detached-watchdog"]])

        try await fixture.service.reconcileAfterAppUpdate()
        XCTAssertEqual(launchctlCalls.count, 1)
    }

    func testApprovalKeepsPortableWatchdogUntilSignedServiceIsEnabled() async throws {
        let denied = NSError(
            domain: "SMAppServiceErrorDomain", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Approval required"])
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.approvalRequired(denied)])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }
        let definition = try fixture.installPortableWatchdog()

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertTrue(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertTrue(launchctlCalls.isEmpty)

        backend.status = .enabled
        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertFalse(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertEqual(launchctlCalls.count, 1)
    }

    func testApprovalKeepsLegacyWatchdogsRunning() async throws {
        let denied = NSError(domain: "SMAppServiceErrorDomain", code: 2)
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.approvalRequired(denied)])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            legacyBackend: legacy,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }
        let definition = try fixture.installPortableWatchdog(
            plistName: "dev.tsarev.codex-detached-watchdog.plist",
            label: "dev.tsarev.codex-detached-watchdog")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertEqual(legacy.unregisterCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertTrue(launchctlCalls.isEmpty)
    }

    func testUnownedPortableDefinitionIsNotRemoved() async throws {
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.success(.enabled)])
        var launchctlCalls: [[String]] = []
        let fixture = makeFixture(
            backend: backend,
            launchctl: { launchctlCalls.append($0); return 0 })
        defer { fixture.cleanup() }
        let definition = try fixture.installPortableWatchdog(
            label: "example.unmanaged.watchdog")

        try await fixture.service.reconcileAfterAppUpdate()

        XCTAssertTrue(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertTrue(launchctlCalls.isEmpty)
    }

    func testNonTransientFailureKeepsRecoveryPending() async {
        let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let backend = FakeWatchdogBackend(
            status: .notRegistered,
            registrations: [.failure(failure)])
        let fixture = makeFixture(backend: backend)
        defer { fixture.cleanup() }

        do {
            try await fixture.service.reconcileAfterAppUpdate()
            XCTFail("Expected registration to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }

        XCTAssertTrue(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
        XCTAssertNil(fixture.defaults.string(forKey: "watchdogDefinitionDigest"))
    }

    func testDisableUnregistersServiceAndClearsDefinitionState() async throws {
        let backend = FakeWatchdogBackend(status: .enabled, registrations: [])
        let legacy = FakeWatchdogBackend(status: .enabled, registrations: [])
        let fixture = makeFixture(backend: backend, legacyBackend: legacy)
        defer { fixture.cleanup() }
        let portableDefinition = try fixture.installPortableWatchdog()
        fixture.defaults.set("digest-current", forKey: "watchdogDefinitionDigest")
        fixture.defaults.set(true, forKey: "watchdogDefinitionReconcilePending")

        try await fixture.service.disable()

        XCTAssertEqual(backend.unregisterCalls, 1)
        XCTAssertEqual(legacy.unregisterCalls, 1)
        XCTAssertEqual(fixture.service.status, .notRegistered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: portableDefinition.path))
        XCTAssertNil(fixture.defaults.string(forKey: "watchdogDefinitionDigest"))
        XCTAssertFalse(fixture.defaults.bool(forKey: "watchdogDefinitionReconcilePending"))
    }

    private func makeFixture(
        backend: FakeWatchdogBackend,
        legacyBackend: FakeWatchdogBackend? = nil,
        sleep: @escaping (UInt64) async throws -> Void = { _ in },
        launchctl: @escaping ([String]) -> Int32 = { _ in 0 }
    ) -> Fixture {
        let suite = "WatchdogServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-tests-\(UUID().uuidString)", isDirectory: true)
        let service = WatchdogService(
            backend: backend,
            legacyBackend: legacyBackend,
            defaults: defaults,
            homeDirectory: home,
            digestProvider: { "digest-current" },
            sleep: sleep,
            launchctl: launchctl)
        return Fixture(service: service, defaults: defaults, suite: suite, home: home)
    }
}

@MainActor
private final class FakeWatchdogBackend: WatchdogRegistrationBackend {
    enum Registration {
        case success(WatchdogStatus)
        case approvalRequired(Error)
        case failure(Error)
    }

    var status: WatchdogStatus
    var registrations: [Registration]
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: WatchdogStatus, registrations: [Registration]) {
        self.status = status
        self.registrations = registrations
    }

    func register() throws {
        registerCalls += 1
        guard !registrations.isEmpty else {
            throw WatchdogServiceError.registrationDidNotComplete
        }
        switch registrations.removeFirst() {
        case .success(let newStatus):
            status = newStatus
        case .approvalRequired(let error):
            status = .requiresApproval
            throw error
        case .failure(let error):
            throw error
        }
    }

    func unregister() async throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}

@MainActor
private struct Fixture {
    let service: WatchdogService
    let defaults: UserDefaults
    let suite: String
    let home: URL

    func installPortableWatchdog(
        plistName: String = "dev.tsarev.detach.cli-watchdog.plist",
        label: String = "dev.tsarev.detach.cli-watchdog",
        directCommand: Bool = false
    ) throws -> URL {
        let launchAgents = home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launchAgents, withIntermediateDirectories: true)
        let definition = launchAgents
            .appendingPathComponent(plistName)
        let arguments = directCommand
            ? ["\(home.path)/.local/bin/detach", "__reconcile_amphetamine"]
            : [
                "/bin/sh", "-c",
                "exec \(home.path)/.local/bin/detach __reconcile_amphetamine"
            ]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: definition)
        return definition
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }
}
