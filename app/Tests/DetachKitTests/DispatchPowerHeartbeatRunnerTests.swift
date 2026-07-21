import XCTest
@testable import DetachKit

final class DispatchPowerHeartbeatRunnerTests: XCTestCase {
    private struct ExpectedFailure: Error {}
    private struct TimedOut: Error {}

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    func testTransientRenewalFailureKeepsRetryingAndRecovers() throws {
        let probe = Probe()
        let recovered = DispatchSemaphore(value: 0)
        let runner = DispatchPowerHeartbeatRunner(interval: 0.01)

        let result = try runner.run(
            heartbeat: {
                if probe.next() == 1 { throw ExpectedFailure() }
                recovered.signal()
            },
            operation: {
                guard recovered.wait(timeout: .now() + 2) == .success else {
                    throw TimedOut()
                }
                return ChildCommandResult(exitCode: 17)
            })

        XCTAssertEqual(result.exitCode, 17)
        XCTAssertGreaterThanOrEqual(probe.value, 2)
    }

    func testPersistentRenewalFailureIsSurfacedAfterChildCleanup() {
        let probe = Probe()
        let secondFailure = DispatchSemaphore(value: 0)
        let runner = DispatchPowerHeartbeatRunner(interval: 0.01)

        XCTAssertThrowsError(try runner.run(
            heartbeat: {
                if probe.next() >= 2 { secondFailure.signal() }
                throw ExpectedFailure()
            },
            operation: {
                _ = secondFailure.wait(timeout: .now() + 2)
                return ChildCommandResult(exitCode: 0)
            })) { error in
                XCTAssertTrue(error is ExpectedFailure)
            }
        XCTAssertGreaterThanOrEqual(probe.value, 2)
    }
}
