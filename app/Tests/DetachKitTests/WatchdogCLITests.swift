import Foundation
import XCTest
@testable import DetachKit

final class WatchdogCLITests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-watchdog-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        home = nil
    }

    func testResolvesInstalledPayloadAndStripsInheritedOverrides() throws {
        let payload = try installPayload()
        let result = try XCTUnwrap(
            WatchdogCLI.resolve(
                home: home,
                environment: [
                    "HOME": home.path,
                    "PATH": "/usr/bin:/bin",
                    "DETACH_STATE_BIN": "/old/detach-state",
                    "DETACH_POWER_BIN": "/old/detach-power",
                    "DETACH_TMUX_BIN": "/old/tmux",
                    "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                    "DYLD_LIBRARY_PATH": "/evil/lib",
                    "UNRELATED_SETTING": "kept",
                ],
                powerStateRoot: "/private/tmp/watchdog-power").get())

        XCTAssertEqual(result.executableURL.standardizedFileURL, payload)
        XCTAssertNil(result.environment["DETACH_STATE_BIN"])
        XCTAssertNil(result.environment["DETACH_POWER_BIN"])
        XCTAssertNil(result.environment["DETACH_TMUX_BIN"])
        XCTAssertNil(result.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(result.environment["DYLD_LIBRARY_PATH"])
        XCTAssertEqual(result.environment["DETACH_POWER_STATE_ROOT"], "/private/tmp/watchdog-power")
        XCTAssertEqual(result.environment["UNRELATED_SETTING"], "kept")
        XCTAssertEqual(
            result.environment["PATH"],
            "\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testRejectsANonPayloadPublicCommand() throws {
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let unmanaged = bin.appendingPathComponent("detach")
        try writeExecutable(unmanaged)

        let result = WatchdogCLI.resolve(
            home: home,
            environment: [:],
            powerStateRoot: "/private/tmp/watchdog-power")

        guard case .failure(.notRegularPayload) = result else {
            XCTFail("expected a non-payload command to be rejected")
            return
        }
    }

    func testRejectsAPublicCommandThatResolvesOutsideThePayload() throws {
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let other = home.appendingPathComponent("other/detach")
        try FileManager.default.createDirectory(
            at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(other)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("detach"),
            withDestinationURL: other)

        let result = WatchdogCLI.resolve(
            home: home,
            environment: [:],
            powerStateRoot: "/private/tmp/watchdog-power")

        guard case .failure(.notRegularPayload) = result else {
            XCTFail("expected a non-payload symlink target to be rejected")
            return
        }
    }

    func testRejectsAPayloadWithoutSiblingCore() throws {
        let payload = try installPayload(includeCore: false)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: payload.path))

        let result = WatchdogCLI.resolve(
            home: home,
            environment: [:],
            powerStateRoot: "/private/tmp/watchdog-power")

        guard case .failure(.notRegularPayload) = result else {
            XCTFail("expected a missing sibling detach-core to be rejected")
            return
        }
    }

    func testReportsAMissingPublicCommand() {
        let result = WatchdogCLI.resolve(
            home: home,
            environment: [:],
            powerStateRoot: "/private/tmp/watchdog-power")

        guard case .failure(.missing) = result else {
            XCTFail("expected a missing public command")
            return
        }
    }

    func testChildEnvironmentKeepsPowerStateRootAfterStrippingBins() {
        let environment = WatchdogCLI.childEnvironment(
            from: [
                "DETACH_POWER_BIN": "/old/detach-power",
                "DETACH_SQLITE_BIN": "/old/sqlite3",
                "DYLD_FRAMEWORK_PATH": "/evil",
                "DETACH_POWER_STATE_ROOT": "/old/power",
            ],
            home: "/Users/test",
            powerStateRoot: "/watchdog/power")

        XCTAssertNil(environment["DETACH_POWER_BIN"])
        XCTAssertNil(environment["DETACH_SQLITE_BIN"])
        XCTAssertNil(environment["DYLD_FRAMEWORK_PATH"])
        XCTAssertEqual(environment["DETACH_POWER_STATE_ROOT"], "/watchdog/power")
    }

    private func installPayload(includeCore: Bool = true) throws -> URL {
        let version = home
            .appendingPathComponent(".local/libexec/detach/versions/1.0.0-testhash")
        try FileManager.default.createDirectory(
            at: version, withIntermediateDirectories: true)
        let payload = version.appendingPathComponent("detach")
        try writeExecutable(payload)
        if includeCore {
            try writeExecutable(version.appendingPathComponent("detach-core"))
        }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("detach"),
            withDestinationURL: payload)
        return payload.standardizedFileURL
    }

    private func writeExecutable(_ url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
