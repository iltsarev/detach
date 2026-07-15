import Foundation
import XCTest
@testable import DetachKit

final class PowerHeartbeatReaderTests: XCTestCase {
    private let referenceDate = ISO8601DateFormatter()
        .date(from: "2026-07-15T12:00:00Z")!

    func testFreshHealthyHeartbeatExposesPowerState() throws {
        let url = try write(document(checkedAt: "2026-07-15T11:59:30Z"))
        defer { remove(url) }

        let snapshot = PowerHeartbeatReader(statusURL: url)
            .read(now: referenceDate)

        XCTAssertTrue(snapshot.isFresh)
        XCTAssertTrue(snapshot.healthy)
        XCTAssertEqual(snapshot.effectivePowerState, .protected)
        XCTAssertEqual(snapshot.age(relativeTo: referenceDate), 30)
    }

    func testFreshnessComesFromCheckedAtNotFileModificationTime() throws {
        let url = try write(document(checkedAt: "2026-07-15T11:00:00Z"))
        defer { remove(url) }
        // A recent mtime must not resurrect an old document.
        try FileManager.default.setAttributes(
            [.modificationDate: referenceDate],
            ofItemAtPath: url.path)

        let snapshot = PowerHeartbeatReader(statusURL: url)
            .read(now: referenceDate)

        XCTAssertFalse(snapshot.isFresh)
        XCTAssertEqual(snapshot.effectivePowerState, .unknown)
    }

    func testFreshnessBoundaryIsMaximumAge() throws {
        let url = try write(document(checkedAt: "2026-07-15T11:57:01Z"))
        defer { remove(url) }
        let reader = PowerHeartbeatReader(statusURL: url)

        XCTAssertTrue(reader.read(now: referenceDate).isFresh)
        XCTAssertFalse(reader.read(
            now: referenceDate.addingTimeInterval(61)).isFresh)
    }

    func testFutureTimestampBeyondToleranceIsStale() throws {
        let slightlyAhead = try write(
            document(checkedAt: "2026-07-15T12:00:03Z"),
            name: "slightly-ahead.json")
        let farAhead = try write(
            document(checkedAt: "2026-07-15T12:05:00Z"),
            name: "far-ahead.json")
        defer {
            remove(slightlyAhead)
            remove(farAhead)
        }

        XCTAssertTrue(PowerHeartbeatReader(statusURL: slightlyAhead)
            .read(now: referenceDate).isFresh)
        XCTAssertFalse(PowerHeartbeatReader(statusURL: farAhead)
            .read(now: referenceDate).isFresh)
    }

    func testMissingCheckedAtIsStale() throws {
        let url = try write(#"{"state":"ok","power_state":"protected"}"#)
        defer { remove(url) }

        let snapshot = PowerHeartbeatReader(statusURL: url)
            .read(now: referenceDate)

        XCTAssertFalse(snapshot.isFresh)
        XCTAssertEqual(snapshot.effectivePowerState, .unknown)
    }

    func testMissingFileAndMalformedDocumentAreUnknown() throws {
        let missing = PowerHeartbeatReader(statusURL: URL(
            fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"))
            .read(now: referenceDate)
        XCTAssertNil(missing.state)
        XCTAssertFalse(missing.isFresh)
        XCTAssertEqual(missing.effectivePowerState, .unknown)

        let url = try write("not-json")
        defer { remove(url) }
        let malformed = PowerHeartbeatReader(statusURL: url)
            .read(now: referenceDate)
        XCTAssertNil(malformed.state)
        XCTAssertEqual(malformed.effectivePowerState, .unknown)
    }

    func testUnhealthyStateNeverExposesPowerState() throws {
        let url = try write(document(
            state: "status_failed", checkedAt: "2026-07-15T11:59:59Z"))
        defer { remove(url) }

        let snapshot = PowerHeartbeatReader(statusURL: url)
            .read(now: referenceDate)

        XCTAssertTrue(snapshot.isFresh)
        XCTAssertFalse(snapshot.healthy)
        XCTAssertEqual(snapshot.effectivePowerState, .unknown)
    }

    func testUnknownPowerStateRawValueDegradesToUnknown() throws {
        let url = try write(document(
            powerState: "future_state", checkedAt: "2026-07-15T11:59:59Z"))
        defer { remove(url) }

        let snapshot = PowerHeartbeatReader(statusURL: url)
            .read(now: referenceDate)

        XCTAssertTrue(snapshot.healthy)
        XCTAssertEqual(snapshot.effectivePowerState, .unknown)
    }

    func testDefaultStatusURLPrecedence() {
        let power = PowerHeartbeatReader.defaultStatusURL(
            environment: [
                "DETACH_POWER_STATE_ROOT": "/tmp/power-root",
                "DETACH_STATE_ROOT": "/tmp/state-root",
                "XDG_STATE_HOME": "/tmp/xdg",
                "HOME": "/tmp/home",
            ])
        XCTAssertEqual(power.path, "/tmp/power-root/watchdog-status.json")

        let state = PowerHeartbeatReader.defaultStatusURL(
            environment: [
                "DETACH_STATE_ROOT": "/tmp/state-root",
                "XDG_STATE_HOME": "/tmp/xdg",
                "HOME": "/tmp/home",
            ])
        XCTAssertEqual(
            state.path, "/tmp/state-root/power/watchdog-status.json")

        let xdg = PowerHeartbeatReader.defaultStatusURL(
            environment: ["XDG_STATE_HOME": "/tmp/xdg", "HOME": "/tmp/home"])
        XCTAssertEqual(
            xdg.path, "/tmp/xdg/detach/power/watchdog-status.json")

        let home = PowerHeartbeatReader.defaultStatusURL(
            environment: ["HOME": "/tmp/home"])
        XCTAssertEqual(
            home.path,
            "/tmp/home/.local/state/detach/power/watchdog-status.json")
    }

    private func document(
        state: String = "ok",
        powerState: String = "protected",
        checkedAt: String
    ) -> String {
        """
        {"schema":1,"state":"\(state)","power_state":"\(powerState)",\
        "checked_at":"\(checkedAt)","exit_status":0}
        """
    }

    private func write(
        _ body: String, name: String = "watchdog-status.json"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url, options: .atomic)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent())
    }
}
