import XCTest
@testable import DetachApp

@MainActor
final class AppRuntimeActivationSequenceTests: XCTestCase {
    func testPayloadActivationPrecedesSessionSource() async {
        var steps: [String] = []

        await AppRuntimeActivationSequence.run(
            activatePayload: { steps.append("payload") },
            activateSessionSource: { steps.append("sessions") })

        XCTAssertEqual(steps, ["payload", "sessions"])
    }
}
