import Foundation

/// Observed SMAppService behavior from quality/platform-facts.tsv, written by
/// scripts/platform-probe on a real Mac. Fakes that model registration take
/// their shapes from here, so a macOS change fails these tests after
/// `scripts/platform-probe record` instead of hiding behind assumed codes.
enum PlatformFacts {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DetachAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // app
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("quality/platform-facts.tsv")

    static func value(_ fact: String) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count >= 2, fields[0] == Substring(fact) {
                return String(fields[1])
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// `Domain/code` → NSError, or nil for `success`.
    static func error(_ fact: String) throws -> NSError? {
        let shape = try value(fact)
        if shape == "success" { return nil }
        guard let slash = shape.lastIndex(of: "/"),
              let code = Int(shape[shape.index(after: slash)...]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return NSError(domain: String(shape[..<slash]), code: code)
    }

    /// True when a label without a Background Task Management record reports
    /// `.notFound` (folded into the app's `unavailable` status).
    static func absentRecordReportsNotFound() throws -> Bool {
        try value("smappservice.agent.status.absent") == "notFound"
    }
}
