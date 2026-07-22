import XCTest
@testable import DetachKit

final class DistributionClientTests: XCTestCase {
    private let payload = URL(fileURLWithPath: "/tmp/payload")
    private let version = URL(fileURLWithPath: "/tmp/payload/VERSION")

    private func client(installer: FakeCLI, cli: FakeCLI) -> DistributionClient {
        DistributionClient(installer: installer, cli: cli,
                           payloadDirectory: payload, versionFile: version)
    }

    func testDoctorValueTypesPreserveTypedContractAndCodingKeys() throws {
        let check = DiagnosticCheck(
            id: "power", section: .keepAwake, label: "Power", required: false,
            status: .warning, path: "/tmp/helper", summary: "degraded")
        let report = DoctorReport(
            schema: 1, version: "1.2.3", build: "45", payloadID: "payload",
            ok: false, checks: [check])

        XCTAssertTrue(report.matches(version: "1.2.3", build: "45", payloadID: "payload"))
        XCTAssertFalse(report.matches(version: "1.2.3", build: "46", payloadID: "payload"))
        XCTAssertEqual(report.checks, [check])

        let encoded = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["payload_id"] as? String, "payload")
        XCTAssertNil(object["payloadID"])
        XCTAssertEqual(try JSONDecoder().decode(DoctorReport.self, from: encoded), report)
    }

    func testDistributionErrorsExposeActionableDescriptions() {
        XCTAssertEqual(
            DistributionClientError.installerFailed("installer failed").errorDescription,
            "installer failed")
        XCTAssertEqual(
            DistributionClientError.doctorOutputMissing("doctor missing").errorDescription,
            "doctor missing")
        XCTAssertEqual(
            DistributionClientError.incompatibleDoctorSchema(7).errorDescription,
            L10n.format("Unsupported detach doctor schema: %d", 7))
    }

    func testSynchronizeUsesBundledPayload() async throws {
        let installer = FakeCLI()
        let cli = FakeCLI()
        installer.responses[
            "install --source app --payload-dir /tmp/payload --version-file /tmp/payload/VERSION"
        ] = .success(CLIResult(exitCode: 0, stdout: "installed", stderr: "", timedOut: false))

        let output = try await client(installer: installer, cli: cli).synchronize()
        XCTAssertEqual(output, "installed")
        XCTAssertEqual(installer.calls.last, [
            "install", "--source", "app", "--payload-dir", "/tmp/payload",
            "--version-file", "/tmp/payload/VERSION",
        ])
    }

    func testRepairIsExplicit() async throws {
        let installer = FakeCLI()
        let cli = FakeCLI()
        _ = try await client(installer: installer, cli: cli).synchronize(repair: true)
        XCTAssertEqual(installer.calls.last?.last, "--repair")
    }

    func testSynchronizeTrimsOutputAndReportsEveryInstallerFailureMode() async throws {
        let installer = FakeCLI()
        let cli = FakeCLI()
        let command = "install --source app --payload-dir /tmp/payload --version-file /tmp/payload/VERSION"
        installer.responses[command] = .success(CLIResult(
            exitCode: 0, stdout: " installed \n", stderr: "", timedOut: false))
        let output = try await client(installer: installer, cli: cli).synchronize()
        XCTAssertEqual(output, "installed")

        installer.responses[command] = .success(CLIResult(
            exitCode: 9, stdout: "", stderr: " permission denied \n", timedOut: false))
        do {
            _ = try await client(installer: installer, cli: cli).synchronize()
            XCTFail("expected stderr failure")
        } catch {
            XCTAssertEqual(error as? DistributionClientError, .installerFailed("permission denied"))
        }

        installer.responses[command] = .success(CLIResult(
            exitCode: 9, stdout: "", stderr: " \n", timedOut: false))
        do {
            _ = try await client(installer: installer, cli: cli).synchronize()
            XCTFail("expected status failure")
        } catch {
            XCTAssertEqual(
                error as? DistributionClientError,
                .installerFailed(L10n.format("CLI installer exited with status %d", 9)))
        }

        installer.responses[command] = .success(CLIResult(
            exitCode: 0, stdout: "", stderr: "", timedOut: true))
        do {
            _ = try await client(installer: installer, cli: cli).synchronize()
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(
                error as? DistributionClientError,
                .installerFailed(L10n.string("CLI installation timed out")))
        }
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

    func testDoctorRejectsTimeoutAndMissingOutputWithSeparateMessages() async {
        let installer = FakeCLI()
        let cli = FakeCLI()
        cli.responses["doctor --json"] = .success(CLIResult(
            exitCode: 1, stdout: "", stderr: "doctor unavailable", timedOut: false))
        do {
            _ = try await client(installer: installer, cli: cli).doctor()
            XCTFail("expected missing output")
        } catch {
            XCTAssertEqual(
                error as? DistributionClientError,
                .doctorOutputMissing("doctor unavailable"))
        }

        cli.responses["doctor --json"] = .success(CLIResult(
            exitCode: 0, stdout: "ignored", stderr: "", timedOut: true))
        do {
            _ = try await client(installer: installer, cli: cli).doctor()
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(
                error as? DistributionClientError,
                .doctorOutputMissing(L10n.string("detach doctor timed out")))
        }
    }
}
