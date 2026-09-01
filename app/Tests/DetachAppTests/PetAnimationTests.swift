import CoreGraphics
import XCTest
@testable import DetachApp
@testable import DetachKit

final class PetAnimationTests: XCTestCase {
    func testIdleWithoutPointerUsesNeutralStillFrame() {
        for elapsed in [0.0, 0.5, 100.0] {
            XCTAssertEqual(PetAnimationFrameResolver.frame(
                activity: nil,
                elapsed: elapsed,
                reduceMotion: false,
                pointerVector: nil,
                supportsLookDirections: true), PetAtlasFrame(row: 0, column: 0))
        }
    }

    func testActivityStatesUseTheCodexStandardRows() {
        let cases: [(PetActivityState?, Int)] = [
            (nil, 0),
            (.blocked, 5),
            (.needsInput, 6),
            (.running, 7),
            (.ready, 8),
        ]
        for (activity, row) in cases {
            XCTAssertEqual(PetAnimationFrameResolver.frame(
                activity: activity,
                elapsed: 0,
                reduceMotion: false,
                pointerVector: nil,
                supportsLookDirections: true).row, row)
        }
    }

    func testReducedMotionKeepsTheFirstStateFrame() {
        XCTAssertEqual(PetAnimationFrameResolver.frame(
            activity: .running,
            elapsed: 10,
            reduceMotion: true,
            pointerVector: nil,
            supportsLookDirections: true), PetAtlasFrame(row: 7, column: 0))
    }

    func testRunningAnimationAdvancesWithDeclaredDurations() {
        XCTAssertEqual(PetAnimationFrameResolver.frame(
            activity: .running,
            elapsed: 0.119,
            reduceMotion: false,
            pointerVector: nil,
            supportsLookDirections: false).column, 0)
        XCTAssertEqual(PetAnimationFrameResolver.frame(
            activity: .running,
            elapsed: 0.121,
            reduceMotion: false,
            pointerVector: nil,
            supportsLookDirections: false).column, 1)
    }

    func testV2LookDirectionsUseClockwiseScreenCoordinates() {
        let cases: [(CGVector, PetAtlasFrame)] = [
            (CGVector(dx: 0, dy: 100), PetAtlasFrame(row: 9, column: 0)),
            (CGVector(dx: 100, dy: 0), PetAtlasFrame(row: 9, column: 4)),
            (CGVector(dx: 0, dy: -100), PetAtlasFrame(row: 10, column: 0)),
            (CGVector(dx: -100, dy: 0), PetAtlasFrame(row: 10, column: 4)),
        ]
        for (vector, expected) in cases {
            XCTAssertEqual(PetAnimationFrameResolver.frame(
                activity: nil,
                elapsed: 0,
                reduceMotion: false,
                pointerVector: vector,
                supportsLookDirections: true), expected)
        }
    }

    func testPointerDeadzoneAndV1FallBackToIdle() {
        for supportsLook in [false, true] {
            let vector = supportsLook ? CGVector(dx: 2, dy: 2) : CGVector(dx: 100, dy: 0)
            XCTAssertEqual(PetAnimationFrameResolver.frame(
                activity: nil,
                elapsed: 0,
                reduceMotion: false,
                pointerVector: vector,
                supportsLookDirections: supportsLook),
                PetAtlasFrame(row: 0, column: 0))
        }
    }
}
