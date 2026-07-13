import XCTest
@testable import DetachKit

final class DistributionClientTests: XCTestCase {
    private let payload = URL(fileURLWithPath: "/tmp/payload")
    private let version = URL(fileURLWithPath: "/tmp/payload/VERSION")

    private func client(installer: FakeCLI, cli: FakeCLI) -> DistributionClient {
        DistributionClient(installer: installer, cli: cli,
                           payloadDirectory: payload, versionFile: version)
    }

    func testSynchronizeUsesBundledPayload() async throws {
        let installer = FakeCLI()
        let cli = FakeCLI()
        installer.responses[
            "install --source app --payload-dir /tmp/payload --version-file /tmp/payload/VERSION --no-launch-agent"
        ] = .success(CLIResult(exitCode: 0, stdout: "installed", stderr: "", timedOut: false))

        let output = try await client(installer: installer, cli: cli).synchronize()
        XCTAssertEqual(output, "installed")
        XCTAssertEqual(installer.calls.last, [
            "install", "--source", "app", "--payload-dir", "/tmp/payload",
            "--version-file", "/tmp/payload/VERSION", "--no-launch-agent",
        ])
    }

    func testRepairIsExplicit() async throws {
        let installer = FakeCLI()
        let cli = FakeCLI()
        _ = try await client(installer: installer, cli: cli).synchronize(repair: true)
        XCTAssertEqual(installer.calls.last?.suffix(2), ["--no-launch-agent", "--repair"])
    }

    func testDoctorParsesReportEvenWhenChecksFail() async throws {
        let installer = FakeCLI()
        let cli = FakeCLI()
        cli.responses["doctor --json"] = .success(CLIResult(
            exitCode: 1,
            stdout: #"{"schema":1,"version":"0.1.0","build":"7","payload_id":"abc","ok":false,"checks":[{"id":"tmux","section":"base","label":"tmux","required":true,"status":"error","path":null,"summary":"missing"}]}"#,
            stderr: "", timedOut: false))

        let report = try await client(installer: installer, cli: cli).doctor()
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.checks.first?.id, "tmux")
        XCTAssertTrue(report.matches(version: "0.1.0", build: "7", payloadID: "abc"))
        XCTAssertFalse(report.matches(version: "0.1.0", build: "6", payloadID: "abc"))
    }

    func testDoctorRejectsUnknownSchema() async {
        let installer = FakeCLI()
        let cli = FakeCLI()
        cli.responses["doctor --json"] = .success(CLIResult(
            exitCode: 0, stdout: #"{"schema":2,"version":"1.0.0","ok":true,"checks":[]}"#,
            stderr: "", timedOut: false))
        do {
            _ = try await client(installer: installer, cli: cli).doctor()
            XCTFail("expected schema error")
        } catch {
            XCTAssertEqual(error as? DistributionClientError, .incompatibleDoctorSchema(2))
        }
    }
}
