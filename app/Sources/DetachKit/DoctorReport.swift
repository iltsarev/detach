import Foundation

public struct DoctorReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var version: String
    public var build: String?
    public var payloadID: String?
    public var ok: Bool
    public var checks: [DiagnosticCheck]

    public init(schema: Int, version: String, build: String? = nil,
                payloadID: String? = nil, ok: Bool, checks: [DiagnosticCheck]) {
        self.schema = schema
        self.version = version
        self.build = build
        self.payloadID = payloadID
        self.ok = ok
        self.checks = checks
    }

    public func matches(version: String, build: String, payloadID: String) -> Bool {
        self.version == version && self.build == build && self.payloadID == payloadID
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, build, ok, checks
        case payloadID = "payload_id"
    }
}

public struct DiagnosticCheck: Codable, Equatable, Identifiable, Sendable {
    public enum Section: String, Codable, Sendable {
        case base
        case keepAwake
    }

    public enum Status: String, Codable, Sendable {
        case ok
        case warning
        case error
        case unknown
    }

    public var id: String
    public var section: Section
    public var label: String
    public var required: Bool
    public var status: Status
    public var path: String?
    public var summary: String

    public init(id: String, section: Section, label: String, required: Bool,
                status: Status, path: String?, summary: String) {
        self.id = id
        self.section = section
        self.label = label
        self.required = required
        self.status = status
        self.path = path
        self.summary = summary
    }
}

public enum DistributionClientError: LocalizedError, Equatable {
    case installerFailed(String)
    case doctorOutputMissing(String)
    case incompatibleDoctorSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .installerFailed(let message): message
        case .doctorOutputMissing(let message): message
        case .incompatibleDoctorSchema(let schema):
            "Unsupported detach doctor schema: \(schema)"
        }
    }
}

public struct DistributionClient: Sendable {
    private let installer: any DetachCLIRunning
    private let cli: any DetachCLIRunning
    private let payloadDirectory: URL
    private let versionFile: URL

    public init(installer: any DetachCLIRunning, cli: any DetachCLIRunning,
                payloadDirectory: URL, versionFile: URL) {
        self.installer = installer
        self.cli = cli
        self.payloadDirectory = payloadDirectory
        self.versionFile = versionFile
    }

    public func synchronize(repair: Bool = false) async throws -> String {
        var arguments = [
            "install", "--source", repair ? "repair" : "app",
            "--payload-dir", payloadDirectory.path,
            "--version-file", versionFile.path,
            "--no-launch-agent",
        ]
        if repair { arguments.append("--repair") }
        let result = try await installer.run(arguments: arguments, timeout: 30)
        guard result.exitCode == 0, !result.timedOut else {
            let message = result.timedOut
                ? "CLI installation timed out"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DistributionClientError.installerFailed(
                message.isEmpty ? "CLI installer exited with status \(result.exitCode)" : message)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func doctor() async throws -> DoctorReport {
        let result = try await cli.run(arguments: ["doctor", "--json"], timeout: 15)
        guard !result.timedOut, let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw DistributionClientError.doctorOutputMissing(
                result.timedOut ? "detach doctor timed out" : result.stderr)
        }
        let report = try JSONDecoder().decode(DoctorReport.self, from: data)
        guard report.schema == 1 else {
            throw DistributionClientError.incompatibleDoctorSchema(report.schema)
        }
        return report
    }
}
