import Foundation
import XCTest
@testable import DetachKit

final class ClamshellLockRunnerTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    private final class FakeWatcher:
        ClamshellStateWatching, @unchecked Sendable
    {
        let states: [Bool]
        private(set) var operationCalls = 0

        init(states: [Bool]) {
            self.states = states
        }

        func run(
            onStateChange: @escaping @Sendable (Bool) -> Void,
            operation: @escaping @Sendable () throws -> ChildCommandResult
        ) throws -> ChildCommandResult {
            for state in states {
                onStateChange(state)
            }
            operationCalls += 1
            return try operation()
        }
    }

    private final class FakeRequester:
        ScreenLockRequesting, @unchecked Sendable
    {
        var error: Error?
        private(set) var calls = 0

        func requestLock() throws {
            calls += 1
            if let error { throw error }
        }
    }

    private final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    func testInitialOpenThenCloseRequestsNormalScreenLock() throws {
        let watcher = FakeWatcher(states: [false, true])
        let requester = FakeRequester()
        let runner = ClamshellLockRunner(
            watcher: watcher,
            requester: requester,
            reportFailure: { _ in XCTFail("unexpected lock failure") })

        let result = try runner.run {
            ChildCommandResult(exitCode: 19)
        }

        XCTAssertEqual(result.exitCode, 19)
        XCTAssertEqual(watcher.operationCalls, 1)
        XCTAssertEqual(requester.calls, 1)
    }

    func testAlreadyClosedInitialStateDoesNotDisruptClamshellUse() throws {
        let watcher = FakeWatcher(states: [true, true])
        let requester = FakeRequester()
        let runner = ClamshellLockRunner(
            watcher: watcher,
            requester: requester)

        _ = try runner.run {
            ChildCommandResult(exitCode: 0)
        }

        XCTAssertEqual(requester.calls, 0)
    }

    func testRepeatedClosedNotificationsLockOnlyOncePerTransition() throws {
        let watcher = FakeWatcher(
            states: [false, true, true, false, false, true])
        let requester = FakeRequester()
        let runner = ClamshellLockRunner(
            watcher: watcher,
            requester: requester)

        _ = try runner.run {
            ChildCommandResult(exitCode: 0)
        }

        XCTAssertEqual(requester.calls, 2)
    }

    func testLockFailureIsReportedWithoutStoppingProtectedChild() throws {
        let watcher = FakeWatcher(states: [false, true])
        let requester = FakeRequester()
        requester.error = ExpectedFailure()
        let messages = Messages()
        let runner = ClamshellLockRunner(
            watcher: watcher,
            requester: requester,
            reportFailure: { messages.append($0) })

        let result = try runner.run {
            ChildCommandResult(exitCode: 27)
        }

        XCTAssertEqual(result.exitCode, 27)
        XCTAssertEqual(requester.calls, 1)
        XCTAssertEqual(messages.values.count, 1)
        XCTAssertTrue(messages.values[0].contains(
            "could not lock the screen after the lid closed"))
    }
}
