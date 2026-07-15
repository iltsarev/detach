import XCTest
@testable import DetachKit

final class DispatchPowerHeartbeatRunnerTests: XCTestCase {
    private struct ExpectedFailure: Error {}

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
        let runner = DispatchPowerHeartbeatRunner(interval: 0.01)

        let result = try runner.run(
            heartbeat: {
                if probe.next() == 1 { throw ExpectedFailure() }
            },
            operation: {
                Thread.sleep(forTimeInterval: 0.055)
                return ChildCommandResult(exitCode: 17)
            })

        XCTAssertEqual(result.exitCode, 17)
        XCTAssertGreaterThanOrEqual(probe.value, 2)
    }

    func testPersistentRenewalFailureIsSurfacedAfterChildCleanup() {
        let probe = Probe()
        let runner = DispatchPowerHeartbeatRunner(interval: 0.01)

        XCTAssertThrowsError(try runner.run(
            heartbeat: {
                _ = probe.next()
                throw ExpectedFailure()
            },
            operation: {
                Thread.sleep(forTimeInterval: 0.04)
                return ChildCommandResult(exitCode: 0)
            }))
        XCTAssertGreaterThanOrEqual(probe.value, 2)
    }
}
