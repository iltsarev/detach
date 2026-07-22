import XCTest
@testable import DetachKit

final class PowerAssertionControllerTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    private final class FakeBackend: PowerAssertionBackend, @unchecked Sendable {
        var nextAssertionID: UInt32 = 41
        var createError: Error?
        var releaseError: Error?
        private(set) var createdReasons: [String] = []
        private(set) var releaseAttempts: [UInt32] = []
        private(set) var releasedAssertionIDs: [UInt32] = []

        func createNoIdleSleepAssertion(reason: String) throws -> UInt32 {
            if let createError { throw createError }
            createdReasons.append(reason)
            return nextAssertionID
        }

        func releaseAssertion(_ assertionID: UInt32) throws {
            releaseAttempts.append(assertionID)
            if let releaseError { throw releaseError }
            releasedAssertionIDs.append(assertionID)
        }
    }

    func testAcquireCreatesOneAssertionAndBecomesActive() throws {
        let backend = FakeBackend()
        let controller = PowerAssertionController(
            reason: "test managed session", backend: backend)

        XCTAssertTrue(try controller.acquire())

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(backend.createdReasons, ["test managed session"])
    }

    func testDefaultControllerStartsInactiveAndReleaseIsIdempotent() throws {
        let controller = PowerAssertionController()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(try controller.release())
        XCTAssertFalse(controller.isActive)
    }

    func testIOKitErrorPreservesOperationCodeAndDescription() {
        let create = IOKitPowerAssertionError(operation: .create, code: -1)
        let release = IOKitPowerAssertionError(operation: .release, code: -2)

        XCTAssertEqual(create.operation, .create)
        XCTAssertEqual(create.code, -1)
        XCTAssertEqual(
            create.localizedDescription,
            "IOKit power assertion create failed with code -1")
        XCTAssertEqual(
            release.localizedDescription,
            "IOKit power assertion release failed with code -2")
    }

    func testAcquireIsIdempotentWhileActive() throws {
        let backend = FakeBackend()
        let controller = PowerAssertionController(backend: backend)

        XCTAssertTrue(try controller.acquire())
        XCTAssertFalse(try controller.acquire())

        XCTAssertEqual(backend.createdReasons, [PowerAssertionController.defaultReason])
    }

    func testReleaseUsesCreatedIDAndIsIdempotentWhenInactive() throws {
        let backend = FakeBackend()
        backend.nextAssertionID = 77
        let controller = PowerAssertionController(backend: backend)

        XCTAssertFalse(try controller.release())
        XCTAssertTrue(try controller.acquire())
        XCTAssertTrue(try controller.release())
        XCTAssertFalse(try controller.release())

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(backend.releasedAssertionIDs, [77])
    }

    func testFailedAcquireRemainsInactiveAndCanRetry() throws {
        let backend = FakeBackend()
        backend.createError = ExpectedFailure()
        let controller = PowerAssertionController(backend: backend)

        XCTAssertThrowsError(try controller.acquire())
        XCTAssertFalse(controller.isActive)

        backend.createError = nil
        XCTAssertTrue(try controller.acquire())
        XCTAssertTrue(controller.isActive)
    }

    func testFailedReleaseStaysActiveAndCanRetry() throws {
        let backend = FakeBackend()
        let controller = PowerAssertionController(backend: backend)
        XCTAssertTrue(try controller.acquire())
        backend.releaseError = ExpectedFailure()

        XCTAssertThrowsError(try controller.release())
        XCTAssertTrue(controller.isActive)

        backend.releaseError = nil
        XCTAssertTrue(try controller.release())
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(backend.releaseAttempts, [41, 41])
        XCTAssertEqual(backend.releasedAssertionIDs, [41])
    }

    func testDeinitMakesBestEffortToReleaseActiveAssertion() throws {
        let backend = FakeBackend()
        backend.nextAssertionID = 99

        do {
            let controller = PowerAssertionController(backend: backend)
            XCTAssertTrue(try controller.acquire())
        }

        XCTAssertEqual(backend.releasedAssertionIDs, [99])
    }

    func testDeinitSwallowsReleaseFailureWithoutLosingTheAttempt() throws {
        let backend = FakeBackend()
        backend.releaseError = ExpectedFailure()

        do {
            let controller = PowerAssertionController(backend: backend)
            XCTAssertTrue(try controller.acquire())
        }

        XCTAssertEqual(backend.releaseAttempts, [41])
        XCTAssertTrue(backend.releasedAssertionIDs.isEmpty)
    }
}
