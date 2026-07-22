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

    func testRejectedPermissionRequestPublishesDeniedAndDoesNotDeliver() async {
        let center = FakeNotificationCenter(
            status: .notDetermined,
            requestResult: .success(false),
            statusAfterRequest: .authorized)
        let service = SessionNotificationService(center: center)

        await service.configure(enabled: true)
        await service.observe([makeSession(status: .running)])
        await service.observe([makeSession(status: .failed)])

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(service.authorizationStatus, .denied)
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testDeniedPermissionIsNotRequestedAgain() async {
        let center = FakeNotificationCenter(status: .denied)
        let service = SessionNotificationService(center: center)

        await service.configure(enabled: true)

        XCTAssertEqual(center.requestCount, 0)
        XCTAssertEqual(service.authorizationStatus, .denied)
    }

    func testPermissionRequestFailureRefreshesStatusAndPublishesError() async {
        let error = NSError(
            domain: "SessionNotificationServiceTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "authorization unavailable"])
        let center = FakeNotificationCenter(
            status: .notDetermined,
            requestResult: .failure(error))
        let service = SessionNotificationService(center: center)

        await service.configure(enabled: true)

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(service.authorizationStatus, .notDetermined)
        XCTAssertEqual(
            service.errorMessage,
            "Could not request notification permission: authorization unavailable")
    }

    func testRefreshReflectsPermissionChangedInSystemSettings() async {
        let center = FakeNotificationCenter(status: .denied)
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: true)

        center.status = .authorized
        await service.refreshAuthorizationStatus()

        XCTAssertEqual(service.authorizationStatus, .authorized)
        XCTAssertEqual(center.requestCount, 0)
    }

    func testRefreshReflectsPermissionRevokedInSystemSettings() async {
        let center = FakeNotificationCenter(status: .authorized)
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: true)

        center.status = .denied
        await service.refreshAuthorizationStatus()

        XCTAssertEqual(service.authorizationStatus, .denied)
        XCTAssertEqual(center.requestCount, 0)
    }

    func testStalePermissionRefreshCannotOverwriteNewerStatus() async {
        let center = OutOfOrderStatusNotificationCenter()
        let service = SessionNotificationService(center: center)

        let staleRefresh = Task { await service.refreshAuthorizationStatus() }
        await center.waitUntilFirstStatusWasRequested()
        await service.refreshAuthorizationStatus()
        center.resumeFirstStatus(with: .denied)
        await staleRefresh.value

        XCTAssertEqual(service.authorizationStatus, .authorized)
    }

    func testConfigureInvalidatesOlderPermissionRefresh() async {
        let center = OutOfOrderStatusNotificationCenter()
        let service = SessionNotificationService(center: center)

        let staleRefresh = Task { await service.refreshAuthorizationStatus() }
        await center.waitUntilFirstStatusWasRequested()
        await service.configure(enabled: true)
        center.resumeFirstStatus(with: .denied)
        await staleRefresh.value

        XCTAssertEqual(service.authorizationStatus, .authorized)
    }

    func testReauthorizingNotificationsEstablishesANewSessionBaseline() async {
        let center = FakeNotificationCenter(status: .authorized)
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: true)
        await service.observe([makeSession(status: .running)])

        center.status = .denied
        await service.refreshAuthorizationStatus()
        center.status = .authorized
        await service.refreshAuthorizationStatus()
        await service.observe([makeSession(status: .completed)])

        XCTAssertTrue(center.delivered.isEmpty)
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

    func testStalePermissionRequestFailureCannotOverwriteDisabledConfiguration() async {
        let failure = NSError(
            domain: "SessionNotificationServiceTests", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "stale authorization failure"])
        let center = SuspendedAuthorizationNotificationCenter()
        let service = SessionNotificationService(center: center)

        let enable = Task { await service.configure(enabled: true) }
        await center.waitUntilRequestStarted()
        await service.configure(enabled: false)
        center.failRequest(with: failure)
        await enable.value

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(service.authorizationStatus, .notDetermined)
        XCTAssertNil(service.errorMessage)
    }

    func testDeniedObservationsAreDiscardedAndNeverReplayed() async {
        let center = FakeNotificationCenter(status: .denied)
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: true)

        await service.observe([makeSession(status: .running)])
        await service.observe([makeSession(status: .failed)])
        center.status = .authorized
        await service.refreshAuthorizationStatus()
        await service.observe([makeSession(status: .failed)])

        XCTAssertTrue(center.delivered.isEmpty)
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
        XCTAssertEqual(center.delivered[0].title, L10n.string("Session failed"))
        XCTAssertTrue(center.delivered[0].body.contains(L10n.format("Exit code: %d", 7)))
    }

    func testDeliversOneNotificationWhenAgentWaitsForUser() async {
        let center = FakeNotificationCenter(status: .authorized)
        let service = SessionNotificationService(
            center: center, identifierProvider: { "waiting-event" })
        await service.configure(enabled: true)

        await service.observe([
            makeSession(status: .running, turnState: .working, turnID: "turn-1")
        ])
        await service.observe([
            makeSession(status: .running, turnState: .waiting, turnID: "turn-1")
        ])
        await service.observe([
            makeSession(status: .running, turnState: .waiting, turnID: "turn-1")
        ])

        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.delivered[0].title, L10n.string("Agent response is ready"))
        XCTAssertTrue(center.delivered[0].body.contains(L10n.string("Open the session to continue")))
    }

    func testCompletedAndRecoverableTransitionsHaveSpecificMessages() async {
        let cases: [(EffectiveStatus, String, String)] = [
            (
                .completed,
                "Session completed",
                "Work completed successfully"
            ),
            (
                .recoverable,
                "Session can be recovered",
                "Recovery from the latest checkpoint is available"
            ),
        ]

        for (status, expectedTitle, expectedDetail) in cases {
            let center = FakeNotificationCenter(status: .authorized)
            let service = SessionNotificationService(
                center: center, identifierProvider: { status.rawValue })
            await service.configure(enabled: true)
            await service.observe([makeSession(status: .running)])

            await service.observe([makeSession(status: status)])

            XCTAssertEqual(center.delivered.count, 1)
            XCTAssertEqual(center.delivered.first?.title, expectedTitle)
            XCTAssertTrue(center.delivered.first?.body.contains(expectedDetail) == true)
        }
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
        XCTAssertTrue(center.delivered[0].body.contains(L10n.format("Exit code: %d", 9)))
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

    func testDisablingDuringFailedDeliveryDoesNotPublishStaleErrorOrRetry() async {
        let failure = NSError(
            domain: "SessionNotificationServiceTests", code: 41,
            userInfo: [NSLocalizedDescriptionKey: "late delivery failure"])
        let center = ResettableDeliveryNotificationCenter()
        let service = SessionNotificationService(
            center: center, identifierProvider: { "disabled-in-flight" })
        await service.configure(enabled: true)
        await service.observe([makeSession(status: .running)])

        let transition = Task {
            await service.observe([makeSession(status: .failed)])
        }
        await center.waitUntilFirstDeliveryStarted()
        await service.configure(enabled: false)
        center.resumeFirstDelivery(throwing: failure)
        await transition.value

        XCTAssertEqual(center.attemptedIdentifiers, [
            "detach.session.disabled-in-flight",
        ])
        XCTAssertNil(service.errorMessage)
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testPermissionResetDuringFailedDeliveryDropsOldPayloadAndContinues() async {
        let failure = NSError(
            domain: "SessionNotificationServiceTests", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "obsolete delivery failure"])
        let center = ResettableDeliveryNotificationCenter()
        let service = SessionNotificationService(
            center: center, identifierProvider: { "reset-in-flight" })
        await service.configure(enabled: true)
        await service.observe([makeSession(status: .running)])

        let staleTransition = Task {
            await service.observe([makeSession(status: .failed)])
        }
        await center.waitUntilFirstDeliveryStarted()
        center.status = .denied
        await service.refreshAuthorizationStatus()
        center.status = .authorized
        await service.refreshAuthorizationStatus()
        center.resumeFirstDelivery(throwing: failure)
        await staleTransition.value

        await service.observe([makeSession(status: .running)])
        await service.observe([makeSession(status: .completed)])

        XCTAssertEqual(center.attemptedIdentifiers, [
            "detach.session.reset-in-flight",
            "detach.session.reset-in-flight",
        ])
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.delivered.first?.title, "Session completed")
        XCTAssertNil(service.errorMessage)
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

    func testPollOnceIgnoresErrorsNonzeroExitAndTimeout() async {
        let center = FakeNotificationCenter(status: .authorized)
        let cli = NotificationCLI(responses: [
            .failure(NSError(domain: "cli", code: 1)),
            .success(CLIResult(
                exitCode: 1, stdout: sessionLine(status: .running),
                stderr: "failed", timedOut: false)),
            .success(CLIResult(
                exitCode: 0, stdout: sessionLine(status: .running),
                stderr: "", timedOut: true)),
            .success(CLIResult(
                exitCode: 0, stdout: sessionLine(status: .running),
                stderr: "", timedOut: false)),
            .success(CLIResult(
                exitCode: 0, stdout: sessionLine(status: .completed),
                stderr: "", timedOut: false)),
        ])
        let service = SessionNotificationService(center: center)
        await service.configure(enabled: true)

        for _ in 0..<5 { await service.pollOnce(using: cli) }

        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.delivered.first?.title, "Session completed")
    }

    private func makeSession(
        status: EffectiveStatus,
        exitStatus: Int? = nil,
        turnState: AgentTurnState? = nil,
        turnID: String? = nil
    ) -> Session {
        let exit = exitStatus.map(String.init) ?? "null"
        let turnStateJSON = turnState.map { "\"\($0.rawValue)\"" } ?? "null"
        let turnIDJSON = turnID.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"provider":"claude","session_name":"work","name":"work","effective_status":"\(status.rawValue)","meta_status":null,"agent_session_id":"uuid","project_dir":"/tmp/harness","created_at":"2026-07-13T10:00:00Z","last_checkpoint_at":null,"exit_status":\(exit),"finished_at":null,"agent_turn_state":\(turnStateJSON),"agent_turn_id":\(turnIDJSON)}
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

    func failRequest(with error: Error) {
        requestContinuation?.resume(throwing: error)
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
private final class ResettableDeliveryNotificationCenter:
    SessionNotificationCenterBackend
{
    var status: SessionNotificationAuthorizationStatus = .authorized
    private var firstDeliveryContinuation: CheckedContinuation<Void, Error>?
    private var firstDeliveryStartedContinuation:
        CheckedContinuation<Void, Never>?
    private var firstDeliveryStarted = false
    private(set) var attemptedIdentifiers: [String] = []
    private(set) var delivered: [SessionNotificationPayload] = []

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool { true }

    func deliver(_ payload: SessionNotificationPayload) async throws {
        attemptedIdentifiers.append(payload.identifier)
        if attemptedIdentifiers.count == 1 {
            firstDeliveryStarted = true
            firstDeliveryStartedContinuation?.resume()
            firstDeliveryStartedContinuation = nil
            try await withCheckedThrowingContinuation {
                firstDeliveryContinuation = $0
            }
        }
        delivered.append(payload)
    }

    func waitUntilFirstDeliveryStarted() async {
        guard !firstDeliveryStarted else { return }
        await withCheckedContinuation {
            firstDeliveryStartedContinuation = $0
        }
    }

    func resumeFirstDelivery(throwing error: Error) {
        firstDeliveryContinuation?.resume(throwing: error)
        firstDeliveryContinuation = nil
    }
}

@MainActor
private final class OutOfOrderStatusNotificationCenter: SessionNotificationCenterBackend {
    private var firstStatusContinuation:
        CheckedContinuation<SessionNotificationAuthorizationStatus, Never>?
    private var firstStatusRequestedContinuation: CheckedContinuation<Void, Never>?
    private var statusRequestCount = 0

    func authorizationStatus() async -> SessionNotificationAuthorizationStatus {
        statusRequestCount += 1
        if statusRequestCount == 1 {
            firstStatusRequestedContinuation?.resume()
            firstStatusRequestedContinuation = nil
            return await withCheckedContinuation { firstStatusContinuation = $0 }
        }
        return .authorized
    }

    func waitUntilFirstStatusWasRequested() async {
        guard statusRequestCount == 0 else { return }
        await withCheckedContinuation { firstStatusRequestedContinuation = $0 }
    }

    func resumeFirstStatus(with status: SessionNotificationAuthorizationStatus) {
        firstStatusContinuation?.resume(returning: status)
        firstStatusContinuation = nil
    }

    func requestAuthorization() async throws -> Bool { true }
    func deliver(_ payload: SessionNotificationPayload) async throws {}
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
