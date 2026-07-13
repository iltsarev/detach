import DetachKit
import XCTest
@testable import DetachApp

@MainActor
final class SessionNotificationServiceTests: XCTestCase {
    func testEnablingRequestsUndeterminedPermissionOnce() async {
        let center = FakeNotificationCenter(
            status: .notDetermined, requestResult: .success(true), statusAfterRequest: .authorized)
        let service = SessionNotificationService(center: center)

        await service.configure(enabled: true)
        await service.configure(enabled: true)

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(service.authorizationStatus, .authorized)
    }

    func testDeniedPermissionIsNotRequestedAgain() async {
        let center = FakeNotificationCenter(status: .denied)
        let service = SessionNotificationService(center: center)

        await service.configure(enabled: true)

        XCTAssertEqual(center.requestCount, 0)
        XCTAssertEqual(service.authorizationStatus, .denied)
    }

    func testDisabledPreferenceDoesNotRequestPermission() async {
        let center = FakeNotificationCenter(status: .notDetermined)
        let service = SessionNotificationService(center: center)

        await service.configure(enabled: false)

        XCTAssertEqual(center.requestCount, 0)
    }

    func testStaleEnableDoesNotRequestAfterFeatureWasDisabled() async {
        let center = SuspendedStatusNotificationCenter()
        let service = SessionNotificationService(center: center)

        let enable = Task { await service.configure(enabled: true) }
        await center.waitUntilStatusWasRequested()
        await service.configure(enabled: false)
        center.resumeFirstStatus(with: .notDetermined)
        await enable.value

        XCTAssertEqual(center.requestCount, 0)
    }

    func testDeliversOneNotificationPerTransitionAndDeduplicatesPolls() async {
        let center = FakeNotificationCenter(status: .authorized)
        let service = SessionNotificationService(
            center: center, identifierProvider: { "event-id" })
        await service.configure(enabled: true)

        await service.observe([makeSession(status: .running)])
        await service.observe([makeSession(status: .failed, exitStatus: 7)])
        await service.observe([makeSession(status: .failed, exitStatus: 7)])

        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.delivered[0].identifier, "detach.session.event-id")
        XCTAssertEqual(center.delivered[0].title, "Сессия завершилась с ошибкой")
        XCTAssertTrue(center.delivered[0].body.contains("Код выхода: 7"))
    }

    func testInitialTerminalStateAndDisabledTransitionsAreNotReplayed() async {
        let center = FakeNotificationCenter(status: .authorized)
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: false)

        await service.observe([makeSession(status: .completed)])
        await service.observe([makeSession(status: .running)])
        await service.configure(enabled: true)
        await service.observe([makeSession(status: .running)])

        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testTransitionDuringPermissionPromptIsDeliveredAfterGrant() async {
        let center = SuspendedAuthorizationNotificationCenter()
        let service = SessionNotificationService(center: center)

        let configure = Task { await service.configure(enabled: true) }
        await center.waitUntilRequestStarted()
        await service.observe([makeSession(status: .running)])
        await service.observe([makeSession(status: .failed, exitStatus: 9)])
        center.resumeRequest(granted: true)
        await configure.value

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertTrue(center.delivered[0].body.contains("Код выхода: 9"))
    }

    func testConcurrentConfigureSharesOnePermissionRequest() async {
        let center = SuspendedAuthorizationNotificationCenter()
        let service = SessionNotificationService(center: center)

        let first = Task { await service.configure(enabled: true) }
        await center.waitUntilRequestStarted()
        let second = Task { await service.configure(enabled: true) }
        await Task.yield()
        center.resumeRequest(granted: true)
        await first.value
        await second.value

        XCTAssertEqual(center.requestCount, 1)
    }

    func testDeliveryFailureIsRetriedWithSamePayloadIdentifier() async {
        let center = RetryNotificationCenter()
        let service = SessionNotificationService(
            center: center, identifierProvider: { "stable-event" })
        await service.configure(enabled: true)

        await service.observe([makeSession(status: .running)])
        await service.observe([makeSession(status: .failed)])
        await service.observe([makeSession(status: .failed)])

        XCTAssertEqual(center.attemptedIdentifiers, [
            "detach.session.stable-event",
            "detach.session.stable-event",
        ])
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertNil(service.errorMessage)
    }

    func testConcurrentDeliveryTriggersShareOneInFlightRequest() async {
        let center = SuspendedDeliveryNotificationCenter()
        let service = SessionNotificationService(
            center: center, identifierProvider: { "single-flight" })
        await service.configure(enabled: true)
        await service.observe([makeSession(status: .running)])

        let transition = Task {
            await service.observe([makeSession(status: .failed)])
        }
        await center.waitUntilDeliveryStarted()

        // Authorization refresh is a second actor-reentrant path into queue
        // delivery while the first backend request is still suspended.
        await service.refreshAuthorizationStatus()
        XCTAssertEqual(center.attemptedIdentifiers.count, 1)

        center.resumeDelivery()
        await transition.value

        XCTAssertEqual(center.attemptedIdentifiers, ["detach.session.single-flight"])
        XCTAssertEqual(center.delivered.count, 1)
    }

    func testPollOnceUsesOnlyValidSuccessfulSnapshots() async {
        let center = FakeNotificationCenter(status: .authorized)
        let cli = NotificationCLI(responses: [
            .success(CLIResult(exitCode: 0, stdout: sessionLine(status: .running), stderr: "", timedOut: false)),
            .success(CLIResult(exitCode: 0, stdout: "invalid", stderr: "", timedOut: false)),
            .success(CLIResult(exitCode: 0, stdout: sessionLine(status: .failed), stderr: "", timedOut: false)),
        ])
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: true)

        await service.pollOnce(using: cli)
        await service.pollOnce(using: cli)
        await service.pollOnce(using: cli)

        XCTAssertEqual(center.delivered.count, 1)
    }

    private func makeSession(status: EffectiveStatus, exitStatus: Int? = nil) -> Session {
        let exit = exitStatus.map(String.init) ?? "null"
        let json = """
        {"schema":1,"provider":"claude","session_name":"work","name":"work","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":"uuid","project_dir":"/tmp/harness","created_at":"2026-07-13T10:00:00Z","last_checkpoint_at":null,"exit_status":\(exit),"finished_at":null}
        """
        return SessionListParser.parse(json).sessions[0]
    }

    private func sessionLine(status: EffectiveStatus) -> String {
        let session = makeSession(status: status)
        return """
        {"schema":1,"provider":"\(session.provider.rawValue)","session_name":"\(session.sessionName)","name":"\(session.name)","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":"uuid","project_dir":"/tmp/harness","created_at":"2026-07-13T10:00:00Z","last_checkpoint_at":null,"exit_status":null,"finished_at":null}
        """
    }
}

@MainActor
private final class SuspendedAuthorizationNotificationCenter: SessionNotificationCenterBackend {
    private var requestContinuation: CheckedContinuation<Bool, Error>?
    private var requestStartedContinuation: CheckedContinuation<Void, Never>?
    private var requestStarted = false
    private(set) var requestCount = 0
    private(set) var delivered: [SessionNotificationPayload] = []
    private var status: SessionNotificationAuthorizationStatus = .notDetermined

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        requestStarted = true
        requestStartedContinuation?.resume()
        requestStartedContinuation = nil
        return try await withCheckedThrowingContinuation { requestContinuation = $0 }
    }

    func waitUntilRequestStarted() async {
        guard !requestStarted else { return }
        await withCheckedContinuation { requestStartedContinuation = $0 }
    }

    func resumeRequest(granted: Bool) {
        status = granted ? .authorized : .denied
        requestContinuation?.resume(returning: granted)
        requestContinuation = nil
    }

    func deliver(_ payload: SessionNotificationPayload) async throws {
        delivered.append(payload)
    }
}

@MainActor
private final class RetryNotificationCenter: SessionNotificationCenterBackend {
    struct DeliveryError: Error {}

    private(set) var attemptedIdentifiers: [String] = []
    private(set) var delivered: [SessionNotificationPayload] = []

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }

    func deliver(_ payload: SessionNotificationPayload) async throws {
        attemptedIdentifiers.append(payload.identifier)
        if attemptedIdentifiers.count == 1 { throw DeliveryError() }
        delivered.append(payload)
    }
}

private final class NotificationCLI: DetachCLIRunning, @unchecked Sendable {
    private var responses: [Result<CLIResult, Error>]

    init(responses: [Result<CLIResult, Error>]) {
        self.responses = responses
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> CLIResult {
        try responses.removeFirst().get()
    }
}

@MainActor
private final class SuspendedDeliveryNotificationCenter: SessionNotificationCenterBackend {
    private var deliveryContinuation: CheckedContinuation<Void, Error>?
    private var deliveryStartedContinuation: CheckedContinuation<Void, Never>?
    private var deliveryStarted = false
    private(set) var attemptedIdentifiers: [String] = []
    private(set) var delivered: [SessionNotificationPayload] = []

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus { .authorized }
    func requestAuthorization() async throws -> Bool { true }

    func deliver(_ payload: SessionNotificationPayload) async throws {
        attemptedIdentifiers.append(payload.identifier)
        deliveryStarted = true
        deliveryStartedContinuation?.resume()
        deliveryStartedContinuation = nil
        try await withCheckedThrowingContinuation { deliveryContinuation = $0 }
        delivered.append(payload)
    }

    func waitUntilDeliveryStarted() async {
        guard !deliveryStarted else { return }
        await withCheckedContinuation { deliveryStartedContinuation = $0 }
    }

    func resumeDelivery() {
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }
}

@MainActor
private final class SuspendedStatusNotificationCenter: SessionNotificationCenterBackend {
    private var firstStatusContinuation:
        CheckedContinuation<SessionNotificationAuthorizationStatus, Never>?
    private var statusRequestContinuation: CheckedContinuation<Void, Never>?
    private var requestStarted = false
    private(set) var requestCount = 0

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        if !requestStarted {
            requestStarted = true
            statusRequestContinuation?.resume()
            statusRequestContinuation = nil
            return await withCheckedContinuation { firstStatusContinuation = $0 }
        }
        return .denied
    }

    func waitUntilStatusWasRequested() async {
        guard !requestStarted else { return }
        await withCheckedContinuation { statusRequestContinuation = $0 }
    }

    func resumeFirstStatus(with status: SessionNotificationAuthorizationStatus) {
        firstStatusContinuation?.resume(returning: status)
        firstStatusContinuation = nil
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        return true
    }

    func deliver(_ payload: SessionNotificationPayload) async throws {}
}

@MainActor
private final class FakeNotificationCenter: SessionNotificationCenterBackend {
    var status: SessionNotificationAuthorizationStatus
    let requestResult: Result<Bool, Error>
    let statusAfterRequest: SessionNotificationAuthorizationStatus
    private(set) var requestCount = 0
    private(set) var delivered: [SessionNotificationPayload] = []

    init(
        status: SessionNotificationAuthorizationStatus,
        requestResult: Result<Bool, Error> = .success(false),
        statusAfterRequest: SessionNotificationAuthorizationStatus? = nil
    ) {
        self.status = status
        self.requestResult = requestResult
        self.statusAfterRequest = statusAfterRequest ?? status
    }

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        let granted = try requestResult.get()
        status = statusAfterRequest
        return granted
    }

    func deliver(_ payload: SessionNotificationPayload) async throws {
        delivered.append(payload)
    }
}
